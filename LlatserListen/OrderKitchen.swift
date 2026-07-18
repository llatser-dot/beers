import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which tier ultimately produced the served text for a pour. Raw values are
/// the strings the flywheel log records verbatim.
enum ServingTier: String {
    /// Minimally sanitised Parakeet output plus the user's explicit vocabulary
    /// corrections. This is the production default: no generative model.
    case parakeetFast = "parakeet-fast"
    /// The optional legacy rule polisher served the pour. Kept as an explicit
    /// comparison mode, never the default.
    case rulePolish = "rule-polish"
    /// Historical/diagnostic tier: Bouncer served its cleaned text. Production
    /// no longer invokes it after v1/v2/v3 failed the gate.
    case bouncerShadowOnly = "bouncer-shadow-only"
    /// The ramble gate judged the pour clean and served it unchanged, no model.
    case cleanGate = "clean-gate"
    /// Apple's on-device Foundation model won the race.
    case apple = "apple"
    /// The user's configured endpoint (loopback by default) won the race.
    case local = "local"
    /// No model served — the rule-polished text stands (race failed/timed out,
    /// or AI rewrite was disabled for this pour).
    case ruleFallback = "rule-fallback"
}

/// Outcome of a per-pour polish: the served text, which tier produced it, and
/// the tier-0 Bouncer shadow verdict (nil when the shadow did not run) so the
/// caller can feed the flywheel.
struct PolishResult {
    let text: String
    let tier: ServingTier
    let shadow: BouncerVerdict?
}

