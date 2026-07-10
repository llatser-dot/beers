import Foundation

enum TranscriptPolisher {
    struct Options {
        var cleanSpeechScaffolding: Bool
        var collapseRepeats: Bool
        var smartCapitalization: Bool
        var normalizeLinks: Bool
        var removeTrailingFullStop: Bool
        var adaptiveTone: Bool
        var mode: WritingMode

        static let defaults = Options(
            cleanSpeechScaffolding: true,
            collapseRepeats: true,
            smartCapitalization: true,
            normalizeLinks: true,
            removeTrailingFullStop: true,
            adaptiveTone: true,
            mode: .automatic
        )
    }

    private static let domainSuffixPattern = #"co\.uk|gov\.uk|ac\.uk|com|info|org|net|ai|io|dev|co|uk"#
    private static let domainPattern = #"(?:https?://)?[a-z0-9][a-z0-9.-]*\.(?:"# + domainSuffixPattern + #")"#

    static func polish(_ text: String) -> String {
        polish(text, options: .defaults, context: nil)
    }

    static func polish(_ text: String, options: Options, context: ActiveAppContext?) -> String {
        let original = tidy(text)
        guard !original.isEmpty else { return "" }

        var result = original
        let mode = resolvedMode(from: options, context: context)

        if options.cleanSpeechScaffolding {
            result = removeSpeechScaffolding(from: result)
        }
        result = applyPhraseReplacements(to: result)
        if options.collapseRepeats {
            result = collapseRepeatedWords(in: result)
            result = collapseRepeatedPhrases(in: result)
        }
        result = tidy(result)
        if options.adaptiveTone {
            result = applyAdaptiveTone(to: result, mode: mode)
        }
        if options.smartCapitalization {
            result = capitalizeSentences(in: result)
        }
        if options.normalizeLinks {
            result = normalizeDomainSuffixes(in: result)
        }
        result = tidy(result)
        if options.normalizeLinks {
            result = normalizeUrlsAndEmails(in: result)
        }
        if options.removeTrailingFullStop {
            result = removeTerminalFullStop(from: result)
        }

        return result.isEmpty ? original : result
    }

    private static func resolvedMode(from options: Options, context: ActiveAppContext?) -> WritingMode {
        guard options.mode == .automatic else { return options.mode }
        return context?.inferredWritingMode ?? .clean
    }

