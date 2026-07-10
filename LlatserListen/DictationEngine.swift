import Foundation

enum DictationEngine: String, CaseIterable, Identifiable {
    case parakeetV3
    case parakeetV2
    case nemotron

    var id: String { rawValue }

    static func savedValue(_ value: String?) -> DictationEngine {
        if value == "parakeet" {
            return .parakeetV3
        }
        return DictationEngine(rawValue: value ?? "") ?? .parakeetV3
    }

    var displayName: String {
        switch self {
        case .parakeetV3: return "Parakeet v3"
        case .parakeetV2: return "Parakeet v2"
        case .nemotron: return "Nemotron 0.6B"
        }
    }

    var detail: String {
        switch self {
        case .parakeetV3:
            return "Best default quality, fast on Apple Silicon."
        case .parakeetV2:
            return "Older Parakeet model for side-by-side comparison."
        case .nemotron:
            return "Experimental streaming model adapted for push-to-talk."
        }
    }

    var isExperimental: Bool {
        switch self {
        case .parakeetV3:
            return false
        case .parakeetV2, .nemotron:
            return true
        }
    }
}
