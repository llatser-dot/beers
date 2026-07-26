import Carbon
import CoreGraphics
import Foundation

enum HotkeyOption: String, CaseIterable, Identifiable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl
    case fnGlobe
    case f13

    var id: String { rawValue }

    static func savedValue(_ value: String?) -> HotkeyOption {
        HotkeyOption(rawValue: value ?? "") ?? .rightOption
    }

    var displayName: String {
        switch self {
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .leftControl: return "Left Control (⌃)"
        case .rightControl: return "Right Control (⌃)"
        case .fnGlobe: return "Fn / Globe"
        case .f13: return "F13"
        }
    }

    var shortName: String {
        switch self {
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .fnGlobe: return "Fn / Globe"
        case .f13: return "F13"
        }
    }

    /// Compact label for the Beers keycap component.
    var keycapLabel: String {
        switch self {
        case .leftCommand: return "L ⌘"
        case .rightCommand: return "R ⌘"
        case .leftOption: return "L ⌥"
        case .rightOption: return "R ⌥"
        case .leftControl: return "L ⌃"
        case .rightControl: return "R ⌃"
        case .fnGlobe: return "fn"
        case .f13: return "F13"
        }
    }

    var icon: String {
        switch self {
        case .leftCommand, .rightCommand: return "command"
        case .leftOption, .rightOption: return "option"
        case .leftControl, .rightControl: return "control"
        case .fnGlobe: return "globe"
        case .f13: return "keyboard"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftCommand: return UInt16(kVK_Command)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .leftOption: return UInt16(kVK_Option)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftControl: return UInt16(kVK_Control)
        case .rightControl: return UInt16(kVK_RightControl)
        case .fnGlobe: return UInt16(kVK_Function)
        case .f13: return UInt16(kVK_F13)
        }
    }

    /// Modifier keys only emit flagsChanged events; regular keys emit keyDown/keyUp.
    var isModifier: Bool {
        self != .f13
    }

    var modifierMask: CGEventFlags? {
        switch self {
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftControl, .rightControl: return .maskControl
        case .fnGlobe: return .maskSecondaryFn
        case .f13: return nil
        }
    }
}
