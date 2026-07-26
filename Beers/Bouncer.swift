import CoreML
import Foundation

/// Tier-0 disfluency tagger — "the Bouncer". A Core ML token-classification
/// model that can only DELETE words (fillers, stutters, false starts, self
/// corrections), never write, so it cannot hallucinate or answer the dictation.
///
/// PARKED RESEARCH: v1/v2/v3 failed the real-speech precision gate. Production
/// ordinary pours do not call this type, even in shadow. `review` remains for
/// explicit diagnostics and future checkpoint evaluation; reactivation needs
/// both a passing bundle and a reviewed code change at the AppState boundary.
///
/// Everything here is self-contained: a pure-Swift WordPiece tokenizer that
/// mirrors HF's cased `BertTokenizer`, first-subtoken logit extraction, and a
/// seam-cleanup pass. Verified word-for-word against the Python pipeline
/// (`ml/export/verify_parity.py` + `--beers-bouncer-test`).
struct BouncerVerdict {
    /// The input split into words the same way the training data was
    /// (`text.split()` — Unicode whitespace runs).
    let words: [String]
    /// P(any DEL_*) for each word, aligned to `words`.
    let deleteProbabilities: [Double]
    /// Indices into `words` the model would delete at the calibrated threshold.
    let deletedIndices: [Int]
    /// The pour with DELETE words removed and seams cleaned. In shadow mode this
    /// is computed and logged but NOT served.
    let cleanedText: String
    /// True if the model would delete at least one word.
    var didFire: Bool { !deletedIndices.isEmpty }
    /// False when the model files are absent or failed to load — the caller
    /// must treat the pour as a clean no-op in that case.
    let modelAvailable: Bool
    /// The gold ship gate recorded in the bundle. Production activation also
    /// requires a reviewed code change; this flag alone cannot serve a pour.
    let targetMet: Bool
    /// Calibrated DELETE probability threshold used for the decisions.
    let threshold: Double
    /// Inference + tokenize + cleanup wall time.
    let elapsedMillis: Double

    /// A no-op verdict for when the model is unavailable: everything kept.
    static func noop(_ text: String, elapsedMillis: Double = 0) -> BouncerVerdict {
        let words = Bouncer.splitWords(text)
        return BouncerVerdict(
            words: words,
            deleteProbabilities: Array(repeating: 0, count: words.count),
            deletedIndices: [],
            cleanedText: text,
            modelAvailable: false,
            targetMet: false,
            threshold: 1.0,
            elapsedMillis: elapsedMillis
        )
    }
}

final class Bouncer {
    static let shared = Bouncer()

    private let model: MLModel?
    private let vocab: [String: Int]
    private let unkId: Int
    private let clsId: Int
    private let sepId: Int
    private let padId: Int
    private let keepId: Int
    private let delIds: Set<Int>
    private let numLabels: Int
    let threshold: Double
    let targetMet: Bool
    /// True once the model + vocab loaded successfully.
    let isAvailable: Bool

    private static let seqLen = 256
    private static let maxSubtokensPerWord = 100

