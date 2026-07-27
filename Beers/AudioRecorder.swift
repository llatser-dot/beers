import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures microphone audio through a dedicated HAL input unit bound
/// explicitly to one device. AVAudioEngine's inputNode is hard-wired to the
/// SYSTEM DEFAULT input; with AirPods connected that meant every engine start
/// touched the Bluetooth device (HFP flip, 2-5s stalls, pins silently
/// reverting to the 24kHz headset mic, zero-callback zombie engines). Binding
/// our own AUHAL to the chosen device means the capture path never touches
/// the default-device machinery at all.
final class AudioRecorder {
    private struct InputDevice {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
    }

    private var inputUnit: AudioUnit?
    private var renderBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var buffer: [Float] = []
    private var isCapturing = false
    private var captureID = 0
    private var suppressComputerAudio = true
    private let targetSampleRate: Double = 16000
    private let lock = NSLock()
    private var tapCallbackCount = 0
    private var selectedChannelLogCount = 0

    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchSourceTimer?
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 5
    private var lastBufferAt: CFAbsoluteTime = 0
    private var captureStartedAt: CFAbsoluteTime = 0
    private var droppedRenderLogCount = 0

    var isWarm: Bool {
        inputUnit != nil
    }

    init() {
        installDeviceChangeListeners()
    }

    func setSuppressComputerAudio(_ enabled: Bool) {
        suppressComputerAudio = enabled
        // Preference only affects ducking + next capture path.
        // Never keep the unit warm while idle — that lights the menu-bar mic.
        if isWarm && !isCapturing {
            stopEngine()
        }
    }

    func startRecording() throws {
        // Start the bound capture unit FIRST (milliseconds on a wired mic),
        // then duck. Ducking mutes the default output — often Bluetooth —
        // and poking that device while the unit spins up risks CoreAudio
        // churn at the worst moment. Voice processing is intentionally
        // skipped: it adds multi-second cold-start lag and keeps the system
        // mic indicator lit while the graph is warm.
        try ensureEngineRunning()
        SystemAudioDucker.duckIfNeeded(enabled: suppressComputerAudio)

        lock.lock()
        buffer.removeAll()
        tapCallbackCount = 0
        selectedChannelLogCount = 0
        droppedRenderLogCount = 0
        captureID += 1
        isCapturing = true
        lastBufferAt = CFAbsoluteTimeGetCurrent()
        captureStartedAt = lastBufferAt
        converter?.reset()
        lock.unlock()
        recoveryAttempts = 0
        startWatchdog()
        llog("AudioRecorder: capture started")
    }

    func stopRecording() -> [Float] {
        stopWatchdog()
        lock.lock()
        isCapturing = false
        let captured = buffer
        buffer.removeAll()
        let callbacks = tapCallbackCount
        lock.unlock()

        SystemAudioDucker.restoreIfNeeded()

        // Never discard portions of a real pour here. Energy-only trimming
        // cannot reliably distinguish quiet syllables from room noise and was
        // cutting dictations short. Keep the full capture; AppState's existing
        // duration/RMS guard still rejects truly silent recordings.
        let boosted = Self.normalizeForSpeech(captured)
        let duration = Float(boosted.count) / Float(targetSampleRate)
        let rms = sqrt(boosted.map { $0 * $0 }.reduce(0, +) / Float(max(1, boosted.count)))
        let peak = boosted.map(abs).max() ?? 0
        llog("AudioRecorder: captured \(boosted.count) samples (\(String(format: "%.2f", duration))s), RMS=\(String(format: "%.4f", rms)), peak=\(String(format: "%.4f", peak)), callbacks=\(callbacks)")

        return boosted
    }

    func stopEngine(restoreOutput: Bool = true) {
        if restoreOutput {
            SystemAudioDucker.restoreIfNeeded()
        }

        stopWatchdog()
        recoveryAttempts = 0
        teardownUnit()

        lock.lock()
        buffer.removeAll()
        isCapturing = false
        captureID += 1
        lock.unlock()

        llog("AudioRecorder: engine stopped")
    }

    /// Tears down the capture unit but keeps the capture state (buffer,
    /// isCapturing, captureID) intact so a mid-pour rebuild never drops
    /// audio the user already spoke.
    private func teardownUnit() {
        let unit: AudioUnit?
        lock.lock()
        unit = inputUnit
        inputUnit = nil
        converter = nil
        outputFormat = nil
        lock.unlock()

        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        // renderBuffer is only touched by the render callback, which is dead
        // once the unit above is stopped.
        renderBuffer = nil
    }

