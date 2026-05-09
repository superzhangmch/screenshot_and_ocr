import AppKit

struct SelectionResult {
    let image: CGImage
    let globalRect: NSRect
    let screen: NSScreen
}

final class OverlayController {
    private var windows: [OverlayWindow] = []
    private let snapshots: [ScreenSnapshot]
    private let completion: (SelectionResult?) -> Void
    private var didFinish = false

    init(snapshots: [ScreenSnapshot], completion: @escaping (SelectionResult?) -> Void) {
        self.snapshots = snapshots
        self.completion = completion
    }

    func show() {
        for snap in snapshots {
            let win = OverlayWindow(snapshot: snap, controller: self)
            win.makeKeyAndOrderFront(nil)
            windows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func cancel() { finish(with: nil) }

    func finishSelection(rect rawRect: NSRect, on screen: NSScreen) {
        guard !didFinish else { return }
        // Snap to integer points so the crop, the overlay's punch-out hole, and the editor
        // window's frame all use the SAME pixel grid. Without this, sub-pixel coords mean
        // the cropped image gets resampled into a slightly different rectangle than the
        // overlay's hole, producing a visible "snap" when the editor appears.
        let globalRect = NSRect(x: rawRect.minX.rounded(),
                                y: rawRect.minY.rounded(),
                                width: rawRect.width.rounded(),
                                height: rawRect.height.rounded())
        guard let snap = snapshots.first(where: { $0.screen == screen }),
              let cropped = crop(snapshot: snap, globalRect: globalRect) else {
            finish(with: nil); return
        }
        for w in windows {
            let win = w
            if win.snapshotScreen == screen {
                let local = NSRect(x: globalRect.minX - snap.frame.minX,
                                   y: globalRect.minY - snap.frame.minY,
                                   width: globalRect.width, height: globalRect.height)
                win.freeze(at: local)
            } else {
                win.freeze(at: .zero)
            }
        }
        let result = SelectionResult(image: cropped, globalRect: globalRect, screen: screen)
        didFinish = true
        ToolbarController.present(
            for: result,
            onClose: { [weak self] in
                guard let self = self else { return }
                for w in self.windows { w.orderOut(nil) }
                self.windows.removeAll()
                self.completion(result)
            },
            onSelectionResize: { [weak self] newGlobal in
                // Editor resized → update the overlay's frozen rect so the dim + border
                // follow the new selection.
                self?.refreezeOverlay(at: newGlobal)
            },
            recropOnResize: { [weak self] newGlobal in
                // Drag end → re-crop the snapshot for the new rect.
                self?.crop(globalRect: newGlobal)
            }
        )
        ClipboardService.copy(image: cropped)
    }

    /// Updates each overlay window's "frozen" selection display to a new global rect.
    private func refreezeOverlay(at globalRect: NSRect) {
        for w in windows {
            let scrFrame = w.snapshotScreen.frame
            if scrFrame.intersects(globalRect) {
                let local = NSRect(x: globalRect.minX - scrFrame.minX,
                                   y: globalRect.minY - scrFrame.minY,
                                   width: globalRect.width,
                                   height: globalRect.height)
                w.freeze(at: local)
            } else {
                w.freeze(at: .zero)
            }
        }
    }

    /// Re-crop the snapshot for the screen that contains `globalRect`. Used after a
    /// resize drag ends so copy/save/OCR see the updated pixels.
    private func crop(globalRect: NSRect) -> CGImage? {
        guard let snap = snapshots.first(where: { $0.frame.intersects(globalRect) }) else { return nil }
        return crop(snapshot: snap, globalRect: globalRect)
    }

    static func handleSelectionResult(_ result: SelectionResult) {}

    private func finish(with result: SelectionResult?) {
        guard !didFinish else { return }
        didFinish = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        completion(result)
    }

    private func crop(snapshot: ScreenSnapshot, globalRect: NSRect) -> CGImage? {
        let sf = snapshot.frame
        let imgW = CGFloat(snapshot.image.width)
        let imgH = CGFloat(snapshot.image.height)
        let scaleX = imgW / sf.width
        let scaleY = imgH / sf.height

        let localX = (globalRect.minX - sf.minX) * scaleX
        let localYTopLeft = (sf.maxY - globalRect.maxY) * scaleY
        let w = globalRect.width * scaleX
        let h = globalRect.height * scaleY
        let cropRect = CGRect(x: localX.rounded(), y: localYTopLeft.rounded(),
                              width: w.rounded(), height: h.rounded())
                          .intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard cropRect.width > 1, cropRect.height > 1 else { return nil }
        return snapshot.image.cropping(to: cropRect)
    }
}