/// The kitchen behind Command Mode. Tiered:
/// 1. Apple's on-device Foundation model (macOS 26+, zero setup)
/// 2. The user's approved OpenAI-compatible endpoint (loopback Ollama by default)
enum OrderKitchen {
    /// Apple's on-device context window is small; longer selections go
    /// straight to the configured endpoint.
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
                    llog("OrderKitchen: Apple model failed (\(error.localizedDescription)) — trying configured endpoint")
                }
            } else {
                llog("OrderKitchen: Apple model unavailable — trying configured endpoint")
            }
        }
        #endif

        let edited = try await AITranscriptRewriter.applyInstruction(instruction, to: text, settings: settings)
        llog("OrderKitchen: served by configured endpoint (\(settings.model))")
        return edited
    }

    /// Longest we'll ever make a pour wait on the model; past this the
    /// rule-polished text serves instead.
    private static let polishTimeout: Duration = .seconds(4)

    /// Only rambling transcripts are worth the model's latency. Clean
    /// pours (the majority) serve instantly.
    static func needsRamblePolish(_ text: String) -> Bool {
        let lower = normalizedSpoken(text)

        if hasStrongCorrections(text) { return true }

        // Immediate word repeats: "the the", "and and".
        if lower.range(of: #" (\S+) \1 "#, options: .regularExpression) != nil { return true }

        // Orphaned single-letter fragments from false starts ("make that s um").
        if lower.range(of: #" [b-hj-z] "#, options: .regularExpression) != nil { return true }

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

    /// Spoken text with punctuation stripped and whitespace collapsed,
    /// padded so ` marker ` searches match at the edges.
    private static func normalizedSpoken(_ text: String) -> String {
        " " + text.lowercased()
            .replacingOccurrences(of: #"[.,!?;:—–\-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "
    }

    /// Explicit self-corrections and restarts — the cases where a much
    /// shorter polish is legitimate because the speaker discarded words.
    private static func hasStrongCorrections(_ text: String) -> Bool {
        let lower = normalizedSpoken(text)

        let strong = [
            " no wait ", " wait no ", " actually no ", " no actually ", " scratch that ",
            " i mean ", " hang on ", " hold on ", " forget that ", " let me start again ",
            " sorry i mean ",
        ]
        if strong.contains(where: lower.contains) { return true }

        // Restarted sentences: the same three-word run appearing twice
        // ("is there no way that we... is there no way that we...").
        if lower.range(of: #" (\S+ \S+ \S+) .*\1 "#, options: .regularExpression) != nil { return true }

        return false
    }

    /// Guard against the model summarising instead of cleaning: unless the
    /// speaker explicitly discarded words, a polish that loses close to half
    /// the input has dropped sentences, not filler.
    private static func minimumKeepRatio(rawTranscript: String) -> Double {
        hasStrongCorrections(rawTranscript) ? 0.35 : 0.55
    }

    private static func keepRatio(input: String, output: String) -> Double {
        let inWords = input.split(whereSeparator: \.isWhitespace).count
        guard inWords > 0 else { return 1 }
        let outWords = output.split(whereSeparator: \.isWhitespace).count
        return Double(outWords) / Double(inWords)
    }

    /// Legacy diagnostic polish retained for `--beers-polish-test`. Production
    /// ordinary pours do not call this function; Command Mode calls only
    /// `applyInstruction`.
    static func polish(
        _ text: String,
        detectOn rawTranscript: String? = nil,
        mode: WritingMode,
        context: ActiveAppContext,
        settings: AIRewriteSettings
    ) async -> PolishResult {
        // Tier 0 — the Bouncer. Runs BEFORE the ramble gate. In this phase it
        // is SHADOW ONLY: it predicts which words it would delete and logs one
        // line per pour, but never alters the served text.
        let shadow = runBouncerShadow(text)

        // Diagnostic-only activation gate. Even a future passing bundle cannot
        // affect production unless AppState is deliberately changed to invoke
        // this legacy function again.
        if let shadow, shadow.targetMet {
            llog("OrderKitchen: pour served by tier-0 Bouncer")
            return PolishResult(text: shadow.cleanedText, tier: .bouncerShadowOnly, shadow: shadow)
        }

        // Gate on the RAW transcript: the rule polisher strips fillers
        // before we get here, hiding exactly the signals we look for.
        guard needsRamblePolish(rawTranscript ?? text) else {
            llog("OrderKitchen: clean pour — served raw, no model")
            return PolishResult(text: text, tier: .cleanGate, shadow: shadow)
        }

        let start = ContinuousClock.now
        let minKeep = minimumKeepRatio(rawTranscript: rawTranscript ?? text)
        do {
            let (tier, polished) = try await withDeadline(polishTimeout) {
                try await racePolish(text, minKeepRatio: minKeep, mode: mode, context: context, settings: settings)
            }
            llog("OrderKitchen: pour polished by \(tier) in \(elapsed(since: start))")
            let servingTier: ServingTier = tier.hasPrefix("Apple") ? .apple : .local
            return PolishResult(text: polished, tier: servingTier, shadow: shadow)
        } catch {
            // Deadline exceeded or no tier available: keep the rule-polished text.
            llog("OrderKitchen: no model served (\(error)) — keeping rule-polished text")
            return PolishResult(text: text, tier: .ruleFallback, shadow: shadow)
        }
    }

    /// Tier-0 Bouncer, SHADOW MODE. Runs one inference, logs exactly one line
    /// per pour, and returns the verdict (or nil when disabled or the model
    /// files are absent) so the caller can both decide activation and log the
    /// shadow prediction to the flywheel. Catches everything: a broken or
    /// missing model must never affect a pour.
    private static func runBouncerShadow(_ text: String) -> BouncerVerdict? {
        // Opt-out switch; defaults on (absent key == enabled).
        let enabled = UserDefaults.standard.object(forKey: "bouncerShadowEnabled") == nil
            || UserDefaults.standard.bool(forKey: "bouncerShadowEnabled")
        guard enabled else { return nil }

        let verdict = Bouncer.review(text)
        guard verdict.modelAvailable else { return nil }  // model files absent -> skip silently

        let ms = String(format: "%.1f", verdict.elapsedMillis)
        if verdict.didFire {
            let deleted = verdict.deletedIndices.map { i in
                "\(verdict.words[i])@\(String(format: "%.2f", verdict.deleteProbabilities[i]))"
            }.joined(separator: ", ")
            llog("Bouncer[shadow]: would delete \(verdict.deletedIndices.count) words: [\(deleted)] in \(ms)ms")
        } else {
            llog("Bouncer[shadow]: clean pour, 0 deletions in \(ms)ms")
        }
        return verdict
    }

    private struct KitchenClosed: Error {}

    /// Run every available tier at once under the caller's single deadline —
    /// first acceptable result serves. Sequential fallback used to stack two
    /// full timeouts before giving up.
    private static func racePolish(
        _ text: String,
        minKeepRatio: Double,
        mode: WritingMode,
        context: ActiveAppContext,
        settings: AIRewriteSettings
    ) async throws -> (tier: String, text: String) {
        try await withThrowingTaskGroup(of: (tier: String, output: String?).self) { group in
            var tiers = 0
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), text.count <= appleTierMaxChars,
               case .available = SystemLanguageModel.default.availability {
                tiers += 1
                group.addTask {
                    do {
                        return ("Apple model", try await applePolish(text, mode: mode, context: context))
                    } catch {
                        if !(error is CancellationError) {
                            llog("OrderKitchen: Apple polish failed (\(error.localizedDescription))")
                        }
                        return ("Apple model", nil)
                    }
                }
            }
            #endif
            if settings.isEnabled {
                let tier = "local model (\(settings.model))"
                tiers += 1
                group.addTask {
                    do {
                        return (tier, try await AITranscriptRewriter.rewrite(text, mode: mode, context: context, settings: settings))
                    } catch {
                        if !(error is CancellationError) {
                            llog("OrderKitchen: local polish failed (\(error.localizedDescription))")
                        }
                        return (tier, nil)
                    }
                }
            }
            guard tiers > 0 else { throw KitchenClosed() }

            defer { group.cancelAll() }
            for try await result in group {
                guard let output = result.output else { continue }
                let ratio = keepRatio(input: text, output: output)
                if ratio >= minKeepRatio {
                    return (result.tier, output)
                }
                llog("OrderKitchen: \(result.tier) kept only \(Int(ratio * 100))% of the words — rejected as over-trimmed")
            }
            throw KitchenClosed()
        }
    }

    /// Load the models while the user is still speaking so generation can
    /// start the instant transcription lands.
    static func prewarmPolish(settings: AIRewriteSettings) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                let session = LanguageModelSession(instructions: polishInstructions())
                session.prewarm()
                prewarmedPolishSession = session
            }
        }
        #endif
        AITranscriptRewriter.prewarm(settings: settings)
        // Tier-0 Bouncer: warm the Core ML model off the main thread so the
        // first pour's shadow pass costs a few ms, not the cold ~600ms.
        Task.detached(priority: .utility) { Bouncer.prewarm() }
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
        Never summarise, condense or shorten: apart from removed filler and corrected restarts, \
        keep every sentence, so the output is nearly as long as the input. \
        Never drop the first or last sentence. When unsure, keep it.
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
