import Foundation

struct VocabularyCorrection: Identifiable, Codable, Equatable {
    let id: UUID
    var heard: String
    var replacement: String

    init(id: UUID = UUID(), heard: String, replacement: String) {
        self.id = id
        self.heard = heard
        self.replacement = replacement
    }
}

enum VocabularyCorrections {
    private static let correctionsKey = "vocabularyCorrections"
    private static let seedVersionKey = "vocabularyCorrectionsSeedVersion"
    private static let currentSeedVersion = 4

    private static let seededCorrections = [
        VocabularyCorrection(heard: "dot co dot uk", replacement: ".co.uk"),
        VocabularyCorrection(heard: "dot gov dot uk", replacement: ".gov.uk"),
        VocabularyCorrection(heard: "dot ac dot uk", replacement: ".ac.uk"),
        VocabularyCorrection(heard: "dot com", replacement: ".com"),
        VocabularyCorrection(heard: "dot info", replacement: ".info"),
        VocabularyCorrection(heard: "dot org", replacement: ".org"),
        VocabularyCorrection(heard: "dot net", replacement: ".net"),
        VocabularyCorrection(heard: "dot ai", replacement: ".ai"),
        VocabularyCorrection(heard: "dot io", replacement: ".io"),
        VocabularyCorrection(heard: "dot dev", replacement: ".dev"),
        VocabularyCorrection(heard: "dot co", replacement: ".co"),
        VocabularyCorrection(heard: "dot uk", replacement: ".uk"),
        VocabularyCorrection(heard: "dot", replacement: "."),
        VocabularyCorrection(heard: "Latsa Listen", replacement: "Beers"),
        VocabularyCorrection(heard: "Latsa", replacement: "Llatser"),
        VocabularyCorrection(heard: "Latser", replacement: "Llatser"),
        VocabularyCorrection(heard: "Latsir", replacement: "Llatser"),
        VocabularyCorrection(heard: "Ladser", replacement: "Llatser")
    ]

    static func ensureSeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: seedVersionKey) < currentSeedVersion else { return }

        var corrections = load()
        for seed in seededCorrections where !contains(corrections, heard: seed.heard) {
            corrections.append(seed)
        }

        save(corrections)
        defaults.set(currentSeedVersion, forKey: seedVersionKey)
    }

    static func load() -> [VocabularyCorrection] {
        guard let data = UserDefaults.standard.data(forKey: correctionsKey) else {
            return []
        }

        return (try? JSONDecoder().decode([VocabularyCorrection].self, from: data)) ?? []
    }

    static func save(_ corrections: [VocabularyCorrection]) {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        UserDefaults.standard.set(data, forKey: correctionsKey)
    }

    static func apply(to text: String) -> String {
        let corrections = load()
            .filter { !$0.heard.trimmed.isEmpty && !$0.replacement.trimmed.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }

        guard !corrections.isEmpty else { return text }

        var result = text
        for correction in corrections {
            result = apply(correction, to: result)
        }
        return applyPhoneticFallback(corrections, to: result)
    }

    private static func contains(_ corrections: [VocabularyCorrection], heard: String) -> Bool {
        corrections.contains { $0.heard.trimmed.caseInsensitiveCompare(heard.trimmed) == .orderedSame }
    }

    /// Catches mishearings the user never listed: any standalone word that *sounds like*
    /// a correction's heard word or its replacement gets corrected too, so one
    /// "groc → Grok" entry also fixes "Crock", "Grock", "Kroc", etc.
    private static func applyPhoneticFallback(
        _ corrections: [VocabularyCorrection],
        to text: String
    ) -> String {
        var keyMap: [String: VocabularyCorrection] = [:]
        for correction in corrections {
            for word in [correction.replacement.trimmed, correction.heard.trimmed] {
                if let key = phoneticKey(for: word), keyMap[key] == nil {
                    keyMap[key] = correction
                }
            }
        }

        guard !keyMap.isEmpty else { return text }

        return replaceMatches(in: text, pattern: #"[A-Za-z]{3,}"#) { token in
            guard let key = phoneticKey(for: token),
                  let correction = keyMap[key],
                  token.caseInsensitiveCompare(correction.replacement.trimmed) != .orderedSame else {
                return token
            }
            return smartCased(correction.replacement.trimmed, matching: token)
        }
    }

    /// Loose sound-alike key: single word only, voiced/voiceless stops merged (c/q/g→k),
    /// z→s, y→i, doubled consonants collapsed (vowel pairs kept so crook ≠ crock),
    /// trailing silent e dropped.
    private static func phoneticKey(for word: String) -> String? {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter }) else { return nil }

        var mapped = ""
        for character in word.lowercased() {
            switch character {
            case "c", "q", "g": mapped.append("k")
            case "z": mapped.append("s")
            case "y": mapped.append("i")
            default: mapped.append(character)
            }
        }

        var key = ""
        for character in mapped {
            if character == key.last, !"aeiou".contains(character) { continue }
            key.append(character)
        }
        if key.count > 3, key.last == "e" {
            key.removeLast()
        }
        return key
    }

    /// A replacement stored in lowercase inherits capitalisation from the token it
    /// replaces; a replacement with explicit casing (ChatGPT, Llatser) is kept verbatim.
    private static func smartCased(_ replacement: String, matching token: String) -> String {
        guard let tokenFirst = token.first, tokenFirst.isUppercase,
              replacement == replacement.lowercased(),
              let replacementFirst = replacement.first, replacementFirst.isLetter else {
            return replacement
        }
        return replacementFirst.uppercased() + replacement.dropFirst()
    }

    private static func apply(_ correction: VocabularyCorrection, to text: String) -> String {
        let heardTokens = correction.heard.trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !heardTokens.isEmpty else { return text }

        let phrase = heardTokens
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"(?:[\s.\-]+)"#)
        let pattern = #"(?i)(^|[^A-Za-z0-9])"# + phrase + #"(?=$|[^A-Za-z0-9])"#

        return replaceMatches(in: text, pattern: pattern) { match in
            guard let first = match.first, !first.isLetter, !first.isNumber else {
                return smartCased(correction.replacement, matching: match)
            }
            if first.isWhitespace, correction.replacement.first == "." {
                return correction.replacement
            }
            return "\(first)\(smartCased(correction.replacement, matching: String(match.dropFirst())))"
        }
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        replacement: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result = ""
        var cursor = 0

        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            result += replacement(source.substring(with: range))
            cursor = range.location + range.length
        }

        if cursor < source.length {
            result += source.substring(from: cursor)
        }

        return result
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
