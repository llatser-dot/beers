import Foundation

enum DictationEngine: String, CaseIterable, Identifiable {
    case parakeet
    case whisperSmall
    case whisperTiny

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .whisperSmall: return "Whisper small"
        case .whisperTiny: return "Whisper tiny"
        }
    }

    var detail: String {
        switch self {
        case .parakeet:
            return "Highest quality here, fast on Apple Silicon"
        case .whisperSmall:
            return "Whisper fallback, better than tiny"
        case .whisperTiny:
            return "Fastest Whisper comparison"
        }
    }

    var whisperModelName: String? {
        switch self {
        case .parakeet: return nil
        case .whisperSmall: return "small"
        case .whisperTiny: return "tiny"
        }
    }
}
