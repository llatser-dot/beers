import AppKit
import SwiftUI

enum OverlayMode: Equatable {
    case listening
    case processing
}

@MainActor
final class OverlayWindowController {
    private var window: OverlayPanelWindow?
    private var hideWorkItem: DispatchWorkItem?
    private var hideGeneration = 0
    private let presentation = OverlayPresentationState()

    func show(mode: OverlayMode) {
        hideWorkItem?.cancel()
        hideGeneration += 1
        presentation.mode = mode
        presentation.menuBarHeight = targetScreen().map { max(28, $0.safeAreaInsets.top) } ?? 32

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

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
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
        panel.contentView = NotchHostingView(rootView: ListeningOverlayView(presentation: presentation))

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
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
            return NSRect(origin: .zero, size: ListeningOverlayLayout.canvasSize)
        }

        let size = ListeningOverlayLayout.canvasSize
        let x = floor(screen.frame.midX - size.width / 2)
        let y = floor(screen.frame.maxY - size.height + 1)
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}

final class OverlayPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class NotchHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    convenience init<Content: View>(rootView: Content) {
        self.init(rootView: AnyView(rootView))
    }

    @MainActor @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
