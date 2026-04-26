import FluidAudio
import Foundation

final class ParakeetTranscriber {
    private var manager: AsrManager?

    func load(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        onProgress(0.05, "Preparing Parakeet v3...")
        let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
            let message: String
            switch progress.phase {
            case .listing:
                message = "Checking Parakeet files..."
            case .downloading:
                message = "Downloading Parakeet v3..."
            case .compiling(let modelName):
                message = "Compiling \(modelName)..."
            }
            onProgress(progress.fractionCompleted, message)
        }

        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        manager = asrManager
        onProgress(1, "Parakeet v3 ready")
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard let manager else {
            throw TranscriptionEngine.TranscriptionError.modelNotLoaded
        }
        guard audio.count >= 4800 else {
            llog("ParakeetTranscriber: audio under 300ms; skipping")
            return ""
        }

        llog("ParakeetTranscriber: transcribing \(audio.count) samples")
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &decoderState, language: .english)
        let cleanedText = sanitize(result.text)
        llog("ParakeetTranscriber: result='\(cleanedText)' rtfx=\(String(format: "%.2f", result.rtfx)) confidence=\(String(format: "%.3f", result.confidence))")
        return cleanedText
    }

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
