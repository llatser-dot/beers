import AVFoundation

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var buffer: [Float] = []
    private let targetSampleRate: Double = 16000
    private let lock = NSLock()
    private var tapCallbackCount = 0

    func startRecording() throws {
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let outFormat = inputNode.outputFormat(forBus: 0)

        llog("AudioRecorder: output format \(outFormat.sampleRate)Hz \(outFormat.channelCount)ch")
        guard outFormat.sampleRate > 0 && outFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        lock.lock()
        buffer.removeAll()
        lock.unlock()
        tapCallbackCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: outFormat) { [weak self] pcmBuffer, _ in
            self?.handleBuffer(pcmBuffer)
        }

        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
        llog("AudioRecorder: engine started")
    }

    func stopRecording() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        lock.lock()
        let captured = buffer
        buffer.removeAll()
        lock.unlock()

        let duration = Float(captured.count) / Float(targetSampleRate)
        let rms = sqrt(captured.map { $0 * $0 }.reduce(0, +) / Float(max(1, captured.count)))
        let peak = captured.map(abs).max() ?? 0
        llog("AudioRecorder: captured \(captured.count) samples (\(String(format: "%.2f", duration))s), RMS=\(String(format: "%.4f", rms)), peak=\(String(format: "%.4f", peak)), callbacks=\(tapCallbackCount)")

        return captured
    }

    private func handleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return }

        let rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        tapCallbackCount += 1

        let sourceSampleRate = pcmBuffer.format.sampleRate
        let samples: [Float]
        if sourceSampleRate != targetSampleRate {
            let ratio = sourceSampleRate / targetSampleRate
            let outputCount = Int(Double(frameCount) / ratio)
            var downsampled = [Float](repeating: 0, count: outputCount)
            for index in 0..<outputCount {
                let sourceIndex = Int(Double(index) * ratio)
                if sourceIndex < frameCount {
                    downsampled[index] = rawSamples[sourceIndex]
                }
            }
            samples = downsampled
        } else {
            samples = rawSamples
        }

        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    enum RecorderError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No audio input device found."
            }
        }
    }
}