    private init() {
        // --- vocab.txt -----------------------------------------------------
        var vocab: [String: Int] = [:]
        if let url = Bouncer.resource("vocab", "txt"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            var idx = 0
            // WordPiece vocab is one token per line, index == line number.
            contents.enumerateLines { line, _ in
                vocab[line] = idx
                idx += 1
            }
        }
        self.vocab = vocab
        self.unkId = vocab["[UNK]"] ?? 100
        self.clsId = vocab["[CLS]"] ?? 101
        self.sepId = vocab["[SEP]"] ?? 102
        self.padId = vocab["[PAD]"] ?? 0

        // --- labels.json ---------------------------------------------------
        var keepId = 0
        var delIds: Set<Int> = [1, 2, 3, 4]
        var numLabels = 5
        if let url = Bouncer.resource("labels", "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            keepId = (obj["keep_id"] as? Int) ?? keepId
            if let ids = obj["del_ids"] as? [Int] { delIds = Set(ids) }
            numLabels = (obj["num_labels"] as? Int) ?? numLabels
        }
        self.keepId = keepId
        self.delIds = delIds
        self.numLabels = numLabels

        // --- threshold.json (threshold + the gold ship gate) ---------------
        var threshold = 0.98
        var targetMet = false
        if let url = Bouncer.resource("threshold", "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            threshold = (obj["threshold"] as? Double) ?? threshold
            targetMet = (obj["target_met"] as? Bool) ?? false
        }
        self.threshold = threshold
        self.targetMet = targetMet

        // --- Core ML model -------------------------------------------------
        self.model = Bouncer.loadModel()

        self.isAvailable = (model != nil) && !vocab.isEmpty
        if isAvailable {
            llog("Bouncer: loaded (threshold=\(threshold), target_met=\(targetMet), vocab=\(vocab.count))")
        } else {
            llog("Bouncer: model files missing — tier-0 disabled (no-op)")
        }
    }

    // MARK: - Resource loading

    /// Bundle resources are flattened to the bundle root by xcodegen; the
    /// `Bouncer/` subdirectory lookup is a fallback (mirrors BeersFonts).
    private static func resource(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Bouncer")
    }

    private static func loadModel() -> MLModel? {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        // Prefer the Xcode-compiled model.
        if let url = Bundle.main.url(forResource: "Bouncer", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "Bouncer", withExtension: "mlmodelc", subdirectory: "Bouncer") {
            return try? MLModel(contentsOf: url, configuration: config)
        }
        // Fallback: an uncompiled .mlpackage — compile once and cache.
        if let pkg = Bundle.main.url(forResource: "Bouncer", withExtension: "mlpackage")
            ?? Bundle.main.url(forResource: "Bouncer", withExtension: "mlpackage", subdirectory: "Bouncer") {
            let cached = FileManager.default.temporaryDirectory.appendingPathComponent("Bouncer.mlmodelc")
            if FileManager.default.fileExists(atPath: cached.path),
               let m = try? MLModel(contentsOf: cached, configuration: config) {
                return m
            }
            if let compiled = try? MLModel.compileModel(at: pkg) {
                try? FileManager.default.removeItem(at: cached)
                try? FileManager.default.copyItem(at: compiled, to: cached)
                return try? MLModel(contentsOf: compiled, configuration: config)
            }
        }
        return nil
    }

    // MARK: - Public API

    /// Predict per-word DELETE decisions for `text`. Never throws; on any
    /// failure or missing model it returns a no-op verdict (everything KEEP).
    static func review(_ text: String) -> BouncerVerdict {
        shared.review(text)
    }

