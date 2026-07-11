import AppKit
import ApplicationServices

final class TextPaster {
    private enum Timing {
        static let keyUpDelay: TimeInterval = 0.02
        static let restoreDelay: TimeInterval = 5.0
    }

    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
        let changeCount: Int
    }

    @discardableResult
    func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = captureSnapshot(from: pasteboard)
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            llog("TextPaster: failed to write text to pasteboard")
            restoreSnapshot(snapshot, to: pasteboard)
            return false
        }

        let axTrusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        llog("TextPaster: AXIsProcessTrusted=\(axTrusted) CGPreflightPostEventAccess=\(postAccess)")

        guard Permissions.isAccessibilityGranted() || Permissions.requestAccessibility(prompt: true) else {
            llog("TextPaster: copied text to pasteboard, but Accessibility is not granted")
            return false
        }

        if !postAccess {
            // AX trust alone doesn't guarantee synthetic events are delivered.
            let granted = CGRequestPostEventAccess()
            llog("TextPaster: requested post-event access, granted=\(granted)")
        }

        let front = NSWorkspace.shared.frontmostApplication
        llog("TextPaster: pasting into frontmost='\(front?.localizedName ?? "?")' bundle='\(front?.bundleIdentifier ?? "?")'")
        llog("TextPaster: copied text to pasteboard, posting Cmd+V")
        simulatePaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.restoreDelay) {
            let currentPasteboard = NSPasteboard.general
            if currentPasteboard.string(forType: .string) == text {
                self.restoreSnapshot(snapshot, to: currentPasteboard)
                llog("TextPaster: restored previous pasteboard")
            }
        }
        return true
    }

    private func captureSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    copy.setString(string, forType: type)
                }
            }
            return copy
        } ?? []

        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    private func restoreSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        guard snapshot.items.isEmpty == false else { return }
        pasteboard.clearContents()
        let objects = snapshot.items.map { $0 as NSPasteboardWriting }
        pasteboard.writeObjects(objects)
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            llog("TextPaster: failed to create Cmd+V event")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.keyUpDelay) {
            keyUp.post(tap: .cgSessionEventTap)
            llog("TextPaster: posted Cmd+V to session tap")
        }
    }
}
