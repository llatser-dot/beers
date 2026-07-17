import AVFoundation
import AudioToolbox
import CoreAudio

final class AudioRecorder {
    private struct InputDevice {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var buffer: [Float] = []
    private var isCapturing = false
    private var captureID = 0
    private var suppressComputerAudio = true
    private let targetSampleRate: Double = 16000
    private let tapBufferSize: AVAudioFrameCount = 1024
    private let lock = NSLock()
    private var tapCallbackCount = 0
    private var selectedChannelLogCount = 0

    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var configChangeObserver: NSObjectProtocol?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 5

    var isWarm: Bool {
        engine?.isRunning == true
    }

    init() {
        installDeviceChangeListeners()
    }

    func setSuppressComputerAudio(_ enabled: Bool) {
        suppressComputerAudio = enabled
        // Preference only affects ducking + next capture path.
        // Never keep the engine warm while idle — that lights the menu-bar mic.
        if isWarm && !isCapturing {
            stopEngine()
        }
    }

    func startRecording() throws {
        // Duck immediately so suppress feels instant, then start a fast raw capture.
        // Voice processing is intentionally skipped: it adds multi-second cold-start lag
        // and keeps the system mic indicator lit while the graph is warm.
        SystemAudioDucker.duckIfNeeded(enabled: suppressComputerAudio)
        do {
            try ensureEngineRunning()
        } catch {
            SystemAudioDucker.restoreIfNeeded()
            throw error
        }

        lock.lock()
        buffer.removeAll()
        tapCallbackCount = 0
        selectedChannelLogCount = 0
        captureID += 1
        isCapturing = true
        converter?.reset()
        lock.unlock()
        llog("AudioRecorder: capture started")
    }

    func stopRecording() -> [Float] {
        lock.lock()
        isCapturing = false
        let captured = buffer
        buffer.removeAll()
        let callbacks = tapCallbackCount
        lock.unlock()

        SystemAudioDucker.restoreIfNeeded()

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

        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryAttempts = 0

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        lock.lock()
        self.engine = nil
        converter = nil
        outputFormat = nil
        buffer.removeAll()
        isCapturing = false
        captureID += 1
        lock.unlock()

        llog("AudioRecorder: engine stopped")
    }

    /// Tears down the audio graph but keeps the capture state (buffer,
    /// isCapturing, captureID) intact so a mid-pour engine rebuild never
    /// drops audio the user already spoke.
    private func teardownEngineOnly() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        lock.lock()
        self.engine = nil
        converter = nil
        outputFormat = nil
        lock.unlock()
    }

    private func ensureEngineRunning() throws {
        if let engine, engine.isRunning {
            return
        }

        // startRecording has already suppressed output. Rebuilding the audio
        // graph must not restore it during the recorder's cold start.
        stopEngine(restoreOutput: false)

        // Headphones connecting churn CoreAudio for a few seconds (the device
        // list and defaults flap several times per connect). A start attempt
        // in that window can fail or see a half-configured device, so retry
        // briefly instead of failing the pour.
        var lastError: Error = RecorderError.noInputDevice
        for attempt in 1...3 {
            do {
                try startEngine()
                return
            } catch {
                lastError = error
                teardownEngineOnly()
                llog("AudioRecorder: engine start attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.15 * Double(attempt))
                }
            }
        }
        throw lastError
    }

    private func startEngine() throws {
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode

        // Capturing from a Bluetooth headset mic forces AirPods into low-quality
        // HFP call mode and lags the whole system audio path, so when the default
        // input is Bluetooth we pin the built-in microphone instead.
        let pinnedDevice = Self.captureDeviceAvoidingBluetoothInput()

        if let pinnedDevice {
            pin(device: pinnedDevice, on: inputNode)
        } else {
            llog("AudioRecorder: using system default input device")
        }

        // Fast raw capture only. Suppress Mac audio is handled by SystemAudioDucker
        // (volume duck) + software gain — not Apple voice processing.
        llog("AudioRecorder: raw input mode")

        let inputFormat = inputNode.outputFormat(forBus: 0)
        llog("AudioRecorder: input format \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch")
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.unsupportedInputFormat
        }

