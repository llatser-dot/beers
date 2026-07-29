import AppKit
import ApplicationServices
import SwiftUI

/// Offscreen design-verification harness. Launch the app with
/// `--beers-snapshot` and every surface renders to /tmp/beers-snapshots
/// as PNGs, then the app exits. No screen recording required.
enum BeersSnapshot {
    static var isRunning: Bool {
        CommandLine.arguments.contains("--beers-snapshot")
    }

    /// Synthetic, in-memory-only examples for public screenshots. The snapshot
    /// path must never render or mutate the user's real Brewer's Dictionary.
    static let demoCorrections = [
        VocabularyCorrection(heard: "git hub", replacement: "GitHub"),
        VocabularyCorrection(heard: "type script", replacement: "TypeScript"),
        VocabularyCorrection(heard: "post grass", replacement: "Postgres"),
        VocabularyCorrection(heard: "core ml", replacement: "Core ML"),
    ]

    private static let demoSuggestions = [
        VocabularySuggestion(heard: "web kit", replacement: "WebKit", count: 4),
        VocabularySuggestion(heard: "swift you eye", replacement: "SwiftUI", count: 3),
        VocabularySuggestion(heard: "app kit", replacement: "AppKit", count: 2),
    ]

    /// Relaunch smoke test: arm the helper as the real System Settings flow
    /// does, then exit without app-delegate callbacks. A normal Beers process
    /// must replace this one, without inheriting the test flag.
    @MainActor
    static func runRelaunchTestIfRequested() {
        guard CommandLine.arguments.contains("--beers-relaunch-test") else { return }
        llog("BeersSnapshot: RELAUNCH TEST starting with simulated system termination")
        Permissions.beginSystemGrantFlow()
        exit(0)
    }

    /// Drag payload smoke test: the permission lists accept the app bundle's
    /// standard file URL, matching a Finder drag.
    @MainActor
    static func runDragPayloadTestIfRequested() {
        guard CommandLine.arguments.contains("--beers-drag-payload-test") else { return }
        let bundleURL = Bundle.main.bundleURL
        let item = AppBundleDragView.pasteboardItem(for: bundleURL)
        let modernURL = item.string(forType: .fileURL)
        let passed = modernURL == bundleURL.absoluteString
            && item.types.contains(.fileURL)
        llog(
            passed
                ? "BeersSnapshot: DRAG PAYLOAD TEST PASS"
                : "BeersSnapshot: DRAG PAYLOAD TEST FAIL "
                    + "modern=\(modernURL ?? "nil") "
                    + "expected=\(bundleURL.absoluteString)"
        )
        exit(passed ? 0 : 1)
    }

    /// Route-change resilience test: `--beers-route-test` records ~6s of
    /// audio while firing the same route-change path an AirPods/headphone
    /// connect fires mid-pour, then asserts the capture survived. Before the
    /// mid-pour recovery existed this captured ~0s (buffer wiped).
    @MainActor
    static func runRouteTestIfRequested() {
        guard CommandLine.arguments.contains("--beers-route-test") else { return }
        let recorder = AudioRecorder()
        recorder.setSuppressComputerAudio(false)
        do {
            try recorder.startRecording()
        } catch {
            llog("BeersSnapshot: ROUTE TEST FAILED to start: \(error.localizedDescription)")
            exit(1)
        }

        // A connect is a burst of events, then more as profiles settle.
        for delay in [1.5, 1.6, 1.7, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                recorder.simulateRouteChangeForTesting()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            let samples = recorder.stopRecording()
            recorder.stopEngine()
            let duration = Double(samples.count) / 16000.0
            // Two recovery cycles pause capture ~0.4s each; ≥4.5s of a 6s
            // pour proves the buffer survived both rebuilds.
            if duration >= 4.5 {
                llog("BeersSnapshot: ROUTE TEST PASS captured \(String(format: "%.2f", duration))s across simulated route changes")
                exit(0)
            } else {
                llog("BeersSnapshot: ROUTE TEST FAIL captured only \(String(format: "%.2f", duration))s")
                exit(1)
            }
        }
    }

