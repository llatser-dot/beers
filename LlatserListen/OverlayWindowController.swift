import AppKit
import SwiftUI

enum OverlayMode: Equatable {
    case pouring
    case settling
    case served(words: Int)
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

        if case .pouring = mode, presentation.mode != .pouring || !presentation.isVisible {
            presentation.pourStart = Date()
        }
        presentation.mode = mode

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

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
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
        guard let screen = targetScreen() else {
            return NSRect(origin: .zero, size: PourHUDLayout.canvasSize)
        }

        let size = PourHUDLayout.canvasSize
        let x = floor(screen.visibleFrame.midX - size.width / 2)
        let y = screen.visibleFrame.minY + PourHUDLayout.bottomMargin
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
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
