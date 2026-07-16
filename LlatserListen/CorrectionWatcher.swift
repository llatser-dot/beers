import AppKit
import ApplicationServices

/// CorrectionWatcher — after an ordinary pour is pasted, watch the focused
/// text element and turn the user's ordinary keyboard fixes into training data
/// (ml/DESIGN.md Phase 3 flywheel). A genuine correction is the highest-value
/// signal we can get: the user telling us, by editing, exactly what the model
/// should have produced.
///
/// How it works: snapshot the element's value right after paste, find the
/// pasted span inside it, then watch (AXObserver + polling fallback) while the
/// element keeps focus. On watch end we re-anchor the span on its surrounding
/// context, diff served-vs-final at the word level, and — if the change looks
/// like a real correction (small, non-empty, not just whitespace/append) —
/// append ONE record to the flywheel log via `FlywheelLog.recordCorrection`.
///
/// ============================ PRIVACY ================================
/// Everything captured here is written to local disk ONLY, through
/// `FlywheelLog`, which has no network path of any kind. Nothing observed on
/// screen ever leaves this machine.
/// ====================================================================
///
/// Threading: every method here runs on the MAIN thread. AX observers are
/// added to the main run loop, timers are scheduled on it, and all calls in
/// from `AppState` come from the @MainActor. AX errors are caught and ignored
/// everywhere; the watcher must never block or affect the pour path.
final class CorrectionWatcher {
    /// Fired on the main thread immediately after a correction/rejection record
    /// is appended to the flywheel. AppState uses this to run the fast
    /// vocabulary learning loop (auto-teach recurring brand/name fixes) without
    /// waiting for Brew Controls to be opened.
    var onCorrectionRecorded: (() -> Void)?

    // Tunables.
    private let hardCapSeconds: TimeInterval = 120
    private let pollInterval: TimeInterval = 1.0
    private let locateRetryInterval: TimeInterval = 0.2
    private let locateMaxAttempts = 8          // ~1.6s for the paste to land
    private let contextChars = 40              // anchor length for re-location
    private let editRatioCap = 0.40            // > 40% words changed => not a fix

    // Live watch state (all touched on main thread only).
    private var active = false
    private var element: AXUIElement?
    private var observer: AXObserver?
    private var pollTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var startedAt = Date.distantPast
    private var servedSpan = ""
    private var prefixContext = ""
    private var suffixContext = ""
    private var latestValue = ""
    private var haveValue = false
    private var pourTs = ""
    private var appName = ""
    private var inTerminal = false

    // Locate phase (before watching actually begins).
    private var pendingElement: AXUIElement?
    private var locateAttempts = 0

    // cmux socket mode (see startCmuxCapture). cmux renders terminals on a
    // canvas, so AX exposes nothing — we read the screen over the cmux socket
    // instead and do the same anchor/diff dance on whitespace-normalized text.
    private var cmuxMode = false
    private var cmuxSurfaceID: String?
    private var cmuxMissCount = 0
    private let cmuxMissLimit = 3              // consecutive re-anchor misses => span left screen