    private static func removeSpeechScaffolding(from text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)\b(?:i mean|you know|sort of|kind of)\b[,\s]*"#,
            #"(?i)\b(?:basically|actually|obviously)\b[,\s]*"#
        ]

        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    private static func collapseRepeatedWords(in text: String) -> String {
        var result = text
        var previous = ""

        while previous != result {
            previous = result
            result = result.replacingOccurrences(
                of: #"(?i)\b([a-z][a-z']*)\s+\1\b"#,
                with: "$1",
                options: .regularExpression
            )
        }

        return result
    }

    private static func collapseRepeatedPhrases(in text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        var index = 0

        while index < words.count {
            var collapsed = false
            let maxLength = min(6, (words.count - index) / 2)

            if maxLength >= 2 {
                for length in stride(from: maxLength, through: 2, by: -1) {
                    let first = words[index..<(index + length)].map(normalizedToken)
                    let second = words[(index + length)..<(index + length * 2)].map(normalizedToken)

                    if first == second {
                        words.removeSubrange((index + length)..<(index + length * 2))
                        collapsed = true
                        break
                    }
                }
            }

            if !collapsed {
                index += 1
            }
        }

        return words.joined(separator: " ")
    }

    private static func normalizedToken(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func applyPhraseReplacements(to text: String) -> String {
        var result = text
        let replacements: [(pattern: String, replacement: String)] = [
            (#"(?i)^i wonder if (?:there'?s|there is) (?:a |any )?way (?:that )?we can\b"#, "Can we"),
            (#"(?i)^is there (?:a |any )?way (?:that )?we can\b"#, "Can we"),
            (#"(?i)\bi wonder if this will be\b"#, "will this be"),
            (#"(?i)\bi wonder if it will be\b"#, "will it be"),
            (#"(?i)\bi wonder if we can\b"#, "can we"),
            (#"(?i)\bi wonder if there is\b"#, "is there"),
            (#"(?i)\bi wonder if there are\b"#, "are there"),
            (#"(?i)\bwill this be i suppose not really faster but i wonder if it will keep up\b"#, "I suppose it won't be faster, but I wonder if it will keep up"),
            (#"(?i)\bprevious one that we had\b"#, "previous one we had"),
            (#"(?i)^i want to\b"#, "I want to"),
            (#"(?i)^i need to\b"#, "I need to"),
            (#"(?i)^i want you to\b"#, "I want you to"),
            (#"(?i)\bokay lets\b"#, "Okay, let's"),
            (#"(?i)\bokay let's\b"#, "Okay, let's"),
            (#"(?i)^lets\b"#, "Let's"),
            (#"(?i)\blet's go ahead and\b"#, "Let's"),
            (#"(?i)\bgo ahead and\b"#, ""),
            (#"(?i)\bim\b"#, "I'm"),
            (#"(?i)\bi'm\b"#, "I'm"),
            (#"(?i)\bive\b"#, "I've"),
            (#"(?i)\bi've\b"#, "I've"),
            (#"(?i)\bid\b"#, "I'd"),
            (#"(?i)\bi'd\b"#, "I'd"),
            (#"(?i)\bi\b"#, "I"),
            (#"(?i)\bllatser listen\b"#, "Llatser Listen"),
            (#"(?i)\bllatser\b"#, "Llatser"),
            (#"(?i)\bparakey\b"#, "Parakeet"),
            (#"(?i)\bparakeet\b"#, "Parakeet"),
            (#"(?i)\bchat gpt\b"#, "ChatGPT"),
            (#"(?i)\bcodex\b"#, "Codex")
        ]

        for replacement in replacements {
            result = result.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: .regularExpression
            )
        }

        return result
    }

    private static func applyAdaptiveTone(to text: String, mode: WritingMode) -> String {
        switch mode {
        case .automatic, .clean:
            return text
        case .message:
            return conversationalText(from: text)
        case .command:
            return commandText(from: text)
        }
    }

    private static func conversationalText(from text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"(?i)^could you please\b"#, "Can you"),
            (#"(?i)^would you be able to\b"#, "Can you"),
            (#"(?i)\bthank you very much\b"#, "thanks"),
            (#"(?i)\bplease let me know\b"#, "let me know")
        ]

        for replacement in replacements {
            result = result.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }

        return result
    }

    private static func commandText(from text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"(?i)^can you please\b"#, "Can you"),
            (#"(?i)^could you please\b"#, "Can you"),
            (#"(?i)^please can you\b"#, "Can you"),
            (#"(?i)^i need you to\b"#, "Please"),
            (#"(?i)^i want you to\b"#, "Please"),
            (#"(?i)\bwhen you get a chance\b"#, ""),
            (#"(?i)\bif possible\b"#, "")
        ]

        for replacement in replacements {
            result = result.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }

        return tidy(result)
    }

    private static func capitalizeSentences(in text: String) -> String {
        var result = ""
        var shouldCapitalize = true

        for character in text {
            let string = String(character)

            if shouldCapitalize, string.rangeOfCharacter(from: .letters) != nil {
                result += string.uppercased()
                shouldCapitalize = false
                continue
            }

            result += string

            if ".!?".contains(character) {
                shouldCapitalize = true
            } else if !character.isWhitespace {
                shouldCapitalize = false
            }
        }

        return result
    }

    private static func removeTerminalFullStop(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.last == "." {
            result.removeLast()
        }
        return result
    }

    private static func normalizeDomainSuffixes(in text: String) -> String {
        var result = text
        let replacements: [(pattern: String, replacement: String)] = [
            (#"(?i)\bdot\s+co\s+dot\s+uk\b\.?"#, ".co.uk"),
            (#"(?i)\bdot\s+gov\s+dot\s+uk\b\.?"#, ".gov.uk"),
            (#"(?i)\bdot\s+ac\s+dot\s+uk\b\.?"#, ".ac.uk"),
            (#"(?i)\bdot\s+com\b\.?"#, ".com"),
            (#"(?i)\bdot\s+info\b\.?"#, ".info"),
            (#"(?i)\bdot\s+org\b\.?"#, ".org"),
            (#"(?i)\bdot\s+net\b\.?"#, ".net"),
            (#"(?i)\bdot\s+ai\b\.?"#, ".ai"),
            (#"(?i)\bdot\s+io\b\.?"#, ".io"),
            (#"(?i)\bdot\s+dev\b\.?"#, ".dev"),
            (#"(?i)\bdot\s+co\b(?!\s+dot\s+uk)\.?"#, ".co"),
            (#"(?i)\bdot\s+uk\b\.?"#, ".uk"),
            (#"(?i)\.\s*co\s*\.\s*uk\b\.?"#, ".co.uk"),
            (#"(?i)\.\s*gov\s*\.\s*uk\b\.?"#, ".gov.uk"),
            (#"(?i)\.\s*ac\s*\.\s*uk\b\.?"#, ".ac.uk"),
            (#"(?i)\.\s*com\b\.?"#, ".com"),
            (#"(?i)\.\s*info\b\.?"#, ".info"),
            (#"(?i)\.\s*org\b\.?"#, ".org"),
            (#"(?i)\.\s*net\b\.?"#, ".net"),
            (#"(?i)\.\s*ai\b\.?"#, ".ai"),
            (#"(?i)\.\s*io\b\.?"#, ".io"),
            (#"(?i)\.\s*dev\b\.?"#, ".dev"),
            (#"(?i)\.\s*co\b(?!\s*\.\s*uk)\.?"#, ".co"),
            (#"(?i)\.\s*uk\b\.?"#, ".uk")
        ]

        for replacement in replacements {
            result = result.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: .regularExpression
            )
        }

        return result
    }

    private static func normalizeUrlsAndEmails(in text: String) -> String {
        var result = text

        let directReplacements: [(pattern: String, replacement: String)] = [
            (#"(?i)\bhttps\s+colon\s+(?:forward\s+)?slash(?:\s+(?:forward\s+)?slash)?\s*"#, "https://"),
            (#"(?i)\bhttp\s+colon\s+(?:forward\s+)?slash(?:\s+(?:forward\s+)?slash)?\s*"#, "http://")
        ]

        for replacement in directReplacements {
            result = result.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: .regularExpression
            )
        }

        let emailPattern = #"(?i)\b([a-z0-9._%+\-]+)\s+at\s+([a-z0-9][a-z0-9.-]*\.(?:"# + domainSuffixPattern + #"))\b"#
        result = replaceMatches(in: result, pattern: emailPattern) { match, source in
            let local = source.substring(with: match.range(at: 1)).lowercased()
            let domain = source.substring(with: match.range(at: 2)).lowercased()
            return "\(local)@\(domain)"
        }

        let pathWord = #"(?!(?:and|or|then|please|thanks|with|for|to|from|in|on|at)\b)[a-z0-9]+"#
        let pathPhrase = pathWord + #"(?:(?:\s+(?:dash|hyphen|-)\s+|\s*-\s*|\s+)"# + pathWord + #"){0,5}"#
        let spokenSlashPattern = #"(?i)\b("# + domainPattern + #")\s+(?:forward\s+slash|slash)\s+("# + pathPhrase + #")"#
        result = replaceMatches(in: result, pattern: spokenSlashPattern) { match, source in
            let domain = source.substring(with: match.range(at: 1)).lowercased()
            let path = normalizedPath(source.substring(with: match.range(at: 2)))
            return "\(domain)/\(path)"
        }

        let literalSlashPattern = #"(?i)\b("# + domainPattern + #")\s*/\s*("# + pathPhrase + #")"#
        result = replaceMatches(in: result, pattern: literalSlashPattern) { match, source in
            let domain = source.substring(with: match.range(at: 1)).lowercased()
            let path = normalizedPath(source.substring(with: match.range(at: 2)))
            return "\(domain)/\(path)"
        }

        let urlPattern = #"(?i)\b"# + domainPattern + #"(?:/[a-z0-9._~%+\-]*)*"#
        result = replaceMatches(in: result, pattern: urlPattern) { match, source in
            source.substring(with: match.range).lowercased()
        }

        return result
    }

    private static func normalizedPath(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"(?i)\s+(?:dash|hyphen)\s+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/ "))
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        replacement: (NSTextCheckingResult, NSString) -> String
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
            result += replacement(match, source)
            cursor = range.location + range.length
        }

        if cursor < source.length {
            result += source.substring(from: cursor)
        }

        return result
    }

    private static func tidy(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "([({\\[])[\\s]+", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
