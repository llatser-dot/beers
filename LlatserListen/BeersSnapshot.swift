import AppKit
import ApplicationServices
import SwiftUI

/// Offscreen design-verification harness. Launch the app with
/// `--beers-snapshot` and every surface renders to /tmp/beers-snapshots
/// as PNGs, then the app exits. No screen recording required.
enum BeersSnapshot {
    /// Kitchen self-test: `--beers-order-test "instruction" "text"` runs
    /// Command Mode's model tiers and prints the result to the log.
    @MainActor
    static func runOrderTestIfRequested(appState: AppState) {
        guard let index = CommandLine.arguments.firstIndex(of: "--beers-order-test"),
              CommandLine.arguments.count > index + 2 else { return }
        let instruction = CommandLine.arguments[index + 1]
        let text = CommandLine.arguments[index + 2]
        Task { @MainActor in
            do {
                let settings = AIRewriteSettings(
                    isEnabled: true,
                    endpoint: appState.aiRewriteEndpoint,
                    model: appState.aiRewriteModel
                )
                let result = try await OrderKitchen.applyInstruction(instruction, to: text, settings: settings)
                llog("BeersSnapshot: ORDER TEST RESULT='\(result)'")
            } catch {
                llog("BeersSnapshot: ORDER TEST FAILED: \(error.localizedDescription)")
            }
            exit(0)
        }
    }

    /// Polish self-test: `--beers-polish-test "rambly text"` runs the
    /// per-pour cleanup tiers and prints the result to the log.
    @MainActor
    static func runPolishTestIfRequested(appState: AppState) {
        guard let index = CommandLine.arguments.firstIndex(of: "--beers-polish-test"),
              CommandLine.arguments.count > index + 1 else { return }
        let text = CommandLine.arguments[index + 1]
        Task { @MainActor in
            // Warm the Bouncer first so the shadow pass reflects the
            // prewarmed steady state real pours see (prewarmPolish warms it
            // during recording), not the one-off cold Core ML compile.
            Bouncer.prewarm()
            let settings = AIRewriteSettings(
                isEnabled: true,
                endpoint: appState.aiRewriteEndpoint,
                model: appState.aiRewriteModel
            )
            let result = await OrderKitchen.polish(
                text, mode: .clean, context: .frontmost, settings: settings
            )
            llog("BeersSnapshot: POLISH TEST RESULT='\(result.text)' [tier=\(result.tier.rawValue)]")
            // Exercise the flywheel end-to-end: this writes a real record to
            // flywheel.jsonl exactly as a live pour would (raw = the test input,
            // no rule-polisher ran so rulePolished is null).
            FlywheelLog.record(
                raw: text,
                rulePolished: nil,
                served: result.text,
                tier: result.tier.rawValue,
                bouncerWouldDelete: result.shadow?.deletedIndices,
                bouncerMs: result.shadow?.elapsedMillis
            )
            FlywheelLog.flush()  // short-lived process: ensure the write lands before exit
            exit(0)
        }
    }

