import AVFoundation
import FluidAudio
import Foundation

final class NemotronTranscriber {
    private var manager: StreamingNemotronAsrManager?

    func load(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        onProgress(0.05, "Preparing Nemotron 0.6B...")
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms560)
        try removePartialCacheIfNeeded()
        onProgress(0.15, "Downloading Nemotron 0.6B (~613 MB)...")
        try await manager.loadModels { progress in
            onProgress(
                0.15 + (progress.fractionCompleted * 0.7),
                Self.progressMessage(for: progress)
            )
        }
        onProgress(0.9, "Loading Nemotron into Core ML...")
        self.manager = manager
        onProgress(1, "Nemotron 0.6B ready")
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard let manager else {
            throw TranscriptionEngine.TranscriptionError.modelNotLoaded
        }
        guard audio.count >= 4800 else {
            llog("NemotronTranscriber: audio under 300ms; skipping")
            return ""
        }

        await manager.reset()
        let buffer = try makeBuffer(from: audio)
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        let text = try await manager.finish()
        let cleanedText = sanitize(text)
        llog("NemotronTranscriber: result='\(cleanedText)'")
        return cleanedText
    }

    private func makeBuffer(from audio: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else {
            throw TranscriptionEngine.TranscriptionError.invalidAudioBuffer
        }

        buffer.frameLength = AVAudioFrameCount(audio.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw TranscriptionEngine.TranscriptionError.invalidAudioBuffer
        }

        audio.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: audio.count)
        }

        return buffer
    }

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func progressMessage(for progress: DownloadUtils.DownloadProgress) -> String {
        let percent = Int((progress.fractionCompleted * 100).rounded())
        switch progress.phase {
        case .listing:
            return "Checking Nemotron files..."
        case .downloading(let completedFiles, let totalFiles):
            return "Downloading Nemotron \(percent)% (\(completedFiles)/\(totalFiles) files)..."
        case .compiling(let modelName):
            return "Preparing \(modelName) for Core ML..."
        }
    }

    private func removePartialCacheIfNeeded() throws {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let cacheDirectory = applicationSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("560ms", isDirectory: true)
        let encoderPath = cacheDirectory.appendingPathComponent("encoder/encoder_int8.mlmodelc").path
        guard fileManager.fileExists(atPath: encoderPath) else { return }

        let requiredPaths = [
            "preprocessor.mlmodelc",
            "encoder/encoder_int8.mlmodelc",
            "decoder.mlmodelc",
            "joint.mlmodelc",
            "tokenizer.json",
            "metadata.json"
        ]

        let isComplete = requiredPaths.allSatisfy { relativePath in
            fileManager.fileExists(atPath: cacheDirectory.appendingPathComponent(relativePath).path)
        }
        guard !isComplete else { return }

        llog("NemotronTranscriber: removing partial model cache at \(cacheDirectory.path)")
        try fileManager.removeItem(at: cacheDirectory)
    }
}
