import AppKit
import SwiftUI

enum OverlayMode: Equatable {
    case pouring
    case settling
    case served(words: Int)
    /// Command Mode: recording the spoken instruction.
    case takingOrder
    /// Command Mode: Apple's on-device model is applying the instruction.
    case workingOrder
    /// Brief failure notice (e.g. Apple's model is unavailable).
    case notice(String)
}

/// The Pour HUD: a borderless, non-activating panel slapped onto the
/// bottom-center of the screen like a coaster. Never steals focus,
/// never takes clicks.
@MainActor
final class OverlayWindowController {
    private var window: OverlayPanelWindow?
    private var hideWorkItem: DispatchWorkItem?
    private var hideGeneration = 0
    private let presentation = OverlayPresentationState()

    func show(mode: OverlayMode) {
        hideWorkItem?.cancel()
        hideGeneration += 1

        switch mode {
        case .pouring where presentation.mode != .pouring || !presentation.isVisible,
             .takingOrder where presentation.mode != .takingOrder || !presentation.isVisible:
            presentation.pourStart = Date()
        default:
            break
        }
        presentation.mode = mode
        presentation.position = HUDPosition.current

        if presentation.position == .notch, let screen = targetScreen(for: .notch) {
            let inset = screen.safeAreaInsets.top
            presentation.notchHeight = inset > 0 ? inset : 34
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                // Exact camera-housing width so the island reads as part of it.
                presentation.notchWidth = max(120, min(340, screen.frame.width - left.width - right.width))
            } else {
                presentation.notchWidth = 190
            }
        }

        if let window {
            position(window)
            window.orderFrontRegardless()
            presentation.isVisible = true
            return
        }

        let panel = OverlayPanelWindow(
            contentRect: frameOnTargetScreen(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // isFloatingPanel resets the window level to .floating (3), which sits
        // BELOW the menu bar (24) — that silently hid the whole notch island
        // behind the menu bar strip. It must be set before the level, never after.
        panel.isFloatingPanel = true
        // Menu-bar items are separate windows and can be ordered above another
        // status-level panel. The pop-up layer keeps the HUD fully in front of
        // crowded status items while remaining below system screen-saver UI.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.contentView = PourHostingView(rootView: PourHUDView(presentation: presentation))

        window = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.presentation.isVisible = true
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()
        hideGeneration += 1
        let generation = hideGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.presentation.isVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.hideGeneration == generation else { return }
                self.window?.orderOut(nil)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func position(_ window: NSWindow) {
        window.setFrame(frameOnTargetScreen(), display: true, animate: false)
    }

    private func frameOnTargetScreen() -> NSRect {
        let placement = HUDPosition.current
        guard let screen = targetScreen(for: placement) else {
            return NSRect(origin: .zero, size: PourHUDLayout.canvasSize)
        }

        let size = PourHUDLayout.canvasSize
        switch placement {
        case .notch:
            // Flush with the very top so the pill slides out of the notch
            // and its wings sit inside the menu bar strip.
            return NSRect(
                x: floor(screen.frame.midX - size.width / 2),
                y: screen.frame.maxY - size.height,
                width: size.width, height: size.height
            )
        case .topRight:
            return NSRect(
                x: screen.visibleFrame.maxX - size.width,
                y: screen.visibleFrame.maxY - size.height,
                width: size.width, height: size.height
            )
        case .bottom:
            return NSRect(
                x: floor(screen.visibleFrame.midX - size.width / 2),
                y: screen.visibleFrame.minY + PourHUDLayout.bottomMargin,
                width: size.width, height: size.height
            )
        }
    }

    private func targetScreen(for placement: HUDPosition) -> NSScreen? {
        if placement == .notch {
            // Prefer the screen that actually has a notch.
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return notched
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

final class OverlayPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class PourHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    convenience init<Content: View>(rootView: Content) {
        self.init(rootView: AnyView(rootView))
    }

    @MainActor @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