    /// Kitchen self-test: `--beers-order-test "instruction" "text"` runs
    /// Command Mode's Apple-on-device tier and prints the result to the log.
    @MainActor
    static func runOrderTestIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--beers-order-test"),
              CommandLine.arguments.count > index + 2 else { return }
        let instruction = CommandLine.arguments[index + 1]
        let text = CommandLine.arguments[index + 2]
        Task { @MainActor in
            do {
                let result = try await OrderKitchen.applyInstruction(instruction, to: text)
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
    static func runPolishTestIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--beers-polish-test"),
              CommandLine.arguments.count > index + 1 else { return }
        let text = CommandLine.arguments[index + 1]
        Task { @MainActor in
            // Diagnostic only: warm Bouncer so this parity path reflects its
            // steady state rather than the one-off cold Core ML compile.
            Bouncer.prewarm()
            let result = await OrderKitchen.polish(
                text, mode: .clean, context: .frontmost
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

    /// Vocabulary-suggestion scanner self-test: `--beers-vocab-suggest-test`.
    /// Injects a handful of synthetic correction records into an isolated temp
    /// flywheel, runs the real scanner over them, and prints the suggestions —
    /// so the extraction rules can be verified without touching the live log.
    @MainActor
    static func runVocabSuggestTestIfRequested(appState: AppState) {
        guard CommandLine.arguments.contains("--beers-vocab-suggest-test") else { return }

        // Synthetic correction records mirroring FlywheelLog.recordCorrection's
        // wire format. Cases exercised:
        //  A. Substitution "Kubernettes"->"Kubernetes", seen twice (surface).
        //  B. Merge "type script"->"TypeScript" via [del,sub], seen twice (surface).
        //  C. Grammar "i"->"I" pure casing (should NOT surface).
        //  D. Homophone "there"->"their" both lowercase (should NOT surface).
        //  E. Single occurrence "Postgress"->"Postgres" (below >=2, no surface).
        let records = [
            #"{"ts":"t1","type":"correction","pourTs":"p1","app":"Notes","served":"deploy to Kubernettes","corrected":"deploy to Kubernetes","changedWords":[[2,"Kubernettes","Kubernetes"]]}"#,
            #"{"ts":"t2","type":"correction","pourTs":"p2","app":"Slack","served":"check the Kubernettes cluster","corrected":"check the Kubernetes cluster","changedWords":[[2,"Kubernettes","Kubernetes"]]}"#,
            #"{"ts":"t3","type":"correction","pourTs":"p3","app":"Mail","served":"open the type script file","corrected":"open the TypeScript file","changedWords":[[2,"type",null],[3,"script","TypeScript"]]}"#,
            #"{"ts":"t4","type":"correction","pourTs":"p4","app":"Notes","served":"the type script build","corrected":"the TypeScript build","changedWords":[[1,"type",null],[2,"script","TypeScript"]]}"#,
            #"{"ts":"t5","type":"correction","pourTs":"p5","app":"Notes","served":"i think so","corrected":"I think so","changedWords":[[0,"i","I"]]}"#,
            #"{"ts":"t6","type":"correction","pourTs":"p6","app":"Notes","served":"i think so","corrected":"I think so","changedWords":[[0,"i","I"]]}"#,
            #"{"ts":"t7","type":"correction","pourTs":"p7","app":"Notes","served":"put there bags down","corrected":"put their bags down","changedWords":[[1,"there","their"]]}"#,
            #"{"ts":"t8","type":"correction","pourTs":"p8","app":"Notes","served":"put there bags down","corrected":"put their bags down","changedWords":[[1,"there","their"]]}"#,
            #"{"ts":"t9","type":"correction","pourTs":"p9","app":"Notes","served":"check Postgress locally","corrected":"check Postgres locally","changedWords":[[1,"Postgress","Postgres"]]}"#,
        ]
        let result = VocabularySuggestions.runScan(onRecords: records, existing: [])
        llog("BeersSnapshot: VOCAB SUGGEST TEST — \(result.count) suggestion(s)")
        for s in result {
            llog("BeersSnapshot: VOCAB SUGGEST — '\(s.heard)' -> '\(s.replacement)' x\(s.count)")
        }
        exit(0)
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

    /// Flywheel wipe self-test: `--beers-wipe-test`. Drives the real
    /// `FlywheelLog.wipe()` against the live Application Support dir and logs how
    /// many files it removed, so the "Pour it away" path can be verified
    /// end-to-end. (Test harness backs up and restores real data around it.)
    @MainActor
    static func runWipeTestIfRequested() {
        guard CommandLine.arguments.contains("--beers-wipe-test") else { return }
        let removed = FlywheelLog.wipe()
        llog("BeersSnapshot: WIPE TEST removed \(removed) file(s)")
        exit(0)
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

            // The learning/privacy disclosure step (step index 2 of 4).
            snap(FirstRoundView(initialStep: 2).environmentObject(appState),
                 size: CGSize(width: 380, height: 540), name: "first-round-learning", in: dir)

            // The doorman guide: drag-the-bottle walkthrough for Accessibility.
            snap(FirstRoundView(initialStep: 0, initialGuide: .accessibility).environmentObject(appState),
                 size: CGSize(width: 380, height: 540), name: "first-round-doorman", in: dir)

            // The floating coach that outlives System Settings taking focus.
            snap(GrantCoachView(grant: .accessibility, forceUngrantedForSnapshot: true)
                    .environmentObject(appState),
                 size: CGSize(width: 344, height: 430), name: "grant-coach", in: dir)
            snap(GrantCoachView(grant: .inputMonitoring, forceUngrantedForSnapshot: true)
                    .environmentObject(appState),
                 size: CGSize(width: 344, height: 430), name: "grant-coach-input-monitoring", in: dir)

            snap(StatusBarView().environmentObject(appState),
                 size: nil, name: "bar-tap", in: dir)

            // Seed correction-driven vocabulary suggestions so the Brewer's
            // Dictionary crate renders its "Suggestions from your fixes" section
            // (mirrors how seededStore() seeds the Taproom's pours).
            appState.vocabularySuggestions = demoSuggestions
            snap(BrewControlsView(snapshotInputDeviceName: "MacBook Microphone").environmentObject(appState),
                 size: CGSize(width: 560, height: 720), name: "brew-controls", in: dir)

            // Focused capture of the Brewer's Dictionary crate — the suggestions
            // section lives below the scroll fold in the full Brew Settings shot.
            let vocabCrate = BeersCrate(
                title: "Brewer’s Dictionary", emoji: "📖", headerColor: Beers.cream2
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    VocabularyEditorView(compact: true, showsTitle: false)
                        .padding(16)
                }
            }
            .padding(22)
            .frame(width: 560)
            .background(Beers.cream)
            .environment(\.colorScheme, .light)
            snap(vocabCrate.environmentObject(appState),
                 size: CGSize(width: 560, height: 620), name: "brew-vocab", in: dir)

            // Focused capture of the privacy/learning crate — it lives below the
            // scroll fold in the full Brew Settings shot. Mirrors the live
            // blackBookCrate; benchmark audio remains explicitly OFF.
            let blackBook = BeersCrate(
                title: "The Little Black Book", emoji: "📓", headerColor: Beers.hopsDeep
            ) {
                BeersSettingRow(
                    label: "Learn from my pours",
                    hint: "Private local learning record"
                ) {
                    Toggle("", isOn: .constant(true))
                        .labelsHidden().toggleStyle(BeersToggleStyle())
                }
                BeersSettingRow(
                    label: "Watch my fixes",
                    hint: "Finds dictionary entries in your fixes"
                ) {
                    Toggle("", isOn: .constant(true))
                        .labelsHidden().toggleStyle(BeersToggleStyle())
                }
                BeersSettingRow(
                    label: "Bouncer on the door",
                    hint: "On-device cleanup research is parked until it meets the accuracy gate"
                ) {
                    BeersChip { Text("Parked") }
                }
                BeersSettingRow(
                    label: "Capture ASR benchmark audio",
                    hint: "Optional local audio capture for comparing speech engines"
                ) {
                    Toggle("", isOn: .constant(false))
                        .labelsHidden().toggleStyle(BeersToggleStyle())
                }
                BeersSettingRow(
                    label: "Pour it away",
                    hint: "Delete every training record from this Mac, forever",
                    showDivider: false
                ) {
                    Button("Pour away…") {}
                        .buttonStyle(BeersButtonStyle(kind: .stoutGhost, small: true))
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Beers.hopsDeep)
                    Text("Learning and benchmark records stay on this Mac. Beers never uploads them.")
                        .font(Beers.ui(11.5, .semibold))
                        .foregroundStyle(Beers.ink.opacity(0.6))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 13)
            }
            .padding(22)
            .frame(width: 560)
            .background(Beers.cream)
            .environment(\.colorScheme, .light)
            snap(blackBook.environmentObject(appState),
                 size: CGSize(width: 560, height: 430), name: "brew-blackbook", in: dir)

            let store = seededStore()
            snap(TaproomView(store: store).environmentObject(appState),
                 size: CGSize(width: 940, height: 620), name: "taproom", in: dir)

            // Drunk Slurs: the corrections editor in its new home, reached the
            // same way Brew Settings reaches it.
            snap(TaproomView(store: store, initialSection: .slurs).environmentObject(appState),
                 size: CGSize(width: 940, height: 620), name: "taproom-slurs", in: dir)
            // Pub Wall uses only its live public response. Never seed invented
            // members or totals into this snapshot.
            snap(PubWallView().environmentObject(appState),
                 size: CGSize(width: 740, height: 620), name: "pub-wall", in: dir)

            snapHUD(mode: .pouring, name: "hud-pouring", in: dir)
            snapHUD(mode: .settling, name: "hud-settling", in: dir)
            snapHUD(mode: .served(words: 42), name: "hud-served", in: dir)
            snapHUD(mode: .takingOrder, name: "hud-taking-order", in: dir)
            snapHUD(mode: .notice("Kitchen's closed — Apple model unavailable"), name: "hud-notice", in: dir)

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
        // In-memory only: snapshots must NEVER render the user's real pours
        // (a taproom screenshot of real dictations is a privacy leak).
        let store = PourStore(inMemory: true)
        let samples: [(String, String, TimeInterval)] = [
            ("Please move Thursday’s workshop to 2 pm and add the updated brief to the invite.", "Mail", 18),
            ("Today: finish the release notes, review the pull request, then test the new onboarding flow.", "Slack", 14),
            ("Draft the launch note: Beers runs on your Mac and never sends audio to a server.", "Notes", 17),
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
