import Carbon
import Cocoa

final class HotkeyManager {
    /// Bool = Shift was held when the pour key went down (Command Mode).
    var onKeyDown: ((Bool) -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyHeld = false
    private var heldSince: CFAbsoluteTime?
    private var option: HotkeyOption = .leftCommand

    var isRegistered: Bool { eventTap != nil }

    func setOption(_ newOption: HotkeyOption) {
        guard newOption != option else { return }
        option = newOption
        isKeyHeld = false
        if isRegistered {
            register()
        }
        llog("HotkeyManager: hotkey set to \(newOption.shortName)")
    }

    func register() {
        unregister()

        guard Permissions.isInputMonitoringGranted() else {
            llog("HotkeyManager: needs Input Monitoring permission")
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        llog("HotkeyManager: re-enabled event tap")
                    }
                    return Unmanaged.passUnretained(event)
                }

                manager.handleCGEvent(type: type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            llog("HotkeyManager: failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            llog("HotkeyManager: registered \(option.shortName)")
        }
    }

    func unregister() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyHeld = false
    }

    private func handleCGEvent(type: CGEventType, _ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == option.keyCode else { return }

        let pressed: Bool
        if option.isModifier {
            guard type == .flagsChanged, let mask = option.modifierMask else { return }
            pressed = event.flags.contains(mask)
        } else if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            pressed = true
        } else if type == .keyUp {
            pressed = false
        } else {
            return
        }

        if pressed && !isKeyHeld {
            isKeyHeld = true
            heldSince = CFAbsoluteTimeGetCurrent()
            let shiftHeld = event.flags.contains(.maskShift)
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?(shiftHeld)
            }
        } else if !pressed && isKeyHeld {
            isKeyHeld = false
            // Pours intermittently end while the key is still physically held,
            // truncating the last words. Capture is provably continuous to the
            // final sample, so the end comes from this release event. Record
            // what the event actually said — a modifier release is inferred
            // from a shared flag bit (both Option keys set .maskAlternate), so
            // the raw flags and the source distinguish a real release from a
            // stray or synthesised one. Only fires for the hotkey's own
            // keycode, so this stays quiet.
            let held = heldSince.map { CFAbsoluteTimeGetCurrent() - $0 } ?? -1
            let source = event.getIntegerValueField(.eventSourceStateID)
            let isSynthetic = source != 1  // 1 == kCGEventSourceStateHIDSystemState (real hardware)
            llog(
                "Hotkey: release keyCode=\(keyCode) held=\(String(format: "%.3f", held))s "
                    + "flags=0x\(String(event.flags.rawValue, radix: 16)) sourceStateID=\(source)"
                    + (isSynthetic ? " SYNTHETIC(not-hardware)" : " hardware")
            )
            heldSince = nil
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }
        }
    }

    deinit {
        unregister()
    }
}