    private enum DiffOp { case equal(Int); case del(Int); case ins(Int) }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
    ]

    // MARK: - Public entry points

    /// Begin watching the focused element for corrections to a just-pasted
    /// ordinary pour. Call ONLY for ordinary pours (Command Mode excluded) and
    /// only after a successful paste. Silently does nothing if capture is
    /// disabled, the element is unwatchable, or the span can't be found.
    func start(servedText: String, pourTs: String) {
        reset()  // a fresh pour supersedes any prior watch, no record

        guard FlywheelLog.isEnabled, FlywheelLog.correctionWatcherEnabled else { return }
        guard !servedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let bundle = front?.bundleIdentifier ?? ""
        let name = front?.localizedName ?? "?"

        // cmux: xterm.js renders to a canvas and its AX tree exposes only an
        // empty helper text area, so the AX path below can never anchor there
        // (and may not even report a focused element). Read the screen over
        // the cmux socket instead.
        if Self.isCmuxApp(bundle: bundle, name: name) {
            guard Self.boolDefaultTrue(forKey: "cmuxScreenCaptureEnabled") else { return }
            guard CmuxScreenSource.isAvailable else {
                llog("CorrectionWatcher: cmux CLI not found — not watching")
                return
            }
            startCmuxCapture(servedText: servedText, pourTs: pourTs, appName: name)
            return
        }

        guard let el = Self.focusedElement() else { return }
        let role = Self.stringAttr(el, kAXRoleAttribute) ?? ""
        let subrole = Self.stringAttr(el, kAXSubroleAttribute) ?? ""

        // Skip secure / password fields.
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            llog("CorrectionWatcher: skip secure field app='\(name)'")
            return
        }
        // Terminals expose the whole scrollback as one AXTextArea value, so
        // naive diffing is dangerous (streamed output looks like edits). We DO
        // watch them now — Ben's real usage is almost entirely in the terminal —
        // but under extra guards: the span must be UNIQUE in the buffer to anchor
        // safely (see attemptLocate), and only in-place edits with no net word
        // growth are recorded (see evaluate). Streamed output is discarded.
        inTerminal = Self.isTerminalApp(bundle: bundle, name: name) && role == "AXTextArea"
        if inTerminal {
            llog("CorrectionWatcher: terminal capture (guarded) app='\(name)' bundle='\(bundle)'")
        }
        // Value must be readable.
        guard Self.stringAttr(el, kAXValueAttribute) != nil else {
            llog("CorrectionWatcher: skip unreadable value app='\(name)' role=\(role)")
            return
        }

        servedSpan = servedText
        self.pourTs = pourTs
        appName = name
        pendingElement = el
        locateAttempts = 0
        attemptLocate()
    }

    /// Force the watch to end and evaluate now (used when a new recording
    /// starts — a new pour supersedes). No-op if nothing is being watched.
    func stop() {
        guard active || pendingElement != nil || cmuxMode else { return }
        if active {
            end(reason: "new recording")
        } else {
            reset()  // still in the locate phase — nothing to evaluate
        }
    }

    // MARK: - Locate the pasted span

    private func attemptLocate() {
        guard let el = pendingElement else { return }
        locateAttempts += 1

        guard let value = Self.stringAttr(el, kAXValueAttribute) else {
            llog("CorrectionWatcher: value became unreadable during locate — aborting")
            reset()
            return
        }
        if let range = value.range(of: servedSpan) {
            // In a terminal the value is the whole scrollback; if the span text
            // occurs more than once we can't anchor to the right one, so bail
            // rather than risk re-locating onto an unrelated copy.
            if inTerminal && Self.occurrences(of: servedSpan, in: value) != 1 {
                llog("CorrectionWatcher: terminal span not unique — not watching app='\(appName)'")
                reset()
                return
            }
            beginWatching(element: el, baseline: value, span: range)
            return
        }
        if locateAttempts >= locateMaxAttempts {
            // The app transformed the paste (autocorrect, rich-text, etc.) —
            // the exact span isn't there. Abort watching silently.
            llog("CorrectionWatcher: pasted span not found in '\(appName)' — not watching")
            reset()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + locateRetryInterval) { [weak self] in
            self?.attemptLocate()
        }
    }

    private func beginWatching(element el: AXUIElement, baseline: String, span: Range<String.Index>) {
        element = el
        pendingElement = nil
        active = true
        startedAt = Date()
        latestValue = baseline
        haveValue = true

        let before = String(baseline[..<span.lowerBound])
        let after = String(baseline[span.upperBound...])
        prefixContext = String(before.suffix(contextChars))
        suffixContext = String(after.prefix(contextChars))

        attachObserver(to: el)

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.end(reason: "app switch")
        }

        let words = servedSpan.split(whereSeparator: \.isWhitespace).count
        llog("CorrectionWatcher: watching \(words)-word span in '\(appName)' (observer=\(observer != nil ? "on" : "poll-only"))")
    }

    // MARK: - cmux socket capture

    /// Same contract as the AX path, but the "element value" is the visible
    /// screen text of the focused cmux terminal surface, read over the cmux
    /// socket and whitespace-normalized (the terminal re-wraps lines, so raw
    /// text never matches the served span exactly). The span is anchored to
    /// the surface UUID captured at paste time, so it stays readable even if
    /// the user switches panes; the watch ends when the span leaves the screen
    /// (submit/scroll), the app is switched, or the 120s cap fires.
    private func startCmuxCapture(servedText: String, pourTs: String, appName name: String) {
        servedSpan = Self.normalizedScreen(servedText)
        guard !servedSpan.isEmpty else { return }
        self.pourTs = pourTs
        appName = name
        inTerminal = true   // same growth guard: streamed output must not train
        cmuxMode = true
        locateAttempts = 0

        CmuxScreenSource.focusedTerminalSurfaceID { [weak self] surfaceID in
            guard let self, self.cmuxMode, !self.active else { return }
            guard let surfaceID else {
                llog("CorrectionWatcher: cmux focused surface unavailable — not watching")
                self.reset()
                return
            }
            self.cmuxSurfaceID = surfaceID
            self.attemptCmuxLocate()
        }
    }

    private func attemptCmuxLocate() {
        guard cmuxMode, !active, let surfaceID = cmuxSurfaceID else { return }
        locateAttempts += 1

        CmuxScreenSource.readScreen(surfaceID: surfaceID) { [weak self] screen in
            guard let self, self.cmuxMode, !self.active else { return }
            let value = Self.normalizedScreen(screen ?? "")
            let hits = Self.occurrences(of: self.servedSpan, in: value)
            if hits == 1, let range = value.range(of: self.servedSpan) {
                self.beginCmuxWatching(baseline: value, span: range)
                return
            }
            if hits > 1 {
                llog("CorrectionWatcher: cmux span not unique on screen — not watching")
                self.reset()
                return
            }
            if self.locateAttempts >= self.locateMaxAttempts {
                llog("CorrectionWatcher: cmux span not found on screen — not watching")
                self.reset()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.locateRetryInterval) { [weak self] in
                self?.attemptCmuxLocate()
            }
        }
    }

    private func beginCmuxWatching(baseline: String, span: Range<String.Index>) {
        active = true
        startedAt = Date()
        latestValue = baseline
        haveValue = true
        cmuxMissCount = 0

        let before = String(baseline[..<span.lowerBound])
        let after = String(baseline[span.upperBound...])
        prefixContext = String(before.suffix(contextChars))
        suffixContext = String(after.prefix(contextChars))

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.cmuxPollTick()
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.end(reason: "app switch")
        }

        let words = servedSpan.split(whereSeparator: \.isWhitespace).count
        llog("CorrectionWatcher: watching \(words)-word span in '\(appName)' (cmux socket)")
    }

    private func cmuxPollTick() {
        guard active, cmuxMode else { return }

        if Date().timeIntervalSince(startedAt) >= hardCapSeconds {
            end(reason: "120s cap")
            return
        }
        guard let surfaceID = cmuxSurfaceID else {
            end(reason: "no surface")
            return
        }
        CmuxScreenSource.readScreen(surfaceID: surfaceID) { [weak self] screen in
            guard let self, self.active, self.cmuxMode else { return }
            let value = Self.normalizedScreen(screen ?? "")
            if let span = Self.relocate(in: value, prefix: self.prefixContext, suffix: self.suffixContext) {
                // Growth between the anchors means the pour was submitted and
                // output is streaming where the composer used to be. The
                // composer's final state — the one holding the user's fixes —
                // is the snapshot we already have; end NOW so a grown snapshot
                // never overwrites it (evaluate would discard the whole record).
                let servedCount = self.servedSpan.split(whereSeparator: \.isWhitespace).count
                let spanCount = span.split(whereSeparator: \.isWhitespace).count
                if spanCount > servedCount {
                    self.end(reason: "span grew on screen (submitted)")
                    return
                }
                self.latestValue = value
                self.haveValue = true
                self.cmuxMissCount = 0
            } else {
                // The span left the visible screen (submitted, cleared, or
                // scrolled away). Evaluate against the last snapshot where the
                // anchors still held — that snapshot contains the user's fixes.
                self.cmuxMissCount += 1
                if self.cmuxMissCount >= self.cmuxMissLimit {
                    self.end(reason: "span left screen")
                }
            }
        }
    }

    // MARK: - AX observer + polling

    private func attachObserver(to el: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, correctionWatcherValueChanged, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon) == .success else {
            return  // fall back to polling only
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    /// Called from the AX value-changed callback (main thread).
    fileprivate func handleValueChanged() {
        guard active, let el = element else { return }
        if let v = Self.stringAttr(el, kAXValueAttribute) {
            latestValue = v
            haveValue = true
        }
    }

    private func pollTick() {
        guard active else { return }

        if Date().timeIntervalSince(startedAt) >= hardCapSeconds {
            end(reason: "120s cap")
            return
        }
        // Focus check: if the focused element is no longer ours, end.
        guard let focused = Self.focusedElement() else {
            end(reason: "no focus")
            return
        }
        if let el = element, !CFEqual(focused, el) {
            end(reason: "focus lost")
            return
        }
        // Polling fallback for the value (harmless when the observer is on too).
        if let el = element, let v = Self.stringAttr(el, kAXValueAttribute) {
            latestValue = v
            haveValue = true
        }
    }

    // MARK: - End + evaluate

    private func end(reason: String) {
        guard active else { reset(); return }
        active = false

        let finalValue = haveValue ? latestValue : nil
        let served = servedSpan
        let prefix = prefixContext
        let suffix = suffixContext
        let ts = pourTs
        let app = appName
        let terminal = inTerminal

        reset()  // tear down observer/timer, drop the element reference

        evaluate(finalValue: finalValue, served: served, prefix: prefix,
                 suffix: suffix, pourTs: ts, app: app, terminal: terminal, reason: reason)
    }

    /// Diff the served span against the final span and, if it reads as a
    /// genuine correction, write exactly one flywheel record.
    private func evaluate(
        finalValue: String?, served: String, prefix: String, suffix: String,
        pourTs: String, app: String, terminal: Bool, reason: String
    ) {
        guard let finalValue else {
            llog("CorrectionWatcher: end (\(reason)) — no readable value, discarding")
            return
        }
        guard let finalSpan = Self.relocate(in: finalValue, prefix: prefix, suffix: suffix) else {
            llog("CorrectionWatcher: end (\(reason)) — could not re-anchor span, discarding")
            return
        }

        let servedTrimmed = served.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTrimmed = finalSpan.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rejection: the span was deleted entirely.
        if finalTrimmed.isEmpty {
            let servedWords = servedTrimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            let changes = servedWords.enumerated().map {
                FlywheelWordChange(index: $0.offset, old: $0.element, new: nil)
            }
            FlywheelLog.recordCorrection(type: "rejection", pourTs: pourTs, app: app,
                                         served: servedTrimmed, corrected: nil, changedWords: changes)
            llog("CorrectionWatcher: REJECTION recorded (\(reason)) app='\(app)'")
            onCorrectionRecorded?()
            return
        }

        // No edit at all — normal pour, no record.
        if servedTrimmed == finalTrimmed {
            llog("CorrectionWatcher: end (\(reason)) — no edit, no record")
            return
        }

        // Whitespace / trailing-punctuation-only change — ignore.
        if Self.normalizedCompare(servedTrimmed) == Self.normalizedCompare(finalTrimmed) {
            llog("CorrectionWatcher: end (\(reason)) — whitespace/punct-only, discarding")
            return
        }

        let servedWords = servedTrimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let finalWords = finalTrimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        // Terminal guard: the span is anchored in live scrollback, so any net
        // word GROWTH almost certainly means streamed output leaked into the
        // re-anchored span (or the user submitted and the shell replied). A real
        // dictation fix is a substitution or deletion, never an addition. Only
        // accept same-or-fewer words in terminals — this is the line that keeps
        // agent/shell output out of the training data.
        if terminal && finalWords.count > servedWords.count {
            llog("CorrectionWatcher: end (\(reason)) — terminal span grew \(servedWords.count)->\(finalWords.count) words, discarding (likely streamed output)")
            return
        }

        // Appended continued typing after the span — ignore.
        if finalWords.count > servedWords.count,
           Array(finalWords.prefix(servedWords.count)) == servedWords {
            llog("CorrectionWatcher: end (\(reason)) — appended text only, discarding")
            return
        }

        let changes = Self.wordDiff(served: servedWords, final: finalWords)
        guard !changes.isEmpty else {
            llog("CorrectionWatcher: end (\(reason)) — empty diff, discarding")
            return
        }

        // Mid-edit harvest guard: ending because a NEW recording started means
        // the user may have been caught mid-backspace, clearing the tail to
        // re-dictate (seen live: "…Have we had any additional" -> "…Ha"). A
        // diff that only touches a contiguous run ending at the span's last
        // word is that half-deleted state, not a correction — never train on it.
        if reason == "new recording" {
            let idxs = changes.map(\.index)
            if let lo = idxs.min(), idxs.max() == servedWords.count - 1,
               Set(idxs).count == servedWords.count - lo {
                llog("CorrectionWatcher: end (\(reason)) — trailing edit-in-progress, discarding")
                return
            }
        }
        let ratio = Double(changes.count) / Double(max(1, servedWords.count))
        guard ratio <= editRatioCap else {
            llog("CorrectionWatcher: end (\(reason)) — \(Int(ratio * 100))% of words changed (>40%), discarding")
            return
        }

        FlywheelLog.recordCorrection(type: "correction", pourTs: pourTs, app: app,
                                     served: servedTrimmed, corrected: finalTrimmed, changedWords: changes)
        llog("CorrectionWatcher: CORRECTION recorded \(changes.count)/\(servedWords.count) words (\(reason)) app='\(app)'")
        onCorrectionRecorded?()
    }

    /// Tear down all live watch resources. Never retains the element past here.
    private func reset() {
        active = false
        if let obs = observer {
            if let el = element {
                AXObserverRemoveNotification(obs, el, kAXValueChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        element = nil
        pendingElement = nil
        latestValue = ""
        haveValue = false
        inTerminal = false
        cmuxMode = false
        cmuxSurfaceID = nil
        cmuxMissCount = 0
    }

    /// Count non-overlapping occurrences of `needle` in `haystack`.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = r.upperBound
        }
        return count
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let f = focused else { return nil }
        return (f as! AXUIElement)
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func isCmuxApp(bundle: String, name: String) -> Bool {
        bundle == "com.cmuxterm.app" || (bundle + " " + name).lowercased().contains("cmux")
    }

    private static func boolDefaultTrue(forKey key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    /// Terminal screen text re-wraps at the column edge, so exact matching is
    /// hopeless: collapse all whitespace (including the wrap newlines) to
    /// single spaces before locating, anchoring, and diffing. The word-level
    /// diff downstream is whitespace-agnostic, so nothing is lost.
    private static func normalizedScreen(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTerminalApp(bundle: String, name: String) -> Bool {
        if terminalBundleIDs.contains(bundle) { return true }
        let hay = (bundle + " " + name).lowercased()
        return hay.contains("cmux") || hay.contains("ghostty")
            || hay.contains("kitty") || hay.contains("iterm") || hay.contains("terminal")
    }

    // MARK: - Span re-location + diff

    /// Re-find the span in `value` by anchoring on the text that surrounded it
    /// at paste time. The span may have grown or shrunk between the anchors.
    private static func relocate(in value: String, prefix: String, suffix: String) -> String? {
        var start = value.startIndex
        if !prefix.isEmpty {
            guard let r = value.range(of: prefix) else { return nil }
            start = r.upperBound
        }
        var end = value.endIndex
        if !suffix.isEmpty {
            guard let r = value.range(of: suffix, range: start..<value.endIndex) else { return nil }
            end = r.lowerBound
        }
        guard start <= end else { return nil }
        return String(value[start..<end])
    }

    /// Collapse whitespace and strip trailing punctuation so pure
    /// whitespace/trailing-punctuation changes compare equal.
    private static func normalizedCompare(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"[\p{P}\p{S}\s]+$"#, with: "", options: .regularExpression)
        return t
    }

    /// Word-level diff (LCS) of served vs final span. Adjacent delete+insert
    /// pairs collapse into substitutions; leftover deletes carry `new == nil`;
    /// leftover inserts carry an empty `old`. Indices are into the served span.
    static func wordDiff(served a: [String], final b: [String]) -> [FlywheelWordChange] {
        let n = a.count, m = b.count
        if n == 0 {
            return b.enumerated().map { FlywheelWordChange(index: 0, old: "", new: $0.element) }
        }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { ops.append(.equal(i)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append(.del(i)); i += 1 }
            else { ops.append(.ins(j)); j += 1 }
        }
        while i < n { ops.append(.del(i)); i += 1 }
        while j < m { ops.append(.ins(j)); j += 1 }

        var changes: [FlywheelWordChange] = []
        var p = 0
        while p < ops.count {
            switch ops[p] {
            case .equal:
                p += 1
            case .del(let si):
                if p + 1 < ops.count, case .ins(let fj) = ops[p + 1] {
                    changes.append(FlywheelWordChange(index: si, old: a[si], new: b[fj])); p += 2
                } else {
                    changes.append(FlywheelWordChange(index: si, old: a[si], new: nil)); p += 1
                }
            case .ins(let fj):
                if p + 1 < ops.count, case .del(let si) = ops[p + 1] {
                    changes.append(FlywheelWordChange(index: si, old: a[si], new: b[fj])); p += 2
                } else {
                    let si = nextServedIndex(ops, after: p, servedCount: n)
                    changes.append(FlywheelWordChange(index: si, old: "", new: b[fj])); p += 1
                }
            }
        }
        return changes
    }

    private static func nextServedIndex(_ ops: [DiffOp], after p: Int, servedCount: Int) -> Int {
        var k = p
        while k < ops.count {
            switch ops[k] {
            case .equal(let si): return si
            case .del(let si): return si
            case .ins: k += 1
            }
        }
        return servedCount
    }
}

/// C AX callback -> back to the watcher instance. Non-capturing so it converts
/// to a C function pointer; the refcon carries the (unretained) watcher.
private let correctionWatcherValueChanged: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<CorrectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleValueChanged()
}
