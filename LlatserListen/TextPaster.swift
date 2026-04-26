import AppKit
import ApplicationServices

final class TextPaster {
    @discardableResult
    func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            llog("TextPaster: failed to write text to pasteboard")
            return false
        }

        guard Permissions.isAccessibilityGranted() || Permissions.requestAccessibility(prompt: true) else {
            llog("TextPaster: copied text to pasteboard, but Accessibility is not granted")
            return false
        }

        llog("TextPaster: copied text to pasteboard, posting Cmd+V")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simulatePaste()
        }
        return true
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
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        llog("TextPaster: posted Cmd+V to HID tap")
    }
}