    private func ensureEngineRunning() throws {
        if inputUnit != nil {
            return
        }

        // Headphones connecting churn CoreAudio for a few seconds. A start
        // attempt in that window can fail or see a half-configured device,
        // so retry briefly instead of failing the pour.
        var lastError: Error = RecorderError.noInputDevice
        for attempt in 1...3 {
            do {
                try startEngine()
                return
            } catch {
                lastError = error
                teardownUnit()
                llog("AudioRecorder: capture unit start attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.15 * Double(attempt))
                }
            }
        }
        throw lastError
    }

    private func startEngine() throws {
        guard let device = Self.captureDevice() else {
            throw RecorderError.noInputDevice
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.unitSetup("no HAL output component", noErr)
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "instantiate")
        guard let unit = newUnit else {
            throw RecorderError.unitSetup("instantiate returned no unit", noErr)
        }

        // From here on, dispose on any failure so we never leak a half-built unit.
        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)
            ), "enable input")
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)
            ), "disable output")

            // Bind to the chosen device BEFORE initialize — this is the whole
            // point: the unit belongs to one device and the system default
            // (possibly Bluetooth) is never opened.
            var deviceID = device.id
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ), "bind device")

            var hardwareFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1, &hardwareFormat, &formatSize
            ), "read hardware format")
            let sampleRate = hardwareFormat.mSampleRate
            let channelCount = min(hardwareFormat.mChannelsPerFrame, 8)
            guard sampleRate > 0, channelCount > 0 else {
                throw RecorderError.unsupportedInputFormat
            }

            guard let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
                throw RecorderError.unsupportedInputFormat
            }
            var clientDescription = clientFormat.streamDescription.pointee
            try check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &clientDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ), "set client format")

            var callback = AURenderCallbackStruct(
                inputProc: audioRecorderInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "set input callback")

            guard let newOutputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ), let monoInputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ), let newConverter = AVAudioConverter(from: monoInputFormat, to: newOutputFormat) else {
                throw RecorderError.unsupportedInputFormat
            }
            newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

            // Ask for a sane slice size so the render buffer can never be
            // outrun by a device that defaults to huge buffers. Best effort —
            // some devices refuse.
            var preferredFrames: UInt32 = 512
            _ = AudioUnitSetProperty(
                unit, kAudioDevicePropertyBufferFrameSize,
                kAudioUnitScope_Global, 0, &preferredFrames, UInt32(MemoryLayout<UInt32>.size)
            )

            renderBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: 8192)
            guard renderBuffer != nil else {
                throw RecorderError.unsupportedInputFormat
            }

            try check(AudioUnitInitialize(unit), "initialize")
            do {
                try check(AudioOutputUnitStart(unit), "start")
            } catch {
                AudioUnitUninitialize(unit)
                throw error
            }

            // The whole AVAudioEngine failure class was "bind accepted, then
            // silently reverted" — verify the running unit is still ours.
            var boundDevice = AudioDeviceID(0)
            var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &boundDevice, &boundSize
            ) == noErr, boundDevice != device.id {
                llog("AudioRecorder: WARNING bound device reverted (\(boundDevice) != \(device.id)) — the pin race is back")
            }

            lock.lock()
            inputUnit = unit
            converter = newConverter
            outputFormat = newOutputFormat
            lock.unlock()

            llog("AudioRecorder: capture unit started on '\(device.name)' @ \(Int(sampleRate))Hz \(channelCount)ch")
        } catch {
            AudioComponentInstanceDispose(unit)
            renderBuffer = nil
            throw error
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw RecorderError.unitSetup(step, status)
        }
    }

    fileprivate func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        lock.lock()
        let unit = inputUnit
        lock.unlock()
        guard let unit, let pcmBuffer = renderBuffer, frameCount > 0 else {
            return noErr
        }
        guard frameCount <= pcmBuffer.frameCapacity else {
            lock.lock()
            let shouldLog = droppedRenderLogCount < 3
            if shouldLog { droppedRenderLogCount += 1 }
            lock.unlock()
            if shouldLog {
                llog("AudioRecorder: dropped render slice (\(frameCount) frames > \(pcmBuffer.frameCapacity) capacity)")
            }
            return noErr
        }

        pcmBuffer.frameLength = frameCount
        let status = AudioUnitRender(
            unit, actionFlags, timeStamp, busNumber, frameCount,
            pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return status }
        handleBuffer(pcmBuffer)
        return noErr
    }

    private func handleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        lock.lock()
        let shouldCapture = isCapturing
        let activeCaptureID = captureID
        let lockedConverter = converter
        let activeOutputFormat = outputFormat
        lock.unlock()

        guard shouldCapture, var activeConverter = lockedConverter, let activeOutputFormat else { return }
        guard pcmBuffer.frameLength > 0 else { return }

        // A device format change under a running unit would make a converter
        // built for the old rate reject every buffer (captured silence), so
        // rebuild it for what the hardware now delivers.
        if activeConverter.inputFormat.sampleRate != pcmBuffer.format.sampleRate {
            guard let driftedMonoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: pcmBuffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ), let rebuiltConverter = AVAudioConverter(from: driftedMonoFormat, to: activeOutputFormat) else {
                return
            }
            rebuiltConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            lock.lock()
            converter = rebuiltConverter
            lock.unlock()
            activeConverter = rebuiltConverter
            llog("AudioRecorder: input rate changed mid-pour to \(pcmBuffer.format.sampleRate)Hz; converter rebuilt")
        }

        guard let monoBuffer = makeMonoBuffer(from: pcmBuffer) else { return }
        guard let convertedBuffer = convert(monoBuffer, with: activeConverter, to: activeOutputFormat) else { return }
        guard let channelData = convertedBuffer.floatChannelData else { return }
        let frameCount = Int(convertedBuffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        LiveMicLevel.shared.update(samples)

        lock.lock()
        var firstBufferLatency: CFAbsoluteTime?
        if isCapturing && captureID == activeCaptureID {
            buffer.append(contentsOf: samples)
            tapCallbackCount += 1
            lastBufferAt = CFAbsoluteTimeGetCurrent()
            if tapCallbackCount == 1 {
                firstBufferLatency = lastBufferAt - captureStartedAt
            }
        }
        lock.unlock()
        if let firstBufferLatency {
            llog("AudioRecorder: first buffer after \(Int(firstBufferLatency * 1000))ms")
        }
    }

    private func makeMonoBuffer(from pcmBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let sourceData = pcmBuffer.floatChannelData else { return nil }
        let frameCount = Int(pcmBuffer.frameLength)
        let channelCount = Int(pcmBuffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: pcmBuffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let monoData = monoBuffer.floatChannelData else {
            return nil
        }

        monoBuffer.frameLength = AVAudioFrameCount(frameCount)
        let destination = monoData[0]

        if channelCount == 1 {
            destination.update(from: sourceData[0], count: frameCount)
        } else {
            // Raw built-in array: sum channels so speech energy adds up.
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += sourceData[channel][frame]
                }
                destination[frame] = sum
            }
        }

        if channelCount > 1 {
            lock.lock()
            if selectedChannelLogCount < 3 {
                selectedChannelLogCount += 1
                lock.unlock()
                var energy: Float = 0
                for frame in 0..<frameCount {
                    let sample = destination[frame]
                    energy += sample * sample
                }
                let rms = sqrt(energy / Float(max(1, frameCount)))
                llog("AudioRecorder: mixed \(channelCount) channels, RMS=\(String(format: "%.5f", rms))")
            } else {
                lock.unlock()
            }
        }

        return monoBuffer
    }

    /// Bring quiet built-in mic captures up to speech level without blowing up silence.
    private static func normalizeForSpeech(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let count = Float(samples.count)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / count)
        let peak = samples.map(abs).max() ?? 0

        // Near-silence: leave alone so the too-quiet gate still works.
        guard rms >= 0.00005, peak > 0 else { return samples }

        let targetRMS: Float = 0.08
        let maxGain: Float = 48
        let gain = min(maxGain, targetRMS / max(rms, 0.00005))
        guard gain > 1.05 else { return samples }

        let boosted = samples.map { max(-1, min(1, $0 * gain)) }
        let boostedRMS = sqrt(boosted.reduce(0) { $0 + $1 * $1 } / count)
        llog("AudioRecorder: applied gain \(String(format: "%.1f", gain))x (rms \(String(format: "%.5f", rms)) → \(String(format: "%.4f", boostedRMS)))")
        return boosted
    }

    /// The device this pour should capture from. Capturing from a Bluetooth
    /// headset mic forces AirPods into low-quality HFP call mode and lags the
    /// whole system audio path, so when the default input is Bluetooth we use
    /// the built-in microphone instead. The result is always an explicit
    /// device — capture never follows the system default at runtime.
    private static func captureDevice() -> InputDevice? {
        if let defaultID = defaultInputDeviceID(),
           let transport = deviceTransport(defaultID),
           !isBluetoothTransport(transport) {
            let name = deviceName(defaultID) ?? "Input \(defaultID)"
            return InputDevice(id: defaultID, name: name, transport: transport)
        }
        if let builtIn = preferredInputDevice() {
            llog("AudioRecorder: default input is Bluetooth or unavailable; using '\(builtIn.name)'")
            return builtIn
        }
        return nil
    }

    /// Display name of the device a pour would actually capture from right now.
    ///
    /// This is the real device, not a label: with AirPods connected it returns
    /// the built-in microphone, because that is genuinely what gets recorded.
    /// Settings shows this so an external mic is never misreported as built-in.
    static func currentInputDisplayName() -> String {
        captureDevice()?.name ?? "No microphone"
    }

    private static func isBluetoothTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func installDeviceChangeListeners() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleRouteChange(reason: "audio devices changed")
                // Settings shows the live capture device; plugging in a mic or
                // connecting AirPods has to move that label.
                NotificationCenter.default.post(name: .beersInputDeviceChanged, object: nil)
            }
        }
        deviceChangeListener = listener

        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
        }
    }

    /// The capture unit is bound to an explicit device, so default-device
    /// changes can't break a running pour — the watchdog handles the rare
    /// case where our bound device itself dies. Idle, just tear down so the
    /// next pour re-resolves which device to use.
    private func handleRouteChange(reason: String) {
        lock.lock()
        let capturing = isCapturing
        lock.unlock()

        guard capturing else {
            if isWarm {
                stopEngine()
                llog("AudioRecorder: \(reason); capture unit will rebind on next pour")
            }
            return
        }
        llog("AudioRecorder: \(reason) mid-pour; bound capture unit unaffected")
    }

    /// Recovery is driven by evidence, not notifications: if the bound
    /// device stops delivering buffers for ~1s mid-pour (unplugged, died),
    /// rebuild the unit on whatever device is right now — with the buffered
    /// audio untouched.
    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.75, repeating: 0.75)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        lock.lock()
        let capturing = isCapturing
        let last = lastBufferAt
        let callbacks = tapCallbackCount
        lock.unlock()
        guard capturing else { return }

        // A unit that has never delivered gets extra grace — tearing down a
        // healthy-but-slow first start would rebuild mid-sentence for nothing.
        let stallThreshold: CFAbsoluteTime = callbacks == 0 ? 2.5 : 1.0
        if CFAbsoluteTimeGetCurrent() - last < stallThreshold {
            recoveryAttempts = 0
            return
        }

        recoveryAttempts += 1
        guard recoveryAttempts <= maxRecoveryAttempts else {
            llog("AudioRecorder: capture stalled and recovery gave up after \(maxRecoveryAttempts) attempts")
            stopWatchdog()
            return
        }

        llog("AudioRecorder: no audio for 1s mid-pour; rebuilding capture unit (attempt \(recoveryAttempts))")
        teardownUnit()
        do {
            try startEngine()
            lock.lock()
            lastBufferAt = CFAbsoluteTimeGetCurrent()
            lock.unlock()
            llog("AudioRecorder: capture unit recovered mid-pour")
        } catch {
            llog("AudioRecorder: mid-pour rebuild failed: \(error.localizedDescription); will retry")
        }
    }

    /// Test seam for `--beers-route-test`: drives the exact same path the
    /// CoreAudio listeners fire when headphones connect mid-pour.
    func simulateRouteChangeForTesting() {
        DispatchQueue.main.async { [weak self] in
            self?.handleRouteChange(reason: "simulated route change")
        }
    }

    private static func preferredInputDevice() -> InputDevice? {
        let devices = inputDevices()
        return devices.first {
            $0.transport == kAudioDeviceTransportTypeBuiltIn
                && $0.name.localizedCaseInsensitiveContains("microphone")
        } ?? devices.first {
            $0.transport == kAudioDeviceTransportTypeBuiltIn
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID) else { return nil }
            let name = deviceName(deviceID) ?? "Input \(deviceID)"
            let transport = deviceTransport(deviceID) ?? 0
            return InputDevice(id: deviceID, name: name, transport: transport)
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func deviceTransport(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transport)
        guard status == noErr else { return nil }
        return transport
    }

    private func convert(
        _ pcmBuffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetSampleRate / pcmBuffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(pcmBuffer.frameLength) * ratio)) + 16)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        if status == .error {
            llog("AudioRecorder: conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
            return nil
        }

        return convertedBuffer
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case unsupportedInputFormat
        case unitSetup(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No audio input device found."
            case .unsupportedInputFormat: return "The current microphone format is not supported."
            case .unitSetup(let step, let status): return "Audio capture setup failed (\(step), status \(status))."
            }
        }
    }

    deinit {
        stopWatchdog()
        if let unit = inputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }
}

private func audioRecorderInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
    return recorder.render(
        actionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        busNumber: inBusNumber,
        frameCount: inNumberFrames
    )
}

/// Live mic RMS for the HUD waveform. Written from the audio tap thread,
/// read every frame by the overlay's TimelineView.
final class LiveMicLevel {
    static let shared = LiveMicLevel()
    private let lock = NSLock()
    private var value: Float = 0

    func update(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        // Normalise raw capture RMS (pre speech-gain) into 0...1 display range.
        let display = min(1, rms * 24)
        lock.lock()
        // Fast attack, slow decay so speech feels punchy.
        value = display > value ? display : value * 0.82 + display * 0.18
        lock.unlock()
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

extension Notification.Name {
    /// Posted on the main queue when the system's audio devices change, so
    /// Settings can refresh the microphone it reports.
    static let beersInputDeviceChanged = Notification.Name("beers.inputDeviceChanged")
}