    /// Force the singleton to load and run one inference so the first real pour
    /// doesn't pay the cold Core ML / ANE compile cost (~600ms). Safe to call
    /// repeatedly and off the main thread; hidden behind the recording like the
    /// LLM prewarm.
    private static var didPrewarm = false
    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        _ = shared.review("warm up the bouncer")
    }

    func review(_ text: String) -> BouncerVerdict {
        let start = DispatchTime.now()
        guard isAvailable, let model else {
            return .noop(text)
        }
        let words = Bouncer.splitWords(text)
        guard !words.isEmpty else {
            return .noop(text, elapsedMillis: Self.millis(since: start))
        }

        // Tokenize + build fixed-length inputs.
        let (inputIds, firstPos) = tokenize(words: words)

        var delProbs = [Double](repeating: 0, count: words.count)
        do {
            let logits = try infer(inputIds: inputIds, model: model)
            for (w, pos) in firstPos.enumerated() {
                guard let pos else { continue }  // truncated -> confident KEEP
                delProbs[w] = deleteProbability(logits: logits, tokenIndex: pos)
            }
        } catch {
            llog("Bouncer: inference failed (\(error.localizedDescription)) — no-op")
            return .noop(text, elapsedMillis: Self.millis(since: start))
        }

        let deleted = (0..<words.count).filter { delProbs[$0] >= threshold }
        let cleaned = Bouncer.cleanup(words: words, deleted: Set(deleted))

        return BouncerVerdict(
            words: words,
            deleteProbabilities: delProbs,
            deletedIndices: deleted,
            cleanedText: cleaned,
            modelAvailable: true,
            targetMet: targetMet,
            threshold: threshold,
            elapsedMillis: Self.millis(since: start)
        )
    }

    private static func millis(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Inference

    private func infer(inputIds: [Int], model: MLModel) throws -> MLMultiArray {
        let n = Self.seqLen
        let ids = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let idsPtr = UnsafeMutablePointer<Int32>(OpaquePointer(ids.dataPointer))
        let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(mask.dataPointer))
        for i in 0..<n {
            if i < inputIds.count {
                idsPtr[i] = Int32(inputIds[i])
                maskPtr[i] = inputIds[i] == padId ? 0 : 1
            } else {
                idsPtr[i] = Int32(padId)
                maskPtr[i] = 0
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let out = try model.prediction(from: provider)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else {
            throw NSError(domain: "Bouncer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no logits output"])
        }
        return logits
    }

    /// Softmax over the `numLabels` logits at `tokenIndex`, summed over DEL_* ids.
    private func deleteProbability(logits: MLMultiArray, tokenIndex: Int) -> Double {
        // logits shape (1, seqLen, numLabels), row-major.
        let base = tokenIndex * numLabels
        var raw = [Double](repeating: 0, count: numLabels)
        var maxL = -Double.greatestFiniteMagnitude
        for c in 0..<numLabels {
            let v = logits[base + c].doubleValue
            raw[c] = v
            if v > maxL { maxL = v }
        }
        var sum = 0.0
        for c in 0..<numLabels { raw[c] = exp(raw[c] - maxL); sum += raw[c] }
        guard sum > 0 else { return 0 }
        var del = 0.0
        for c in delIds { del += raw[c] }
        return del / sum
    }

    // MARK: - Tokenizer (WordPiece, cased — mirrors HF BertTokenizer)

    /// Split like Python `str.split()`: on runs of Unicode whitespace.
    static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Returns the [CLS]…[SEP] token-id sequence plus, for each input word, the
    /// token index of its FIRST subtoken (nil if the word was truncated away).
    private func tokenize(words: [String]) -> (inputIds: [Int], firstPos: [Int?]) {
        var ids: [Int] = [clsId]
        var firstPos = [Int?](repeating: nil, count: words.count)
        let maxSubtokens = Self.seqLen - 2  // room for [CLS] and [SEP]
        var subtokenCount = 0

        outer: for (i, word) in words.enumerated() {
            let pieces = wordPieceIds(for: word)
            for (j, id) in pieces.enumerated() {
                if subtokenCount >= maxSubtokens { break outer }
                let position = ids.count
                ids.append(id)
                if j == 0 { firstPos[i] = position }
                subtokenCount += 1
            }
        }
        ids.append(sepId)
        return (ids, firstPos)
    }

    /// Basic-tokenize one whitespace word (clean, split CJK, split punctuation)
    /// then WordPiece each fragment. Returns the flat list of subtoken ids for
    /// the word, in order (first element is the word's first subtoken).
    private func wordPieceIds(for word: String) -> [Int] {
        var ids: [Int] = []
        for fragment in basicTokenize(word) {
            ids.append(contentsOf: wordPiece(fragment))
        }
        return ids
    }

    /// HF BasicTokenizer for a single pre-split word (cased: no lowercase, no
    /// accent stripping). Cleans control chars, spaces CJK, splits punctuation.
    private func basicTokenize(_ word: String) -> [String] {
        var cleaned = ""
        for scalar in word.unicodeScalars {
            let cp = scalar.value
            if cp == 0 || cp == 0xFFFD || Bouncer.isControl(scalar) { continue }
            if Bouncer.isWhitespace(scalar) { cleaned.append(" "); continue }
            if Bouncer.isChineseChar(cp) {
                cleaned.append(" "); cleaned.unicodeScalars.append(scalar); cleaned.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        var fragments: [String] = []
        for chunk in cleaned.split(whereSeparator: { $0 == " " }) {
            fragments.append(contentsOf: Bouncer.splitOnPunctuation(String(chunk)))
        }
        return fragments
    }

    /// HF WordpieceTokenizer: greedy longest-match, `##` continuations, `[UNK]`
    /// for words longer than 100 chars or with any unmatchable piece.
    private func wordPiece(_ token: String) -> [Int] {
        let chars = Array(token.unicodeScalars)
        if chars.count > Self.maxSubtokensPerWord { return [unkId] }
        var out: [Int] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var curId: Int? = nil
            while start < end {
                var substr = String(String.UnicodeScalarView(chars[start..<end]))
                if start > 0 { substr = "##" + substr }
                if let id = vocab[substr] { curId = id; break }
                end -= 1
            }
            guard let id = curId else { return [unkId] }  // unmatchable -> whole word UNK
            out.append(id)
            start = end
        }
        return out.isEmpty ? [unkId] : out
    }

    // MARK: Character classes (match HF's tokenization.py exactly)

    private static func splitOnPunctuation(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isPunctuation(scalar) {
                if !current.isEmpty { out.append(current); current = "" }
                out.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        if s == " " || s == "\t" || s == "\n" || s == "\r" { return true }
        return s.properties.generalCategory == .spaceSeparator  // Zs
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return true
        default:
            return false
        }
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let cp = s.value
        // ASCII non-alphanumeric ranges HF treats as punctuation.
        if (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64)
            || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isChineseChar(_ cp: UInt32) -> Bool {
        (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF)
            || (cp >= 0x20000 && cp <= 0x2A6DF) || (cp >= 0x2A700 && cp <= 0x2B73F)
            || (cp >= 0x2B740 && cp <= 0x2B81F) || (cp >= 0x2B820 && cp <= 0x2CEAF)
            || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0x2F800 && cp <= 0x2FA1F)
    }

    // MARK: - Seam cleanup

    /// Remove DELETE words, then repair the seams: orphaned/leading punctuation,
    /// doubled spaces, and sentence-start capitalization where a deleted word
    /// opened the sentence. This is the downstream regex pass DESIGN.md assigns
    /// to the app, not the model.
    static func cleanup(words: [String], deleted: Set<Int>) -> String {
        guard !deleted.isEmpty else { return words.joined(separator: " ") }

        var kept: [String] = []
        var sentenceStart = true
        for (i, word) in words.enumerated() {
            if deleted.contains(i) { continue }
            var w = word
            if sentenceStart, let first = w.first, first.isLowercase {
                w.replaceSubrange(w.startIndex...w.startIndex, with: String(first).uppercased())
            }
            kept.append(w)
            sentenceStart = endsSentence(word)
        }

        var text = kept.joined(separator: " ")
        text = regexReplace(text, #"\s+"#, " ")                     // collapse spaces
        text = regexReplace(text, #"\s+([,.;:!?])"#, "$1")          // space before punct
        text = regexReplace(text, #",(\s*,)+"#, ",")               // comma runs ", ,"
        text = regexReplace(text, #"([,;:])\1+"#, "$1")            // doubled ",," ";;"
        text = regexReplace(text, #"^[\s,;:]+"#, "")               // leading orphan punct
        text = text.trimmingCharacters(in: .whitespaces)
        // Re-capitalize the very first letter if a leading deletion exposed it.
        if let first = text.first, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        return text
    }

    private static func endsSentence(_ word: String) -> Bool {
        for ch in word.reversed() {
            if ch == "." || ch == "!" || ch == "?" { return true }
            if ch == "\"" || ch == "'" || ch == ")" || ch == "]" || ch == "”" || ch == "’" { continue }
            return false
        }
        return false
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: repl)
    }
}
