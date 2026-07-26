import Foundation

/// One correction-driven vocabulary suggestion: the app repeatedly saw the user
/// type `replacement` where a pour served `heard`, and the two words look like a
/// vocabulary miss (a brand / name / merged term), not grammar or cleanup.
struct VocabularySuggestion: Identifiable, Equatable {
    let heard: String        // what was served, e.g. "plan watch"
    let replacement: String  // what the user typed instead, e.g. "PlanWatch"
    let count: Int           // times this exact fix recurred (>= 2)

    /// Stable identity + the key persisted in the dismissed set. Case-folded on
    /// `heard` so "Plan"/"plan" collapse; `replacement` kept verbatim (casing is
    /// the whole point of a brand fix).
    var id: String { VocabularySuggestions.key(heard: heard, replacement: replacement) }
}

/// Scans the local flywheel correction log for recurring word-level fixes that
/// read as VOCABULARY the user should teach Beers, and surfaces them as one-tap
/// suggestions in Brew Controls. Read-only over the flywheel; it never writes to
/// it, never adds vocabulary on its own, and — like everything flywheel — never
/// leaves the Mac.
///
/// Two shapes qualify (both must recur >= 2 times):
///   1. Substitution — a single changedWords entry `[i, old, new]` where `old`
///      and `new` are one word each, phonetically/orthographically related
///      (shared consonant-skeleton or 3-char prefix) and `new` carries a
///      brand/proper-noun capital. Catches "Latzra" -> "Llatser".
///   2. Merge — a contiguous run of changedWords collapsing a multi-word span
///      into one brand token, e.g. `[2,"plan",null],[3,"watch","PlanWatch"]`.
///
/// Excluded: pure sentence-start casing ("i" -> "I"), punctuation-only edits,
/// pure deletions (the Bouncer's job), and anything already in the user's
/// dictionary or previously dismissed.
enum VocabularySuggestions {
    /// A parsed word edit from a `changedWords` triple. `new == nil` == deletion.
    private struct WordChange {
        let index: Int
        let old: String
        let new: String?
    }

    /// (heard, replacement) -> running tally, keyed case-folded on heard.
    private struct PairTally {
        let heard: String
        let replacement: String
        var count: Int
    }

    /// File-signature-guarded cache of the parsed tallies so opening Brew
    /// Controls repeatedly never re-reads the log unless it actually changed.
    private static var cache: (signature: String, tallies: [String: PairTally])?
    private static let cacheLock = NSLock()

    private static let dismissedKey = "vocabularySuggestionsDismissed"

    // MARK: - Public API

    /// Suggestions for the given dictionary + dismissed set, best first, capped.
    /// Cheap on repeat calls: the log is only re-parsed when its files change.
    static func suggestions(
        existing: [VocabularyCorrection],
        dismissed: Set<String>,
        dir: URL? = nil,
        limit: Int = 5
    ) -> [VocabularySuggestion] {
        let directory = dir ?? supportDir()
        let tallies = talliesForDirectory(directory)

        let takenReplacements = Set(existing.map { $0.replacement.lowercased() })
        let takenHeards = Set(existing.map { $0.heard.lowercased() })

        let matches = tallies.values
            .filter { $0.count >= 2 }
            .filter { !takenReplacements.contains($0.replacement.lowercased()) }
            .filter { !takenHeards.contains($0.heard.lowercased()) }
            .filter { !dismissed.contains(key(heard: $0.heard, replacement: $0.replacement)) }
            .map { VocabularySuggestion(heard: $0.heard, replacement: $0.replacement, count: $0.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.replacement.localizedCaseInsensitiveCompare($1.replacement) == .orderedAscending
            }

        return Array(matches.prefix(limit))
    }

    static func key(heard: String, replacement: String) -> String {
        "\(heard.lowercased())\u{0}\(replacement)"
    }

    // MARK: - Dismissed set (persisted)

    static func dismissedKeys() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        return Set(arr)
    }

    static func dismiss(_ suggestion: VocabularySuggestion) {
        var set = dismissedKeys()
        set.insert(suggestion.id)
        UserDefaults.standard.set(Array(set), forKey: dismissedKey)
    }

    // MARK: - Scan (with file-signature cache)

