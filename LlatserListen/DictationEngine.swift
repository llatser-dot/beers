import Foundation

enum DictationEngine: String, CaseIterable, Identifiable {
    case parakeetV3
    case parakeetV2

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
        }
    }

    var detail: String {
        switch self {
        case .parakeetV3:
            return "Multilingual model for accurate everyday dictation."
        case .parakeetV2:
            return "English-only model for focused English dictation."
        }
    }

    var choiceLabel: String {
        switch self {
        case .parakeetV3: return "Multilingual"
        case .parakeetV2: return "English only"
        }
    }

    var modelSize: String {
        switch self {
        case .parakeetV3: return "~473 MB"
        case .parakeetV2: return "~443 MB"
        }
    }

    var abilitySummary: String {
        switch self {
        case .parakeetV3:
            return "The recommended multilingual model. It can transcribe English and other supported languages automatically, with strong punctuation and long-form accuracy."
        case .parakeetV2:
            return "The previous English-only Parakeet model. Choose it when you only dictate in English or want to compare its output with v3."
        }
    }

    var bestFor: String {
        switch self {
        case .parakeetV3: return "Multilingual dictation and mixed-language workflows"
        case .parakeetV2: return "English-only dictation and output comparison"
        }
    }

    var isExperimental: Bool {
        switch self {
        case .parakeetV3, .parakeetV2: return false
        }
    }
}
