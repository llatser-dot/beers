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

    private func ensureEngineRunning() throws {
        if let engine, engine.isRunning {
            return
        }

        // startRecording has already suppressed output. Rebuilding the audio
        // graph must not restore it during the recorder's cold start.
        stopEngine(restoreOutput: false)

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
        let activeConverter = converter
        let activeOutputFormat = outputFormat
        lock.unlock()

        guard shouldCapture, let activeConverter, let activeOutputFormat else { return }
        guard pcmBuffer.frameLength > 0 else { return }
        guard let monoBuffer = makeMonoBuffer(from: pcmBuffer) else { return }
        guard let convertedBuffer = convert(monoBuffer, with: activeConverter, to: activeOutputFormat) else { return }
        guard let channelData = convertedBuffer.floatChannelData else { return }
        let frameCount = Int(convertedBuffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

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
                guard let self, !self.isCapturing else { return }
                self.stopEngine()
                llog("AudioRecorder: audio devices changed; engine will restart on next capture")
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
            self.stopEngine()
            llog("AudioRecorder: engine configuration changed; engine will restart on next capture")
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
