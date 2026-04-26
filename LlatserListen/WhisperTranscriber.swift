import Foundation
import WhisperKit

final class WhisperTranscriber {
    private var whisperKit: WhisperKit?

    func load(modelName: String, onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        onProgress(0.1, "Preparing Whisper \(modelName)...")
        let config = WhisperKitConfig(
            model: "openai_whisper-\(modelName)",
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        onProgress(1, "Whisper \(modelName) ready")
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionEngine.TranscriptionError.modelNotLoaded
        }
        guard !audio.isEmpty else { return "" }

        llog("WhisperTranscriber: transcribing \(audio.count) samples")
        let results = try await whisperKit.transcribe(audioArray: audio)
        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = sanitize(text)
        llog("WhisperTranscriber: result='\(cleanedText)'")
        return cleanedText
    }

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: "<|nospeech|>", with: "")
            .replacingOccurrences(of: "<|nocaptions|>", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
