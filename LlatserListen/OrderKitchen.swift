import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The kitchen behind Command Mode. Tiered:
/// 1. Apple's on-device Foundation model (macOS 26+, zero setup)
/// 2. The user's OpenAI-compatible local endpoint (Ollama etc.)
enum OrderKitchen {
    /// Apple's on-device context window is small; longer selections go
    /// straight to the local endpoint.
    private static let appleTierMaxChars = 6000

    static func applyInstruction(
        _ instruction: String,
        to text: String,
        settings: AIRewriteSettings
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), text.count <= appleTierMaxChars {
            if case .available = SystemLanguageModel.default.availability {
                do {
                    let edited = try await appleEdit(instruction, text)
                    llog("OrderKitchen: served by Apple on-device model")
                    return edited
                } catch {
                    llog("OrderKitchen: Apple model failed (\(error.localizedDescription)) — trying local endpoint")
                }
            } else {
                llog("OrderKitchen: Apple model unavailable — trying local endpoint")
            }
        }
        #endif

        let edited = try await AITranscriptRewriter.applyInstruction(instruction, to: text, settings: settings)
        llog("OrderKitchen: served by local endpoint (\(settings.model))")
        return edited
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func appleEdit(_ instruction: String, _ text: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You edit text. Apply the user's instruction to the provided text.
        Respond with ONLY the edited text — no explanations, no preamble, no quotes, no code fences.
        Apply the instruction proportionately: change what it asks for and nothing more. \
        Keep the result natural — never stiff, flowery or exaggerated.
        Preserve meaning, names, numbers, URLs and formatting unless the instruction says otherwise.
        """)
        let response = try await session.respond(
            to: "INSTRUCTION: \(instruction)\n\nTEXT:\n\(text)"
        )
        let edited = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { throw URLError(.zeroByteResource) }
        return edited
    }
    #endif
}
