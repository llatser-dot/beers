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

    /// Per-pour polish: turn rambling speech into what the speaker meant.
    /// Same tiers as orders. On any failure the caller keeps the original.
    static func polish(
        _ text: String,
        mode: WritingMode,
        context: ActiveAppContext,
        settings: AIRewriteSettings
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), text.count <= appleTierMaxChars {
            if case .available = SystemLanguageModel.default.availability {
                do {
                    let polished = try await applePolish(text, mode: mode, context: context)
                    llog("OrderKitchen: pour polished by Apple on-device model")
                    return polished
                } catch {
                    llog("OrderKitchen: Apple polish failed (\(error.localizedDescription)) — trying local endpoint")
                }
            }
        }
        #endif
        return try await AITranscriptRewriter.rewrite(text, mode: mode, context: context, settings: settings)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func applePolish(
        _ text: String,
        mode: WritingMode,
        context: ActiveAppContext
    ) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You clean up dictated speech into the text the speaker meant to write.
        The input is spoken thinking-out-loud. Apply the speaker's own corrections: \
        when they restart a sentence, change their mind ("no wait", "actually", "scratch that", \
        "I mean"), or say the same thing twice in different words, keep ONLY the final intended version.
        Remove filler ("um", "uh", "like", "you know", "basically") and false starts.
        Keep ALL substantive content — every reason, detail and aside the speaker meant. \
        Only drop words that are filler or versions the speaker corrected. When unsure, keep it.
        Keep the speaker's natural voice, tone and word choice — tidy it, don't formalise it.
        Never add information, never answer questions in the text, never explain.
        Keep names, numbers, URLs, emails and code exactly as spoken.
        Target app: \(context.name). Style: \(mode.displayName).
        Respond with ONLY the cleaned text.
        """)
        let response = try await session.respond(to: text)
        let polished = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw URLError(.zeroByteResource) }
        return polished
    }

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
