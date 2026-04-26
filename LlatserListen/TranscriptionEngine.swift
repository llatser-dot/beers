import Foundation

final class TranscriptionEngine {
    private var parakeet: ParakeetTranscriber?
    private var whisper: WhisperTranscriber?
    private(set) var loadedEngine: DictationEngine?

    func load(_ engine: DictationEngine, onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        if loadedEngine == engine {
            onProgress(1, "\(engine.displayName) ready")
            return
        }

        loadedEngine = nil
        switch engine {
        case .parakeet:
            whisper = nil
            let transcriber = ParakeetTranscriber()
            try await transcriber.load { progress, message in
                onProgress(progress, message)
            }
            parakeet = transcriber
        case .whisperSmall, .whisperTiny:
            parakeet = nil
            guard let modelName = engine.whisperModelName else {
                throw TranscriptionError.modelNotLoaded
            }
            let transcriber = WhisperTranscriber()
            try await transcriber.load(modelName: modelName) { progress, message in
                onProgress(progress, message)
            }
            whisper = transcriber
        }

        loadedEngine = engine
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard let loadedEngine else {
            throw TranscriptionError.modelNotLoaded
        }

        switch loadedEngine {
        case .parakeet:
            guard let parakeet else { throw TranscriptionError.modelNotLoaded }
            return try await parakeet.transcribe(audio)
        case .whisperSmall, .whisperTiny:
            guard let whisper else { throw TranscriptionError.modelNotLoaded }
            return try await whisper.transcribe(audio)
        }
    }

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "The selected dictation engine is not loaded."
            }
        }
    }
}
