import Foundation

/// One word-level edit inside a served span: the served word at `index` became
/// `new` (nil == the word was deleted; empty `old` == a word was inserted).
struct FlywheelWordChange {
    let index: Int
    let old: String
    let new: String?
}

/// Flywheel — local, append-only capture of real dictation pairs so the
/// Bouncer disfluency model can one day be retrained on Ben's actual speech
/// (ml/DESIGN.md Phase 3). The synthetic-data ceiling is real; the only
/// remaining lever is the user's own pours.
///
/// One JSON record per served pour is appended to
/// `~/Library/Application Support/Beers/flywheel.jsonl` (Application Support,
/// NOT /tmp — the corpus must survive reboots).
///
/// ============================ PRIVACY ================================
/// These records contain VERBATIM dictation transcripts. They are written to
/// local disk ONLY and MUST NEVER leave this machine — there is no network
/// call, no telemetry, no sync, and no upload path anywhere in this type, and
/// none may ever be added. The ML pipeline reads the file in place
/// (`ml/gen/flywheel_ingest.py`). The user can disable capture entirely via
/// the `flywheelLoggingEnabled` UserDefault.
/// ====================================================================
enum FlywheelLog {
    /// Rotate once the live file passes ~5 MB. Rotations are never deleted.
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    /// Serialize all disk work off the pour path so logging can never block or
    /// fail a pour.
    private static let queue = DispatchQueue(label: "com.llatser.listen.flywheel", qos: .utility)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Opt-out switch; defaults ON (absent key == enabled).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "flywheelLoggingEnabled") == nil
            || UserDefaults.standard.bool(forKey: "flywheelLoggingEnabled")
    }

    /// Second opt-out, for the correction watcher only. Defaults ON (absent
    /// key == enabled). Correction/rejection/redictation records honour BOTH
    /// this and `flywheelLoggingEnabled`.
    static var correctionWatcherEnabled: Bool {
        UserDefaults.standard.object(forKey: "correctionWatcherEnabled") == nil
            || UserDefaults.standard.bool(forKey: "correctionWatcherEnabled")
    }

    /// Append one pour record. Fire-and-forget: never blocks the caller, never
    /// throws, never affects the pour path. Skips empty pours and honours the
    /// `flywheelLoggingEnabled` opt-out.
    ///
    /// - raw:                verbatim ASR transcript, BEFORE the rule polisher.
    /// - rulePolished:       post-TranscriptPolisher text, or nil if it did not run.
    /// - served:             the final text that was pasted.
    /// - tier:               which tier served (see OrderKitchen.ServingTier).
    /// - bouncerWouldDelete: word indices the tier-0 shadow would delete, or nil
    ///                       if the shadow did not run.
    /// - bouncerMs:          shadow latency in ms, or nil if it did not run.
    ///
    /// Returns the record's `ts` so the caller can reference this pour from a
    /// later correction/rejection/redictation record (nil when nothing was
    /// written — logging disabled or the pour was empty).
    @discardableResult
    static func record(
        raw: String,
        rulePolished: String?,
        served: String,
        tier: String,
        bouncerWouldDelete: [Int]?,
        bouncerMs: Double?
    ) -> String? {
        guard isEnabled else { return nil }
        guard !served.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Build the line by hand so the keys land in the documented schema
        // order (JSONEncoder emits keyed containers in hash order). String
        // values are escaped via JSONSerialization so any quotes/newlines/
        // unicode in a transcript are handled correctly. nil optionals become
        // an explicit `null` — the ML side distinguishes "did not run" from
        // "measured empty".
        let ts = iso.string(from: Date())
        var fields: [String] = []
        fields.append("\"ts\":\(jsonString(ts))")
        fields.append("\"raw\":\(jsonString(raw))")
        fields.append("\"rulePolished\":\(rulePolished.map(jsonString) ?? "null")")
        fields.append("\"served\":\(jsonString(served))")
        fields.append("\"tier\":\(jsonString(tier))")
        let idx = bouncerWouldDelete.map { "[" + $0.map(String.init).joined(separator: ",") + "]" }
        fields.append("\"bouncerWouldDelete\":\(idx ?? "null")")
        fields.append("\"bouncerMs\":\(bouncerMs.map { String($0) } ?? "null")")
        let line = "{" + fields.joined(separator: ",") + "}\n"

        guard let data = line.data(using: .utf8) else { return ts }
        queue.async { append(data) }
        return ts
    }

    /// Append a correction/rejection record — the user's keyboard fix of a
    /// pasted pour, captured by `CorrectionWatcher`. A SEPARATE line; existing
    /// pour lines are never mutated. `pourTs` links back to the pour's `ts`.
    /// Records NEVER leave this machine (see the PRIVACY block above).
    ///
    /// - type:         "correction" (edited in place) or "rejection" (deleted).
    /// - corrected:    the span after the user's edits, or nil for a rejection.
    /// - changedWords: per-word edits, served-span indices.
    static func recordCorrection(
        type: String,
        pourTs: String,
        app: String,
        served: String,
        corrected: String?,
        changedWords: [FlywheelWordChange]
    ) {
        guard isEnabled, correctionWatcherEnabled else { return }
        var fields: [String] = []
        fields.append("\"ts\":\(jsonString(iso.string(from: Date())))")
        fields.append("\"type\":\(jsonString(type))")
        fields.append("\"pourTs\":\(jsonString(pourTs))")
        fields.append("\"app\":\(jsonString(app))")
        fields.append("\"served\":\(jsonString(served))")
        fields.append("\"corrected\":\(corrected.map(jsonString) ?? "null")")
        let cw = changedWords.map { c in
            "[\(c.index),\(jsonString(c.old)),\(c.new.map(jsonString) ?? "null")]"
        }.joined(separator: ",")
        fields.append("\"changedWords\":[\(cw)]")
        let line = "{" + fields.joined(separator: ",") + "}\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { append(data) }
    }

    /// Append a re-dictation record: `pourTs`'s pour is superseded by a fresh
    /// pour (`newPourTs`) the user dictated instead of keeping the first.
    static func recordRedictation(pourTs: String, newPourTs: String) {
        guard isEnabled, correctionWatcherEnabled else { return }
        var fields: [String] = []
        fields.append("\"ts\":\(jsonString(iso.string(from: Date())))")
        fields.append("\"type\":\"redictation\"")
        fields.append("\"pourTs\":\(jsonString(pourTs))")
        fields.append("\"newPourTs\":\(jsonString(newPourTs))")
        let line = "{" + fields.joined(separator: ",") + "}\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { append(data) }
    }

    /// RFC-correct JSON string literal (with surrounding quotes) for `s`.
    private static func jsonString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
           let out = String(data: data, encoding: .utf8) {
            return out
        }
        return "\"\""
    }

    /// Wait for all pending writes to reach disk. Only needed by short-lived
    /// self-test processes that exit immediately after logging; real pours
    /// never call this (the app keeps running).
    static func flush() {
        queue.sync {}
    }

    // MARK: - Disk

    private static func supportDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Beers", isDirectory: true)
    }

    /// Runs on `queue`. Everything is best-effort; a failure here silently
    /// drops one record rather than ever surfacing to the pour path.
    private static func append(_ line: Data) {
        let fm = FileManager.default
        let dir = supportDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("flywheel.jsonl")

        // Rotate the live file if it has grown past the cap. Old rotations are
        // renamed, never deleted.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > maxBytes {
            let stamp = rotationStamp()
            var dest = dir.appendingPathComponent("flywheel-\(stamp).jsonl")
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("flywheel-\(stamp)-\(n).jsonl")
                n += 1
            }
            try? fm.moveItem(at: url, to: dest)
        }

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private static func rotationStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
