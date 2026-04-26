import Carbon
import Cocoa

final class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyHeld = false
    private let targetKeyCode: UInt16 = 61 // Right Option

    var isRegistered: Bool { eventTap != nil }

    func register() {
        unregister()

        guard Permissions.isInputMonitoringGranted() else {
            llog("HotkeyManager: needs Input Monitoring permission")
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
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

                manager.handleCGEvent(event)
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
            llog("HotkeyManager: registered Right Option")
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

    private func handleCGEvent(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return }

        let optionDown = event.flags.contains(.maskAlternate)
        if optionDown && !isKeyHeld {
            isKeyHeld = true
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?()
            }
        } else if !optionDown && isKeyHeld {
            isKeyHeld = false
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }
        }
    }

    deinit {
        unregister()
    }
}