    /// Bouncer parity self-test: `--beers-bouncer-test "text"` prints every
    /// word with its P(DELETE) and the model's cleaned text, so the Swift
    /// WordPiece tokenizer + Core ML decisions can be diffed against the Python
    /// pipeline (`ml/export/verify_parity.py`) for the same string.
    @MainActor
    static func runBouncerTestIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--beers-bouncer-test"),
              CommandLine.arguments.count > index + 1 else { return }
        let text = CommandLine.arguments[index + 1]
        // Give Core ML a beat to compile/load the model on cold launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Bouncer.prewarm()  // measure the warm, steady-state pass
            let v = Bouncer.review(text)
            llog("Bouncer[test]: available=\(v.modelAvailable) threshold=\(v.threshold) "
                 + "target_met=\(v.targetMet) elapsed=\(String(format: "%.1f", v.elapsedMillis))ms")
            for (i, w) in v.words.enumerated() {
                let p = String(format: "%.4f", v.deleteProbabilities[i])
                let mark = v.deletedIndices.contains(i) ? " <-- DELETE" : ""
                llog("Bouncer[test]: \(w):\(p)\(mark)")
            }
            llog("Bouncer[test]: cleaned='\(v.cleanedText)'")
            exit(0)
        }
    }

    /// End-to-end correction-watcher self-test:
    /// `--beers-correction-test "served text" "edit to make"`.
    ///
    /// Drives the REAL CorrectionWatcher code path: writes a pour record,
    /// pastes `served text` into the frontmost field, starts the watcher, then
    /// simulates the user's keyboard edit by setting the field value via AX to
    /// `edit to make`, and finally forces the watch to end so it evaluates and
    /// writes a correction record. Two sentinels for the second argument:
    ///   __NOEDIT__   — paste + watch but make NO edit (expect no record).
    ///   __SKIPTEST__ — don't paste; just point the watcher at the current
    ///                  frontmost (e.g. a Terminal) to exercise the skip path.
    @MainActor
    static func runCorrectionTestIfRequested(appState: AppState) {
        guard let index = CommandLine.arguments.firstIndex(of: "--beers-correction-test"),
              CommandLine.arguments.count > index + 2 else { return }
        let served = CommandLine.arguments[index + 1]
        let edit = CommandLine.arguments[index + 2]

        // Skip-path check: no paste, just start the watcher against whatever is
        // frontmost. Safe to run with a Terminal focused.
        if edit == "__SKIPTEST__" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let ts = FlywheelLog.record(
                    raw: served, rulePolished: nil, served: served,
                    tier: "rule-fallback", bouncerWouldDelete: nil, bouncerMs: nil
                ) ?? ""
                appState.correctionWatcher.start(servedText: served, pourTs: ts)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    FlywheelLog.flush()
                    exit(0)
                }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let ts = FlywheelLog.record(
                raw: served, rulePolished: nil, served: served,
                tier: "rule-fallback", bouncerWouldDelete: nil, bouncerMs: nil
            ) ?? ""
            let paster = TextPaster()
            _ = paster.paste(served)

            // Let the paste land, then start the watcher (mirrors the pour path).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                appState.correctionWatcher.start(servedText: served, pourTs: ts)

                if edit == "__NOEDIT__" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        appState.correctionWatcher.stop()
                        FlywheelLog.flush()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                    }
                    return
                }

                // Simulate the user's keyboard edit by rewriting the field value.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    setFocusedValue(edit)
                    // Give the watcher's poll a couple of ticks to capture it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        appState.correctionWatcher.stop()
                        FlywheelLog.flush()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                    }
                }
            }
        }
    }

    /// Set the focused element's AX value — a stand-in for the user typing.
    @MainActor
    private static func setFocusedValue(_ text: String) {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let f = focused else {
            llog("BeersSnapshot: correction test — no focused element to edit")
            return
        }
        let el = f as! AXUIElement
        let result = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
        llog("BeersSnapshot: correction test set value result=\(result.rawValue)")
    }

    /// End-to-end paste self-test: focuses whatever is frontmost and pastes
    /// a marker string 2s after launch, then exits.
    @MainActor
    static func runPasteTestIfRequested() {
        guard CommandLine.arguments.contains("--beers-paste-test") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let paster = TextPaster()
            let ok = paster.paste("BEERS PASTE TEST OK ")
            llog("BeersSnapshot: paste test returned \(ok)")
            // Outlive the 5s pasteboard restore so the clipboard comes back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { exit(0) }
        }
    }

    @MainActor
    static func runIfRequested(appState: AppState) {
        guard CommandLine.arguments.contains("--beers-snapshot") else { return }

        let dir = URL(fileURLWithPath: "/tmp/beers-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Delay slightly so fonts/assets settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snap(FirstRoundView().environmentObject(appState),
                 size: CGSize(width: 380, height: 540), name: "first-round", in: dir)

            snap(StatusBarView().environmentObject(appState),
                 size: nil, name: "bar-tap", in: dir)

            snap(BrewControlsView().environmentObject(appState),
                 size: CGSize(width: 560, height: 720), name: "brew-controls", in: dir)

            let store = seededStore()
            snap(TaproomView(store: store).environmentObject(appState),
                 size: CGSize(width: 940, height: 620), name: "taproom", in: dir)

            snapHUD(mode: .pouring, name: "hud-pouring", in: dir)
            snapHUD(mode: .settling, name: "hud-settling", in: dir)
            snapHUD(mode: .served(words: 42), name: "hud-served", in: dir)
            snapHUD(mode: .takingOrder, name: "hud-taking-order", in: dir)
            snapHUD(mode: .notice("Kitchen's closed — no model at your endpoint"), name: "hud-notice", in: dir)

            llog("BeersSnapshot: wrote snapshots to \(dir.path)")
            exit(0)
        }
    }

    @MainActor
    private static func snapHUD(mode: OverlayMode, name: String, in dir: URL) {
        let presentation = OverlayPresentationState()
        presentation.isVisible = true
        presentation.mode = mode
        snap(
            PourHUDView(presentation: presentation),
            size: PourHUDLayout.canvasSize,
            name: name,
            in: dir
        )
    }

    @MainActor
    private static func seededStore() -> PourStore {
        let store = PourStore()
        store.persistenceEnabled = false
        guard store.active.isEmpty else { return store }
        let samples: [(String, String, TimeInterval)] = [
            ("Send the invoice over to Dave and cc the accountant, tell him it's the March one.", "Mail", 19),
            ("Standup notes — shipped the tunnel fix, blocked on the cert, next up the retry queue.", "Slack", 12),
            ("Idea: the onboarding should literally pour the first beer for you.", "Notes", 48),
        ]
        for (text, app, duration) in samples {
            store.add(Pour(text: text, appName: app, duration: duration))
        }
        return store
    }

    @MainActor
    private static func snap<V: View>(
        _ view: V,
        size: CGSize?,
        name: String,
        in dir: URL
    ) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
        let target = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: target)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        llog("BeersSnapshot: \(name) \(Int(target.width))x\(Int(target.height))")
    }
}
