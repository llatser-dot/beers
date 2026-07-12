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

    /// Longest we'll ever make a pour wait on the model; past this the
    /// rule-polished text serves instead.
    private static let polishTimeout: Duration = .seconds(4)

    /// Only rambling transcripts are worth the model's latency. Clean
    /// pours (the majority) serve instantly.
    static func needsRamblePolish(_ text: String) -> Bool {
        let lower = " " + text.lowercased()
            .replacingOccurrences(of: #"[.,!?;:—–\-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "

        let strong = [
            " no wait ", " wait no ", " actually no ", " no actually ", " scratch that ",
            " i mean ", " hang on ", " hold on ", " forget that ", " let me start again ",
            " sorry i mean ",
        ]
        if strong.contains(where: lower.contains) { return true }

        // Immediate word repeats: "the the", "and and".
        if lower.range(of: #" (\S+) \1 "#, options: .regularExpression) != nil { return true }

        let weak = [" um ", " uh ", " erm ", " basically ", " you know ", " kind of like ", " sort of like "]
        let weakCount = weak.filter(lower.contains).count
        if weakCount >= 2 { return true }

        // Long think-aloud passages usually want rewording; one filler in a
        // long take also qualifies.
        let words = text.split(separator: " ").count
        if words > 35 { return true }
        if weakCount >= 1 && words > 12 { return true }

        return false
    }

    /// Per-pour polish: turn rambling speech into what the speaker meant.
    /// Same tiers as orders. On any failure the caller keeps the original.
    static func polish(
        _ text: String,
        mode: WritingMode,
        context: ActiveAppContext,
        settings: AIRewriteSettings
    ) async throws -> String {
        guard needsRamblePolish(text) else {
            llog("OrderKitchen: clean pour — served raw, no model")
            return text
        }

        let start = ContinuousClock.now
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), text.count <= appleTierMaxChars {
            if case .available = SystemLanguageModel.default.availability {
                do {
                    let polished = try await withDeadline(polishTimeout) {
                        try await applePolish(text, mode: mode, context: context)
                    }
                    llog("OrderKitchen: pour polished by Apple model in \(elapsed(since: start))")
                    return polished
                } catch {
                    llog("OrderKitchen: Apple polish failed after \(elapsed(since: start)) (\(error.localizedDescription)) — trying local endpoint")
                }
            }
        }
        #endif
        let polished = try await withDeadline(polishTimeout) {
            try await AITranscriptRewriter.rewrite(text, mode: mode, context: context, settings: settings)
        }
        llog("OrderKitchen: pour polished by local endpoint in \(elapsed(since: start))")
        return polished
    }

    /// Load the model while the user is still speaking so generation can
    /// start the instant transcription lands.
    static func prewarmPolish() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                let session = LanguageModelSession(instructions: polishInstructions())
                session.prewarm()
                prewarmedPolishSession = session
            }
        }
        #endif
    }

    private static var prewarmedPolishSession: Any?

    private struct DeadlineExceeded: Error {}

    private static func withDeadline<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw DeadlineExceeded()
            }
            guard let result = try await group.next() else { throw DeadlineExceeded() }
            group.cancelAll()
            return result
        }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> String {
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        return "\(Int(ms))ms"
    }

    private static func polishInstructions() -> String {
        """
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
        Respond with ONLY the cleaned text.
        """
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func applePolish(
        _ text: String,
        mode: WritingMode,
        context: ActiveAppContext
    ) async throws -> String {
        // Use the session prewarmed during recording when there is one;
        // sessions accrue context, so each serves exactly one pour.
        let session = (prewarmedPolishSession as? LanguageModelSession)
            ?? LanguageModelSession(instructions: polishInstructions())
        prewarmedPolishSession = nil

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
