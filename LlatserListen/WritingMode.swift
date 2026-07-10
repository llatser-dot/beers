import Foundation

enum WritingMode: String, CaseIterable, Identifiable {
    case automatic
    case clean
    case message
    case command

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .clean: return "Clean"
        case .message: return "Message"
        case .command: return "Command"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Matches formatting to the active app."
        case .clean:
            return "Neutral written English for notes and documents."
        case .message:
            return "Shorter, conversational text for chat."
        case .command:
            return "Direct instructions for Codex, terminals, and editors."
        }
    }
}
