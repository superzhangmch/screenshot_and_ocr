import AppKit

final class OverlayWindow: NSWindow {
    private let snapshot: ScreenSnapshot
    private weak var controller: OverlayController?
    private let overlayView: OverlayView

    init(snapshot: ScreenSnapshot, controller: OverlayController) {
        self.snapshot = snapshot
        self.controller = controller
        self.overlayView = OverlayView(snapshot: snapshot)

        super.init(contentRect: snapshot.frame,
                   styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
        self.contentView = overlayView
        // display: true asks AppKit to schedule a draw pass when the window first becomes
        // visible. Calling displayIfNeeded() during init was crashing (autorelease pool
        // over-release in a half-constructed window) — that's been removed.
        self.setFrame(snapshot.frame, display: true)

        overlayView.onSelectionFinished = { [weak self] localRect in
            guard let self = self, let controller = self.controller else { return }
            let global = NSRect(x: snapshot.frame.minX + localRect.minX,
                                y: snapshot.frame.minY + localRect.minY,
                                width: localRect.width,
                                height: localRect.height)
            controller.finishSelection(rect: global, on: snapshot.screen)
        }
        overlayView.onCancel = { [weak self] in self?.controller?.cancel() }
    }

    var snapshotScreen: NSScreen { snapshot.screen }

    func dimAndHide() { self.orderOut(nil) }

    /// Lock the visible selection in place and stop responding to mouse input,
    /// so the editor + toolbar can sit above this window and the gray context
    /// stays visible behind them until the user closes / copies.
    func freeze(at lockedRect: NSRect) { overlayView.freeze(at: lockedRect) }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 /* Esc */ { controller?.cancel() }
        else { super.keyDown(with: event) }
    }
}