        guard let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.unsupportedInputFormat
        }

        guard let newConverter = AVAudioConverter(from: monoInputFormat, to: outputFormat) else {
            throw RecorderError.unsupportedInputFormat
        }
        newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.handleBuffer(pcmBuffer)
        }

        lock.lock()
        engine = newEngine
        converter = newConverter
        self.outputFormat = outputFormat
        lock.unlock()

        newEngine.prepare()
        do {
            try newEngine.start()
            llog("AudioRecorder: engine started")
        } catch {
            inputNode.removeTap(onBus: 0)
            lock.lock()
            engine = nil
            converter = nil
            self.outputFormat = nil
            lock.unlock()
            throw error
        }
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

        // A route change can shift the input sample rate underneath a running
        // tap. A converter built for the old rate would reject every buffer
        // (captured silence), so rebuild it for what the hardware now delivers.
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
        if isCapturing && captureID == activeCaptureID {
            buffer.append(contentsOf: samples)
            tapCallbackCount += 1
        }
        lock.unlock()
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

    private func pin(device: InputDevice, on inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else {
            llog("AudioRecorder: could not access input audio unit; using system default input device")
            return
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            llog("AudioRecorder: pinned input device '\(device.name)' (avoiding Bluetooth mic)")
        } else {
            llog("AudioRecorder: failed to pin input device '\(device.name)' status=\(status); using system default")
        }
    }

    private static func captureDeviceAvoidingBluetoothInput() -> InputDevice? {
        guard let defaultID = defaultInputDeviceID(),
              let transport = deviceTransport(defaultID),
              isBluetoothTransport(transport) else {
            return nil
        }
        return preferredInputDevice()
    }

    private static func isBluetoothTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func installDeviceChangeListeners() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleRouteChange(reason: "audio devices changed")
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

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let engine = self.engine, notification.object as? AVAudioEngine === engine else { return }
            self.handleRouteChange(reason: "engine configuration changed")
        }
    }

    /// Route changes while idle just tear the engine down (it rebuilds on the
    /// next capture). Mid-pour they must NOT kill the capture: headphones
    /// connecting fire several of these in a burst, so coalesce briefly, then
    /// rebuild the graph in place with the buffered audio untouched.
    private func handleRouteChange(reason: String) {
        lock.lock()
        let capturing = isCapturing
        lock.unlock()

        guard capturing else {
            stopEngine()
            llog("AudioRecorder: \(reason); engine will restart on next capture")
            return
        }

        llog("AudioRecorder: \(reason) mid-pour; recovering capture without dropping audio")
        recoveryAttempts = 0
        scheduleMidPourRecovery(after: 0.25)
    }

    private func scheduleMidPourRecovery(after delay: TimeInterval) {
        recoveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.recoverMidPour()
        }
        recoveryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func recoverMidPour() {
        lock.lock()
        let capturing = isCapturing
        lock.unlock()
        guard capturing else { return }

        teardownEngineOnly()
        do {
            try startEngine()
            recoveryAttempts = 0
            llog("AudioRecorder: engine recovered mid-pour")
        } catch {
            recoveryAttempts += 1
            guard recoveryAttempts < maxRecoveryAttempts else {
                llog("AudioRecorder: mid-pour recovery gave up after \(recoveryAttempts) attempts: \(error.localizedDescription)")
                return
            }
            llog("AudioRecorder: mid-pour recovery attempt \(recoveryAttempts) failed: \(error.localizedDescription); retrying")
            scheduleMidPourRecovery(after: 0.4)
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
        guard status == noErr else { return nil }
        return deviceID
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No audio input device found."
            case .unsupportedInputFormat: return "The current microphone format is not supported."
            }
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
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
