import FluidAudio
import Foundation

enum ASRLanguageMode: String {
    case automatic
    case english
}

final class ParakeetTranscriber {
    private var manager: AsrManager?
    private let version: AsrModelVersion
    private let label: String

    init(version: AsrModelVersion, label: String) {
        self.version = version
        self.label = label
    }

    func load(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        onProgress(0.05, "Preparing \(label)...")
        let models = try await AsrModels.downloadAndLoad(version: version) { progress in
            let message: String
            switch progress.phase {
            case .listing:
                message = "Checking \(self.label) files..."
            case .downloading:
                message = "Downloading \(self.label)..."
            case .compiling(let modelName):
                message = "Compiling \(modelName)..."
            }
            onProgress(progress.fractionCompleted, message)
        }

        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        manager = asrManager
        onProgress(1, "\(label) ready")
    }

    func transcribe(
        _ audio: [Float],
        languageMode: ASRLanguageMode = .automatic
    ) async throws -> String {
        guard let manager else {
            throw TranscriptionEngine.TranscriptionError.modelNotLoaded
        }
        guard audio.count >= 4800 else {
            llog("ParakeetTranscriber: audio under 300ms; skipping")
            return ""
        }

        llog("ParakeetTranscriber: \(label) transcribing \(audio.count) samples")
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language: Language?
        switch version {
        case .v2:
            language = .english
        case .v3:
            // Keep multilingual auto-detection as the production baseline,
            // but make the English hint independently benchmarkable against
            // exactly the same audio before changing that default.
            language = languageMode == .english ? .english : nil
        default:
            language = nil
        }
        let result = try await manager.transcribe(audio, decoderState: &decoderState, language: language)
        let cleanedText = sanitize(result.text)
        llog("ParakeetTranscriber: result='\(cleanedText)' language=\(languageMode.rawValue) rtfx=\(String(format: "%.2f", result.rtfx)) confidence=\(String(format: "%.3f", result.confidence))")
        return cleanedText
    }

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
