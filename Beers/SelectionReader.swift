import AppKit
import ApplicationServices

/// Reads the selected text in the frontmost app for Command Mode.
/// Accessibility API first; falls back to a synthetic Cmd+C with
/// pasteboard capture and restore.
enum SelectionReader {
    static func selectedText(completion: @escaping (String) -> Void) {
        if let text = axSelectedText(), !text.isEmpty {
            llog("SelectionReader: AX selection (\(text.count) chars)")
            completion(text)
            return
        }
        copySelectedText(completion: completion)
    }

    private static func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else { return nil }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected
        ) == .success else { return nil }

        return selected as? String
    }

    private static func copySelectedText(completion: @escaping (String) -> Void) {
        let pasteboard = NSPasteboard.general
        let savedItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        let changeCountBefore = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            completion("")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let text: String
            if pasteboard.changeCount != changeCountBefore {
                text = pasteboard.string(forType: .string) ?? ""
            } else {
                text = ""
            }
            // Put the user's clipboard back.
            if !savedItems.isEmpty {
                pasteboard.clearContents()
                pasteboard.writeObjects(savedItems)
            }
            llog("SelectionReader: Cmd+C fallback (\(text.count) chars)")
            completion(text)
        }
    }
}