    private static func talliesForDirectory(_ dir: URL) -> [String: PairTally] {
        let files = flywheelFiles(in: dir)
        let signature = files.map(fileSignature).joined(separator: "|")

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache, cache.signature == signature {
            return cache.tallies
        }

        var tallies: [String: PairTally] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                tally(line: String(line), into: &tallies)
            }
        }

        cache = (signature, tallies)
        return tallies
    }

    /// Live log plus every rotation, oldest names first (stable ordering).
    private static func flywheelFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let matching = names
            .filter { $0 == "flywheel.jsonl" || ($0.hasPrefix("flywheel-") && $0.hasSuffix(".jsonl")) }
            .sorted()
        return matching.map { dir.appendingPathComponent($0) }
    }

    private static func fileSignature(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent):\(size):\(mtime)"
    }

    private static func supportDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Beers", isDirectory: true)
    }

    // MARK: - Per-record extraction

    private static func tally(line: String, into tallies: inout [String: PairTally]) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "correction",
              let rawChanges = obj["changedWords"] as? [[Any]] else { return }

        let changes = rawChanges.compactMap { parseChange($0) }.sorted { $0.index < $1.index }
        guard !changes.isEmpty else { return }

        for (heard, replacement) in vocabularyPairs(from: changes) {
            let k = key(heard: heard, replacement: replacement)
            if var existing = tallies[k] {
                existing.count += 1
                tallies[k] = existing
            } else {
                tallies[k] = PairTally(heard: heard, replacement: replacement, count: 1)
            }
        }
    }

    private static func parseChange(_ triple: [Any]) -> WordChange? {
        guard triple.count == 3 else { return nil }
        guard let index = (triple[0] as? NSNumber)?.intValue else { return nil }
        guard let old = triple[1] as? String else { return nil }
        let new = triple[2] as? String   // NSNull -> nil == deletion
        return WordChange(index: index, old: old, new: new)
    }

    /// Group a record's changes into contiguous index-runs and pull out the ones
    /// that read as vocabulary (substitution or merge).
    private static func vocabularyPairs(from changes: [WordChange]) -> [(String, String)] {
        var pairs: [(String, String)] = []

        var run: [WordChange] = []
        func flush() {
            if let pair = vocabularyPair(fromRun: run) { pairs.append(pair) }
            run = []
        }
        for change in changes {
            if let last = run.last, change.index != last.index + 1 {
                flush()
            }
            run.append(change)
        }
        flush()

        return pairs
    }

    private static func vocabularyPair(fromRun run: [WordChange]) -> (String, String)? {
        guard !run.isEmpty else { return nil }
        let subs = run.filter { $0.new != nil }
        let dels = run.filter { $0.new == nil }

        // Merge: a run that collapses a multi-word span into one brand token.
        if run.count >= 2, subs.count == 1, !dels.isEmpty {
            guard let replacement = subs.first?.new?.trimmed, !replacement.isEmpty else { return nil }
            let heard = run.map { $0.old.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
            guard isMerge(heard: heard, replacement: replacement) else { return nil }
            return (heard, replacement)
        }

        // Substitution: exactly one word swapped for one word.
        if run.count == 1, let only = run.first, let new = only.new?.trimmed {
            let old = only.old.trimmed
            guard isSubstitution(old: old, new: new) else { return nil }
            return (old, new)
        }

        return nil
    }

    // MARK: - Vocabulary heuristics

    /// A single-word swap reads as vocabulary when old/new are related in sound
    /// or spelling, the replacement carries a brand/proper-noun capital, and it
    /// is not merely a casing fix.
    private static func isSubstitution(old: String, new: String) -> Bool {
        guard isWord(old), isWord(new) else { return false }
        guard old.lowercased() != new.lowercased() else { return false }   // pure casing ("i" -> "I")
        guard hasBrandCapital(new) else { return false }                    // proper-noun / brand signal
        guard old.split(whereSeparator: \.isWhitespace).count == 1,
              new.split(whereSeparator: \.isWhitespace).count == 1 else { return false }
        return related(old, new)
    }

    /// A merge reads as vocabulary when the target is one token that either
    /// carries an internal capital (CamelCase brand) or is the joined span
    /// glued together (skeleton or letter match).
    private static func isMerge(heard: String, replacement: String) -> Bool {
        guard isWord(replacement) else { return false }
        guard !replacement.contains(where: { $0.isWhitespace }) else { return false }
        let glued = heard.filter { !$0.isWhitespace }.lowercased()
        if replacement.lowercased() == glued { return true }
        if consonantSkeleton(replacement) == consonantSkeleton(glued) { return true }
        return hasInternalCapital(replacement)
    }

    private static func isWord(_ s: String) -> Bool {
        s.contains(where: { $0.isLetter })
    }

    /// True when the string has an uppercase letter (a name/brand signal). Note a
    /// pure sentence-start casing fix is already excluded before this is reached.
    private static func hasBrandCapital(_ s: String) -> Bool {
        s.contains(where: { $0.isUppercase })
    }

    /// True when an uppercase letter appears after the first character (CamelCase).
    private static func hasInternalCapital(_ s: String) -> Bool {
        s.dropFirst().contains(where: { $0.isUppercase })
    }

    private static func related(_ a: String, _ b: String) -> Bool {
        let sa = consonantSkeleton(a), sb = consonantSkeleton(b)
        if !sa.isEmpty, sa == sb { return true }
        let la = a.lowercased(), lb = b.lowercased()
        if la.count >= 3, lb.count >= 3, la.prefix(3) == lb.prefix(3) { return true }
        return false
    }

    /// Loose consonant skeleton: lowercase, drop vowels + y, fold c/q/g -> k and
    /// z -> s, collapse doubles. "latzra" and "llatser" both reduce to "ltsr".
    private static func consonantSkeleton(_ s: String) -> String {
        var out = ""
        for raw in s.lowercased() where raw.isLetter {
            if "aeiouy".contains(raw) { continue }
            let mapped: Character
            switch raw {
            case "c", "q", "g": mapped = "k"
            case "z": mapped = "s"
            default: mapped = raw
            }
            if out.last == mapped { continue }
            out.append(mapped)
        }
        return out
    }

    // MARK: - Test seam

    /// Feeds `records` (one JSON object per element) into a temp log, scans it,
    /// and returns the suggestions — used by the `--beers-vocab-suggest-test`
    /// hook. Purely local; nothing touches the real flywheel.
    static func runScan(onRecords records: [String], existing: [VocabularyCorrection]) -> [VocabularySuggestion] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beers-vocab-suggest-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let log = tmp.appendingPathComponent("flywheel.jsonl")
        try? records.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        // Bypass the signature cache for the isolated temp dir by clearing it.
        cacheLock.lock(); cache = nil; cacheLock.unlock()
        let result = suggestions(existing: existing, dismissed: [], dir: tmp, limit: 10)
        try? FileManager.default.removeItem(at: tmp)
        cacheLock.lock(); cache = nil; cacheLock.unlock()
        return result
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
