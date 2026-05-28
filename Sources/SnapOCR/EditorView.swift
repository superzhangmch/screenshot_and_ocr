import AppKit

/// Annotated image canvas. Tools:
/// - .line: click-drag for a straight line
/// - .freehand: click-drag for a smooth brush stroke
/// - .text: click anywhere → an inline NSTextField appears at the cursor and gets focus.
///   Clicking again (or pressing ⏎/Esc) commits the current field; you can drop multiple
///   text annotations in one session.
/// Which corner / edge of the editor's bounds the user grabbed for resize.
enum ResizeHandle {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
}

final class EditorView: NSView {
    enum Tool { case select, line, freehand, rectangle, text, mosaic }

    /// Invisible "halo" pad around the visible selection. The editor window is sized
    /// `selection.insetBy(-halo, -halo)` so clicks up to `halo` pt OUTSIDE the visible
    /// corner still land on the editor and can be picked up by the resize hit-test.
    static let halo: CGFloat = 20

    private(set) var baseImage: CGImage
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []

    private var lineDragStart: NSPoint?
    private var liveLineEnd: NSPoint?
    private var liveStrokePoints: [NSPoint] = []
    private var mosaicDragStart: NSPoint?
    private var liveMosaicRect: NSRect?
    private var rectDragStart: NSPoint?
    private var liveRect: NSRect?

    /// Currently selected annotation (highlighted with a dashed outline). Click an
    /// annotation to select; click empty space to deselect; press Delete to remove.
    private var selectedAnnotationIndex: Int?
    /// Dragging any annotation by its index. Set on mouseDown when a click hits an
    /// existing annotation; cleared on mouseUp.
    private var draggingAnnotationIndex: Int?
    private var dragLastPoint: NSPoint = .zero

    /// Active text view, if any. Auto-commits on next mouseDown / tool switch.
    private weak var activeTextView: LiveTextView?
    /// Cursor-hint subview placed at the bottom-right corner of the active text input.
    /// Owned by EditorView (unflipped) so its tracking-area coordinates can't be
    /// mis-interpreted the way a child of the flipped NSTextView was.
    private var inputHandleHint: HandleHintView?

    /// Active resize-handle drag (set on mouseDown over a handle, cleared on mouseUp).
    private var draggingHandle: ResizeHandle?
    private var anchorWindowFrame: NSRect = .zero
    private var anchorMouseScreen: NSPoint = .zero
    /// True while the user is dragging empty area in select mode to move the whole
    /// selection box. Reuses anchorWindowFrame + anchorMouseScreen.
    private var draggingSelection: Bool = false

    /// Fired continuously while the user resizes via a handle (live preview).
    /// The new editor window frame in screen coordinates.
    var onResize: ((NSRect) -> Void)?
    /// Fired once when the resize drag ends — the caller (ToolbarController) re-crops
    /// the snapshot for the new rect and replaces the base image.
    var onResizeEnded: ((NSRect) -> Void)?

    var tool: Tool = .freehand {
        didSet {
            commitActiveTextField()
            // Switching away from select clears the visual highlight to avoid confusion;
            // selection only "lives" while in select mode.
            if tool != .select { selectedAnnotationIndex = nil }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var strokeColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 2

    init(image: CGImage, frame: NSRect) {
        self.baseImage = image
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// CRITICAL: NSView's default mouseDownCanMoveWindow returns true when the host
    /// window's background is fully transparent (alpha=0). Ours is — the overlay below
    /// shows the screenshot. With true, AppKit hijacks mouseDown to drag the window,
    /// suppressing our handler. That's the "handles work sometimes" bug. Force false.
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .text: cursor = .iBeam
        case .select: cursor = .arrow
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - undo / redo

    func undo() {
        commitActiveTextField()
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        annotations.append(next)
        needsDisplay = true
    }

    var canUndo: Bool { !annotations.isEmpty || activeTextView != nil }

    var hasActiveTextField: Bool { activeTextView != nil }

    /// While the user is typing in a live text input, repaint the existing characters
    /// AND set typingAttributes so future characters use the new color too.
    func applyColorToActiveText(_ color: NSColor) {
        guard let tv = activeTextView else { return }
        tv.textColor = color
        if let storage = tv.textStorage {
            storage.addAttribute(.foregroundColor, value: color,
                                  range: NSRange(location: 0, length: storage.length))
        }
        var attrs = tv.typingAttributes
        attrs[.foregroundColor] = color
        tv.typingAttributes = attrs
    }

    /// Apply a new color to the currently-selected annotation (works for line, stroke,
    /// and text). No-op if no selection.
    func applyColorToSelected(_ color: NSColor) {
        guard let idx = selectedAnnotationIndex, idx < annotations.count else { return }
        annotations[idx] = annotations[idx].withColor(color)
        needsDisplay = true
    }

    /// Apply a new stroke width to the selected annotation. Lines/strokes only —
    /// text annotations ignore width (font size is the relevant property; use ⌘+/⌘-).
    func applyWidthToSelected(_ width: CGFloat) {
        guard let idx = selectedAnnotationIndex, idx < annotations.count else { return }
        annotations[idx] = annotations[idx].withWidth(width)
        needsDisplay = true
    }

    /// Delete the currently selected annotation (if any). Returns true if something
    /// was removed so the caller can swallow the keystroke.
    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        guard let idx = selectedAnnotationIndex, idx < annotations.count else { return false }
        annotations.remove(at: idx)
        // Don't push to redoStack — Delete is a destructive user action; undo with ⌘Z works
        // (it pops from `annotations` though, which is empty for this entry).
        // Simpler: not in redo. User can always redraw.
        selectedAnnotationIndex = nil
        needsDisplay = true
        return true
    }

    /// Adjust the live text view's font size by `delta` points (⌘+ / ⌘-).
    /// The text view auto-resizes its frame in response.
    func adjustActiveTextSize(by delta: CGFloat) {
        guard let tv = activeTextView, let font = tv.font else { return }
        let newSize = max(8, min(96, font.pointSize + delta))
        let newFont = NSFont.systemFont(ofSize: newSize, weight: .medium)
        tv.font = newFont
        // Apply across existing characters
        if let storage = tv.textStorage {
            storage.addAttribute(.font, value: newFont, range: NSRange(location: 0, length: storage.length))
        }
        tv.autoResize()
        needsDisplay = true
    }

    // MARK: - mouse

    /// Replace the base image (used when the user resizes the selection — the cropped
    /// area changes, so the flatten path needs the new pixels for copy/save/OCR).
    func replaceBaseImage(_ image: CGImage) {
        baseImage = image
        needsDisplay = true
    }

    /// Translate every annotation by (dx, dy). Called after the editor window moves
    /// so committed annotations stay at the same SCREEN position rather than the
    /// same view-local position.
    func translateAllAnnotations(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        for i in 0..<annotations.count {
            annotations[i] = annotations[i].translated(dx: dx, dy: dy)
        }
        if let tv = activeTextView {
            var f = tv.frame
            f.origin.x += dx
            f.origin.y += dy
            tv.frame = f
        }
        needsDisplay = true
    }

    /// The visible selection rectangle inside the editor view's bounds (which extends
    /// `halo` pt past it on each side).
    private var selectionInsetRect: NSRect {
        bounds.insetBy(dx: Self.halo, dy: Self.halo)
    }

    /// Clamp a point to the visible selection so drawing tools can't stray into the
    /// invisible halo area (mouseDragged keeps sending events outside the visible box).
    private func clampToSelection(_ p: NSPoint) -> NSPoint {
        let r = selectionInsetRect
        return NSPoint(x: max(r.minX, min(p.x, r.maxX)),
                       y: max(r.minY, min(p.y, r.maxY)))
    }

    /// Generous corner-first hit test. Corners use a 20pt Euclidean radius (the
    /// closest corner wins if multiple match). Edge midpoints fall back to 12pt.
    /// Anchored on the SELECTION corners, not the editor's outer bounds — the editor
    /// extends `halo` pt outside the selection so clicks `halo` pt past a corner
    /// still register.
    private func hitTestResizeHandle(at p: NSPoint) -> ResizeHandle? {
        let r = selectionInsetRect
        let cornerR: CGFloat = 20
        let edgeR:   CGFloat = 12

        let corners: [(ResizeHandle, NSPoint)] = [
            (.topLeft,     NSPoint(x: r.minX, y: r.maxY)),
            (.topRight,    NSPoint(x: r.maxX, y: r.maxY)),
            (.bottomLeft,  NSPoint(x: r.minX, y: r.minY)),
            (.bottomRight, NSPoint(x: r.maxX, y: r.minY)),
        ]
        var best: (ResizeHandle, CGFloat)?
        for (h, pt) in corners {
            let d = hypot(p.x - pt.x, p.y - pt.y)
            if d <= cornerR && (best == nil || d < best!.1) {
                best = (h, d)
            }
        }
        if let (h, _) = best { return h }

        let edges: [(ResizeHandle, NSPoint)] = [
            (.top,    NSPoint(x: r.midX, y: r.maxY)),
            (.bottom, NSPoint(x: r.midX, y: r.minY)),
            (.left,   NSPoint(x: r.minX, y: r.midY)),
            (.right,  NSPoint(x: r.maxX, y: r.midY)),
        ]
        for (h, pt) in edges {
            if hypot(p.x - pt.x, p.y - pt.y) <= edgeR { return h }
        }
        return nil
    }

    /// Apply a delta (dx, dy in screen coords) to the anchored window frame based on
    /// which handle is being dragged.
    private func newFrameForResize(_ handle: ResizeHandle, dx: CGFloat, dy: CGFloat) -> NSRect {
        var f = anchorWindowFrame
        switch handle {
        case .topLeft:    f.origin.x += dx;                  f.size.width  -= dx; f.size.height += dy
        case .top:                                                                f.size.height += dy
        case .topRight:                                      f.size.width  += dx; f.size.height += dy
        case .left:       f.origin.x += dx;                  f.size.width  -= dx
        case .right:                                         f.size.width  += dx
        case .bottomLeft: f.origin.x += dx; f.origin.y += dy; f.size.width -= dx; f.size.height -= dy
        case .bottom:                       f.origin.y += dy;                     f.size.height -= dy
        case .bottomRight:                  f.origin.y += dy; f.size.width += dx; f.size.height -= dy
        }
        // Don't allow flipping or sub-minimum sizes. min visible selection = 30pt,
        // plus halo on both sides = 30 + 2*halo.
        let minSide: CGFloat = 30 + 2 * Self.halo
        if f.size.width  < minSide { f.size.width  = minSide }
        if f.size.height < minSide { f.size.height = minSide }
        return NSRect(x: f.origin.x.rounded(),
                      y: f.origin.y.rounded(),
                      width: f.size.width.rounded(),
                      height: f.size.height.rounded())
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Resize-handle hit takes priority — works in any tool mode so users can grab
        // a corner without first switching tools.
        if let handle = hitTestResizeHandle(at: p) {
            commitActiveTextField()
            draggingHandle = handle
            anchorWindowFrame = window?.frame ?? .zero
            anchorMouseScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
            return
        }
        // Clicks in the halo (outside the visible selection) and not on a handle: ignore.
        // Prevents drawing/typing in the "invisible padding" area where the user is just
        // approaching a corner but missed it.
        if !selectionInsetRect.contains(p) { return }

        // Any click commits the in-flight text field first.
        commitActiveTextField()

        // Select mode: double-click text → re-edit; single-click hit → select + drag;
        // click empty → deselect. Re-edit is ONLY available in select mode (was previously
        // also in text mode — moved here per request).
        if tool == .select {
            if event.clickCount >= 2, let idx = hitTestTextAnnotation(at: p) {
                if case .text(let str, let frame, let color, let font) = annotations[idx] {
                    annotations.remove(at: idx)
                    selectedAnnotationIndex = nil
                    redoStack.removeAll()
                    reEditTextField(at: frame.insetBy(dx: -4, dy: -4),
                                    prefill: str, color: color, font: font)
                    needsDisplay = true
                }
                return
            }
            if let idx = hitTestAnyAnnotation(at: p) {
                selectedAnnotationIndex = idx
                draggingAnnotationIndex = idx
                dragLastPoint = p
                NSCursor.closedHand.push()
                needsDisplay = true
                return
            }
            // Empty area in select mode → start dragging the whole selection box.
            selectedAnnotationIndex = nil
            draggingSelection = true
            anchorWindowFrame = window?.frame ?? .zero
            anchorMouseScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
            NSCursor.closedHand.push()
            needsDisplay = true
            return
        }

        // In any drawing/text tool, never auto-select existing annotations — clicks always
        // create new content. Use the select tool to move/delete.
        switch tool {
        case .select:
            break  // handled above
        case .line:
            lineDragStart = p; liveLineEnd = p
        case .freehand:
            liveStrokePoints = [p]
        case .rectangle:
            rectDragStart = p
            liveRect = NSRect(origin: p, size: .zero)
        case .text:
            // Double-click on a committed text annotation → reopen it for editing.
            // (Single click still drops a new input.)
            if event.clickCount >= 2, let idx = hitTestTextAnnotation(at: p),
               case .text(let str, let frame, let color, let font) = annotations[idx] {
                annotations.remove(at: idx)
                selectedAnnotationIndex = nil
                redoStack.removeAll()
                reEditTextField(at: frame.insetBy(dx: -4, dy: -4),
                                prefill: str, color: color, font: font)
                needsDisplay = true
            } else {
                dropTextField(at: p)
            }
        case .mosaic:
            mosaicDragStart = p
            liveMosaicRect = NSRect(origin: p, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Resize drag — annotations stay at SCREEN positions while the box reshapes.
        if let handle = draggingHandle, let win = window {
            let mouseScreen = win.convertPoint(toScreen: event.locationInWindow)
            let dx = mouseScreen.x - anchorMouseScreen.x
            let dy = mouseScreen.y - anchorMouseScreen.y
            let newFrame = newFrameForResize(handle, dx: dx, dy: dy)
            applyNewWindowFrame(newFrame, keepAnnotationsAtScreenPositions: true)
            return
        }
        // Whole-box move — annotations travel with the box (stay at LOCAL positions).
        if draggingSelection, let win = window {
            let mouseScreen = win.convertPoint(toScreen: event.locationInWindow)
            let dx = mouseScreen.x - anchorMouseScreen.x
            let dy = mouseScreen.y - anchorMouseScreen.y
            var f = anchorWindowFrame
            f.origin.x += dx
            f.origin.y += dy
            applyNewWindowFrame(f, keepAnnotationsAtScreenPositions: false)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        // Dragging an annotation takes priority over tool-specific drag gestures.
        if let idx = draggingAnnotationIndex, idx < annotations.count {
            let dx = p.x - dragLastPoint.x
            let dy = p.y - dragLastPoint.y
            annotations[idx] = annotations[idx].translated(dx: dx, dy: dy)
            dragLastPoint = p
            needsDisplay = true
            return
        }
        let pc = clampToSelection(p)
        switch tool {
        case .line where lineDragStart != nil:
            liveLineEnd = pc; needsDisplay = true
        case .freehand where !liveStrokePoints.isEmpty:
            liveStrokePoints.append(pc); needsDisplay = true
        case .mosaic where mosaicDragStart != nil:
            let s = mosaicDragStart!
            liveMosaicRect = NSRect(x: min(s.x, pc.x), y: min(s.y, pc.y),
                                    width: abs(pc.x - s.x), height: abs(pc.y - s.y))
            needsDisplay = true
        case .rectangle where rectDragStart != nil:
            let s = rectDragStart!
            liveRect = NSRect(x: min(s.x, pc.x), y: min(s.y, pc.y),
                              width: abs(pc.x - s.x), height: abs(pc.y - s.y))
            needsDisplay = true
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Resize finished — fire the "ended" callback so the controller can re-crop.
        if draggingHandle != nil {
            draggingHandle = nil
            if let frame = window?.frame {
                let h = Self.halo
                onResizeEnded?(frame.insetBy(dx: h, dy: h))
            }
            return
        }
        // Selection-box move finished — same end-of-resize path (re-crop new region).
        if draggingSelection {
            draggingSelection = false
            NSCursor.pop()
            if let frame = window?.frame {
                let h = Self.halo
                onResizeEnded?(frame.insetBy(dx: h, dy: h))
            }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if draggingAnnotationIndex != nil {
            draggingAnnotationIndex = nil
            NSCursor.pop()
            return
        }
        let pc = clampToSelection(p)
        switch tool {
        case .select:
            break
        case .line:
            if let s = lineDragStart, hypot(pc.x - s.x, pc.y - s.y) >= 2 {
                pushAnnotation(.line(from: s, to: pc, color: strokeColor, width: strokeWidth))
            }
            lineDragStart = nil; liveLineEnd = nil
        case .freehand:
            if liveStrokePoints.count >= 2 {
                pushAnnotation(.stroke(points: liveStrokePoints, color: strokeColor, width: strokeWidth))
            }
            liveStrokePoints.removeAll()
        case .text:
            break
        case .mosaic:
            if let r = liveMosaicRect, r.width >= 5, r.height >= 5 {
                pushAnnotation(.mosaic(rect: r))
            }
            mosaicDragStart = nil
            liveMosaicRect = nil
        case .rectangle:
            if let r = liveRect, r.width >= 4, r.height >= 4 {
                pushAnnotation(.rectangle(rect: r, color: strokeColor,
                                          width: strokeWidth, cornerRadius: 6))
            }
            rectDragStart = nil
            liveRect = nil
        }
        needsDisplay = true
    }

    private func drawResizeHandles(in ctx: CGContext) {
        let r = selectionInsetRect   // visible selection corners, not the outer halo
        let s: CGFloat = 8
        let pts: [NSPoint] = [
            NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
            NSPoint(x: r.minX, y: r.midY),                                NSPoint(x: r.maxX, y: r.midY),
            NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
        ]
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        for p in pts {
            let h = NSRect(x: p.x - s/2, y: p.y - s/2, width: s, height: s)
            ctx.fill(h)
            ctx.stroke(h)
        }
        ctx.restoreGState()
    }

    /// Resize/move the editor window to `newFrame` (screen coords).
    ///
    /// `keepAnnotationsAtScreenPositions`:
    /// - **true** (resize handles): annotations stay glued to the same SCREEN pixels —
    ///   their local coords shift by `-Δ` so a line you drew on a button stays on that
    ///   button as the box grows/shrinks around it.
    /// - **false** (whole-box move): annotations stay at the same LOCAL position inside
    ///   the box — they travel with the box. A circle drawn in the middle stays in the
    ///   middle of the moved box.
    private func applyNewWindowFrame(_ newFrame: NSRect,
                                     keepAnnotationsAtScreenPositions: Bool) {
        guard let win = window else { return }
        let oldFrame = win.frame
        let dx = newFrame.minX - oldFrame.minX
        let dy = newFrame.minY - oldFrame.minY

        win.setFrame(newFrame, display: true)
        if keepAnnotationsAtScreenPositions {
            translateAllAnnotations(dx: -dx, dy: -dy)
        }

        // The window is halo-padded, but downstream (toolbar position, overlay re-freeze,
        // re-crop) wants the VISIBLE selection rect. Strip the halo before forwarding.
        let h = Self.halo
        onResize?(newFrame.insetBy(dx: h, dy: h))
    }

    /// Returns the index of the topmost text annotation containing `p`, or nil.
    private func hitTestTextAnnotation(at p: NSPoint) -> Int? {
        for i in (0..<annotations.count).reversed() {
            if let r = annotations[i].textBoundingRect(), r.insetBy(dx: -4, dy: -4).contains(p) {
                return i
            }
        }
        return nil
    }

    /// Returns the index of the topmost annotation (any type) hit by `p`, or nil.
    /// Tolerance is generous (8pt) for thin strokes so the user doesn't have to be pixel-perfect.
    private func hitTestAnyAnnotation(at p: NSPoint) -> Int? {
        for i in (0..<annotations.count).reversed() {
            if annotations[i].containsPoint(p, tolerance: 8) { return i }
        }
        return nil
    }

    private func pushAnnotation(_ a: Annotation) {
        annotations.append(a)
        redoStack.removeAll()  // any new edit invalidates the redo stack
    }

    // MARK: - text

    private func dropTextField(at p: NSPoint,
                               prefill: String = "",
                               color: NSColor? = nil,
                               font: NSFont? = nil) {
        let useFont = font ?? .systemFont(ofSize: 18, weight: .medium)
        let useColor = color ?? strokeColor
        let initialH = ceil(useFont.pointSize * 1.6) + 8
        let initialW: CGFloat = 220
        let tv = LiveTextView.make(frame: NSRect(x: p.x, y: p.y - initialH/2,
                                                  width: initialW, height: initialH))
        tv.font = useFont
        tv.textColor = useColor
        // Typing attributes govern the formatting of characters typed AFTER this point.
        // Without setting them, NSTextView reverts to system defaults on typed text.
        tv.typingAttributes = [
            .font: useFont,
            .foregroundColor: useColor
        ]
        tv.string = prefill
        tv.commitCallback = { [weak self] in self?.commitActiveTextField() }
        tv.delegate = self
        addSubview(tv)
        activeTextView = tv
        installHandleHint(for: tv)
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self = self, let tv = tv else { return }
            self.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        }
        tv.autoResize()
    }

    private func installHandleHint(for tv: LiveTextView) {
        let hint = HandleHintView(cursor: LiveTextView.cornerResizeCursor)
        addSubview(hint, positioned: .above, relativeTo: tv)
        inputHandleHint = hint
        repositionInputHandleHint()
        NotificationCenter.default.addObserver(
            self, selector: #selector(textViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: tv
        )
    }

    @objc private func textViewFrameDidChange(_ note: Notification) {
        repositionInputHandleHint()
    }

    private func repositionInputHandleHint() {
        guard let hint = inputHandleHint, let tv = activeTextView else { return }
        let pt: CGFloat = 18
        hint.frame = NSRect(x: tv.frame.maxX - pt,
                            y: tv.frame.minY,
                            width: pt, height: pt)
    }

    private func removeHandleHint(for tv: LiveTextView?) {
        if let tv = tv {
            NotificationCenter.default.removeObserver(
                self, name: NSView.frameDidChangeNotification, object: tv
            )
        }
        inputHandleHint?.removeFromSuperview()
        inputHandleHint = nil
    }

    /// Restore a text input field at a specific frame (used for double-click re-edit so
    /// the field appears exactly where the committed annotation was, not offset).
    private func reEditTextField(at frame: NSRect, prefill: String, color: NSColor, font: NSFont) {
        let tv = LiveTextView.make(frame: frame)
        tv.font = font
        tv.textColor = color
        tv.typingAttributes = [.font: font, .foregroundColor: color]
        tv.string = prefill
        tv.commitCallback = { [weak self] in self?.commitActiveTextField() }
        tv.delegate = self
        addSubview(tv)
        activeTextView = tv
        installHandleHint(for: tv)
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self = self, let tv = tv else { return }
            self.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        }
        tv.autoResize()
    }

    private func commitActiveTextField() {
        guard let tv = activeTextView else { return }
        tv.autoResize()
        if !tv.string.isEmpty {
            let inset: CGFloat = 4
            let frame = tv.frame.insetBy(dx: inset, dy: inset)
            pushAnnotation(.text(string: tv.string,
                                  frame: frame,
                                  color: tv.textColor ?? strokeColor,
                                  font: tv.font ?? .systemFont(ofSize: 18, weight: .medium)))
        }
        removeHandleHint(for: tv)
        tv.removeFromSuperview()
        activeTextView = nil
        needsDisplay = true
    }

    // MARK: - draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 1) Near-zero-alpha fill so AppKit routes clicks to this view.
        ctx.setFillColor(NSColor(white: 0, alpha: 0.005).cgColor)
        ctx.fill(bounds)

        // 2) Annotations + live previews — clipped to the visible selection so they
        //    can never bleed into the invisible halo padding.
        ctx.saveGState()
        ctx.clip(to: selectionInsetRect)
        for a in annotations {
            a.draw(in: ctx, baseImage: baseImage, selRect: selectionInsetRect)
        }
        if let s = lineDragStart, let e = liveLineEnd {
            Annotation.line(from: s, to: e, color: strokeColor, width: strokeWidth).draw(in: ctx)
        }
        if liveStrokePoints.count >= 2 {
            Annotation.stroke(points: liveStrokePoints, color: strokeColor, width: strokeWidth).draw(in: ctx)
        }
        if let r = liveMosaicRect, r.width > 0, r.height > 0 {
            Annotation.mosaic(rect: r).draw(in: ctx, baseImage: baseImage, selRect: selectionInsetRect)
        }
        if let r = liveRect, r.width > 0, r.height > 0 {
            Annotation.rectangle(rect: r, color: strokeColor, width: strokeWidth,
                                 cornerRadius: 6).draw(in: ctx)
        }
        ctx.restoreGState()

        // 3) Resize handles at the selection corners + edge midpoints (NOT clipped —
        //    handles sit on the selection border).
        drawResizeHandles(in: ctx)

        // 4) Selection highlight (dashed blue outline around the chosen annotation's bbox).
        if let idx = selectedAnnotationIndex, idx < annotations.count {
            let bbox = annotations[idx].boundingRect().insetBy(dx: -4, dy: -4)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(bbox)
            ctx.restoreGState()
        }
    }

    func flattenedCGImage() -> CGImage? {
        commitActiveTextField()
        let scale: CGFloat = 2
        // Output is the VISIBLE selection only (no halo) — even though our bounds
        // include the halo for hit-test reach. The baseImage was cropped at the
        // visible-selection size and corresponds 1:1 with selectionInsetRect.
        let sel = selectionInsetRect
        let w = Int(sel.width * scale)
        let h = Int(sel.height * scale)
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Shift so the selection's origin maps to (0,0) in the output bitmap.
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        // baseImage's natural size matches the selection rect, so draw it there.
        ctx.draw(baseImage, in: sel)
        for a in annotations { a.draw(in: ctx, baseImage: baseImage, selRect: sel) }
        return ctx.makeImage()
    }
}

extension EditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        // Resizing the text view's frame from inside the textDidChange callback re-enters
        // NSTextKit while it's mid-update and crashes. Defer to the next runloop tick.
        guard let tv = notification.object as? LiveTextView else { return }
        DispatchQueue.main.async { [weak tv] in tv?.autoResize() }
    }
}

/// NSTextView subclass that:
/// - Auto-resizes its frame to fit content (so multi-line text grows the input box).
/// - Treats Return as "commit" and Shift+Return as "insert newline" (NSTextField can't do
///   newlines at all, hence the switch from NSTextField to NSTextView).
/// - Treats Escape as "commit" too (so empty Esc just dismisses).
final class LiveTextView: NSTextView {
    var commitCallback: (() -> Void)?

    /// Build the full TextKit-1 network (storage → layoutManager → container) explicitly
    /// and inject it into NSTextView. Passing `nil` to init(frame:textContainer:) is
    /// supposed to auto-build this, but on macOS 26 the auto-built network sometimes
    /// renders no glyphs / no caret. Constructing it manually is reliable.
    static func make(frame: NSRect) -> LiveTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frame.width,
                                                     height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        return LiveTextView(frame: frame, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 4
        // Make the border obviously colored so the input area is easy to spot against
        // the screenshot underneath.
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 4
        backgroundColor = NSColor.white.withAlphaComponent(0.85)
        drawsBackground = true
        isRichText = false
        isFieldEditor = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        isHorizontallyResizable = false
        // We manage frame manually (autoResize for content-fit, user-drag for explicit
        // resize). With this true, NSTextView fights us by snapping the frame back to
        // hugging the current text — which is why drag-DOWN reverted instantly.
        isVerticallyResizable = false
        insertionPointColor = .systemBlue
        textContainerInset = NSSize(width: 4, height: 4)
        autoresizingMask = []
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        postsFrameChangedNotifications = true
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - user-resize by dragging the bottom-right corner

    /// Set to true once the user explicitly drags to resize. Subsequent autoResize calls
    /// only GROW the box (never shrink, never change width) so the user's preferred size
    /// is preserved while they keep typing.
    private(set) var userResized: Bool = false
    private var resizing: Bool = false
    private var resizeAnchorFrame: NSRect = .zero
    private var resizeAnchorMouseScreen: NSPoint = .zero
    private let resizeHandlePt: CGFloat = 18

    /// Bottom-right corner area where mousedown starts a resize drag.
    /// NSTextView is **flipped** (y=0 is the top) so the bottom-right corner is at
    /// `(bounds.maxX, bounds.maxY)`, not `(bounds.maxX, bounds.minY)`.
    private var resizeHandleRect: NSRect {
        NSRect(x: bounds.maxX - resizeHandlePt,
               y: bounds.maxY - resizeHandlePt,
               width: resizeHandlePt, height: resizeHandlePt)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if resizeHandleRect.contains(p) {
            resizing = true
            resizeAnchorFrame = frame
            resizeAnchorMouseScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if resizing, let win = window {
            let mouse = win.convertPoint(toScreen: event.locationInWindow)
            let dx = mouse.x - resizeAnchorMouseScreen.x
            let dy = mouse.y - resizeAnchorMouseScreen.y
            // Y-up: dragging mouse DOWN means screen y decreases (dy negative). The handle
            // is at the BOTTOM-right; dragging down should grow the box downward = origin.y
            // moves down (decreases) and height grows (-dy).
            var f = resizeAnchorFrame
            f.size.width  = max(80, resizeAnchorFrame.size.width + dx)
            let newH      = max(28, resizeAnchorFrame.size.height - dy)
            f.origin.y    = resizeAnchorFrame.origin.y + (resizeAnchorFrame.size.height - newH)
            f.size.height = newH
            self.frame = f
            textContainer?.size = NSSize(
                width: max(20, f.size.width - textContainerInset.width * 2),
                height: .greatestFiniteMagnitude
            )
            userResized = true
            needsDisplay = true
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing { resizing = false; return }
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()                  // iBeam over text area
        addCursorRect(resizeHandleRect, cursor: Self.cornerResizeCursor)
    }

    /// NSTextView routes cursor changes through `cursorUpdate(with:)` (driven by its
    /// tracking areas) rather than honoring our small cursor-rect — so we have to
    /// intercept here too, otherwise the I-beam wins everywhere even over our handle.
    override func cursorUpdate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if resizeHandleRect.contains(p) {
            Self.cornerResizeCursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // The cursor-change hint subview is owned by EditorView (the textview's superview),
    // not by us. NSTextView mishandles non-text subviews (treats them like inline
    // attachments and lays them in weird places), so placing the hint as a sibling in
    // the unflipped EditorView is the only reliable path.

    /// macOS 15 added a proper diagonal frame-resize cursor; on older macOS we fall
    /// back to resizeUpDown (the closest built-in).
    static let cornerResizeCursor: NSCursor = {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        } else {
            return .resizeUpDown
        }
    }()

    /// Draw a small diagonal-stripes glyph in the bottom-right corner so the user sees
    /// the resize affordance.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = resizeHandleRect
        ctx.saveGState()
        // Filled triangle in the bottom-right corner (flipped coords: maxY is the bottom).
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.move(to:    NSPoint(x: r.maxX, y: r.maxY))    // bottom-right corner of view
        ctx.addLine(to: NSPoint(x: r.maxX, y: r.minY))    // up along right edge
        ctx.addLine(to: NSPoint(x: r.minX, y: r.maxY))    // diagonal back to bottom-left of handle
        ctx.closePath()
        ctx.fillPath()
        // White diagonal stripes in the corner (matches macOS resize affordance).
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        for i in 0..<3 {
            let off = CGFloat(i) * 4 + 4
            ctx.move(to:    NSPoint(x: r.maxX - 2,   y: r.maxY - off))
            ctx.addLine(to: NSPoint(x: r.maxX - off, y: r.maxY - 2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return, 53 = Escape
        if event.keyCode == 36 {
            // ⌘Return commits (explicit "I'm done"); plain Return / Shift+Return both
            // insert a newline so typing multi-line text feels normal.
            if event.modifierFlags.contains(.command) {
                commitCallback?()
                return
            }
            // Fall through to NSTextView's default, which inserts \n via insertNewline:.
        }
        if event.keyCode == 53 {
            // Esc commits.
            commitCallback?()
            return
        }
        super.keyDown(with: event)
    }

    func autoResize() {
        guard let lm = self.layoutManager, let tc = self.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let inset = textContainerInset
        let neededH = max(28, ceil(used.height) + inset.height*2 + 4)
        let neededW = max(120, ceil(used.width)  + inset.width*2  + 8)

        var f = frame
        if userResized {
            // Honor the user-chosen size — only grow vertically if content overflows,
            // never shrink, never touch width.
            if neededH > f.size.height + 0.5 {
                f.origin.y -= (neededH - f.size.height)
                f.size.height = neededH
                self.frame = f
            }
            return
        }
        if abs(f.size.height - neededH) > 0.5 || abs(f.size.width - neededW) > 0.5 {
            f.origin.y -= (neededH - f.size.height)
            f.size.height = neededH
            f.size.width  = neededW
            tc.size = NSSize(width: neededW - inset.width*2, height: .greatestFiniteMagnitude)
            self.frame = f
        }
    }
}

enum Annotation {
    case line(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat)
    case stroke(points: [NSPoint], color: NSColor, width: CGFloat)
    case text(string: String, frame: NSRect, color: NSColor, font: NSFont)
    /// Redact a rectangular region by pixelating the underlying screenshot pixels.
    case mosaic(rect: NSRect)
    /// Rounded-corner rectangle outline (stroke, no fill).
    case rectangle(rect: NSRect, color: NSColor, width: CGFloat, cornerRadius: CGFloat)

    /// Hit-test rectangle for text annotations (nil for non-text). Padded slightly so
    /// click targets are forgiving.
    func textBoundingRect() -> NSRect? {
        guard case .text(_, let frame, _, _) = self else { return nil }
        return frame
    }

    /// Bounding rect for any annotation type (used for selection highlight).
    func boundingRect() -> NSRect {
        switch self {
        case .line(let a, let b, _, _):
            return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .stroke(let pts, _, _):
            guard let first = pts.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts {
                if p.x < minX { minX = p.x }; if p.x > maxX { maxX = p.x }
                if p.y < minY { minY = p.y }; if p.y > maxY { maxY = p.y }
            }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(_, let frame, _, _):
            return frame
        case .mosaic(let rect):
            return rect
        case .rectangle(let rect, _, _, _):
            return rect
        }
    }

    /// Hit-test for click selection. Lines/strokes use point-to-segment distance with the
    /// given tolerance so thin strokes are still selectable; text uses the bounding rect.
    func containsPoint(_ p: NSPoint, tolerance: CGFloat) -> Bool {
        switch self {
        case .line(let a, let b, _, _):
            return Annotation.distance(from: p, toSegment: a, b) <= tolerance
        case .stroke(let pts, _, _):
            guard pts.count >= 2 else { return false }
            for i in 0..<(pts.count - 1) {
                if Annotation.distance(from: p, toSegment: pts[i], pts[i+1]) <= tolerance {
                    return true
                }
            }
            return false
        case .text(_, let frame, _, _):
            return frame.insetBy(dx: -4, dy: -4).contains(p)
        case .mosaic(let rect):
            return rect.contains(p)
        case .rectangle(let rect, _, _, _):
            // Hit if click is on the border (within tolerance). Inside-but-far-from-border
            // doesn't select — that area belongs to the underlying screenshot.
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx:  tolerance, dy:  tolerance)
            return outer.contains(p) && !inner.contains(p)
        }
    }

    /// Replace the annotation's color (preserves geometry + width/font).
    func withColor(_ color: NSColor) -> Annotation {
        switch self {
        case .line(let a, let b, _, let w):
            return .line(from: a, to: b, color: color, width: w)
        case .stroke(let pts, _, let w):
            return .stroke(points: pts, color: color, width: w)
        case .text(let s, let f, _, let font):
            return .text(string: s, frame: f, color: color, font: font)
        case .mosaic:
            return self   // mosaic has no color
        case .rectangle(let rect, _, let w, let cr):
            return .rectangle(rect: rect, color: color, width: w, cornerRadius: cr)
        }
    }

    /// Replace the stroke width (line/stroke/rectangle — text + mosaic are unchanged).
    func withWidth(_ width: CGFloat) -> Annotation {
        switch self {
        case .line(let a, let b, let c, _):
            return .line(from: a, to: b, color: c, width: width)
        case .stroke(let pts, let c, _):
            return .stroke(points: pts, color: c, width: width)
        case .rectangle(let rect, let c, _, let cr):
            return .rectangle(rect: rect, color: c, width: width, cornerRadius: cr)
        case .text, .mosaic:
            return self
        }
    }

    /// Translate by (dx, dy). Returns a new annotation case with shifted coordinates.
    func translated(dx: CGFloat, dy: CGFloat) -> Annotation {
        switch self {
        case .line(let a, let b, let color, let width):
            return .line(from: NSPoint(x: a.x + dx, y: a.y + dy),
                         to:   NSPoint(x: b.x + dx, y: b.y + dy),
                         color: color, width: width)
        case .stroke(let pts, let color, let width):
            return .stroke(points: pts.map { NSPoint(x: $0.x + dx, y: $0.y + dy) },
                           color: color, width: width)
        case .text(let str, let frame, let color, let font):
            return .text(string: str,
                         frame: NSRect(x: frame.minX + dx, y: frame.minY + dy,
                                       width: frame.width, height: frame.height),
                         color: color, font: font)
        case .mosaic(let rect):
            return .mosaic(rect: NSRect(x: rect.minX + dx, y: rect.minY + dy,
                                        width: rect.width, height: rect.height))
        case .rectangle(let rect, let c, let w, let cr):
            return .rectangle(
                rect: NSRect(x: rect.minX + dx, y: rect.minY + dy,
                             width: rect.width, height: rect.height),
                color: c, width: w, cornerRadius: cr
            )
        }
    }

    /// Distance from point `p` to the line segment a–b.
    private static func distance(from p: NSPoint, toSegment a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx*dx + dy*dy
        if lenSq < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let cx = a.x + t * dx, cy = a.y + t * dy
        return hypot(p.x - cx, p.y - cy)
    }

    /// `baseImage` + `selRect` are required only for `.mosaic` (it pixelates the screenshot
    /// pixels in its rect); other annotations ignore them.
    func draw(in ctx: CGContext, baseImage: CGImage? = nil, selRect: NSRect? = nil) {
        switch self {
        case .line(let a, let b, let color, let width):
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.strokePath()
            ctx.restoreGState()
        case .stroke(let pts, let color, let width):
            guard pts.count >= 2 else { return }
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            ctx.restoreGState()
        case .text(let str, let frame, let color, let font):
            // Draw with word wrapping so the rendered annotation has the SAME number of
            // visual lines as the input box did. NSStringDrawing's .usesLineFragmentOrigin
            // does proper wrapping at `frame.width`, but it needs a flipped (top-down)
            // graphics context — so we momentarily flip CG around the rect's vertical
            // midpoint, then restore.
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: para
            ]
            let ns = NSAttributedString(string: str, attributes: attrs)
            ctx.saveGState()
            NSGraphicsContext.saveGraphicsState()
            ctx.translateBy(x: 0, y: frame.maxY + frame.minY)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            ns.draw(with: frame, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        case .mosaic(let rect):
            Annotation.renderMosaic(rect: rect, in: ctx,
                                     baseImage: baseImage, selRect: selRect)
        case .rectangle(let rect, let color, let width, let cr):
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            // Inset the path by half the line width so the stroke doesn't clip the rect's
            // outer edge; clamp corner radius so it doesn't exceed the shorter side / 2.
            let inset = width / 2
            let strokeRect = rect.insetBy(dx: inset, dy: inset)
            let maxR = min(strokeRect.width, strokeRect.height) / 2
            let radius = max(0, min(cr, maxR))
            let path = CGPath(roundedRect: strokeRect,
                              cornerWidth: radius, cornerHeight: radius,
                              transform: nil)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Pixelate the screenshot pixels that fall within `rect`. The trick is to draw
    /// the relevant slice of `baseImage` into a tiny CGContext (averaging colors),
    /// then draw the small image back out at the original size with nearest-neighbor
    /// interpolation — that produces chunky blocks.
    private static func renderMosaic(rect: NSRect,
                                      in ctx: CGContext,
                                      baseImage: CGImage?,
                                      selRect: NSRect?) {
        guard let baseImage = baseImage, let selRect = selRect,
              rect.width > 0, rect.height > 0 else { return }
        // Map editor-local rect → pixel rect inside baseImage (baseImage is at native
        // retina resolution; selRect is in points and matches baseImage's natural size).
        let scaleX = CGFloat(baseImage.width)  / selRect.width
        let scaleY = CGFloat(baseImage.height) / selRect.height
        let pixelRect = CGRect(
            x: (rect.minX - selRect.minX) * scaleX,
            y: (selRect.maxY - rect.maxY) * scaleY,    // Y-flipped because CGImage is top-down
            width:  rect.width  * scaleX,
            height: rect.height * scaleY
        ).integral
        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = baseImage.cropping(to: pixelRect) else { return }

        // ~10pt blocks. Each cell in the small bitmap = one chunky block on screen.
        let cellSize: CGFloat = 10
        let cellsX = max(1, Int(rect.width  / cellSize))
        let cellsY = max(1, Int(rect.height / cellSize))

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let small = CGContext(data: nil, width: cellsX, height: cellsY,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .medium   // averaging while downsampling
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: cellsX, height: cellsY))
        guard let smallImg = small.makeImage() else { return }

        ctx.saveGState()
        ctx.interpolationQuality = .none      // upscale → chunky blocks
        ctx.draw(smallImg, in: rect)
        ctx.restoreGState()
    }
}

/// A tiny standalone NSView used as a corner cursor-hint. Its own bounds are unflipped
/// 18×18, so its tracking area / cursor rects use plain XY — no flipped-coordinate
/// surprises. Click pass-through (hitTest = nil) lets the parent LiveTextView keep
/// handling the actual resize-drag via its own mouseDown.
final class HandleHintView: NSView {
    private let cursor: NSCursor
    private var trackArea: NSTrackingArea?

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
        wantsLayer = true
        // TEMP: tint the hint translucent so we can visually confirm where it lands.
        // Once cursor + drag are verified working, remove this fill.
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved,
                      .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        addTrackingArea(ta)
        trackArea = ta
        // The mouseMoved option is only meaningful if the window accepts mouse-moved
        // events; opt in lazily here so callers don't have to remember.
        window?.acceptsMouseMovedEvents = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent)  { NSCursor.iBeam.set() }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    // Force-reassert on every mouseMoved so NSTextView's I-beam can't win the race.
    override func mouseMoved(with event: NSEvent)   { cursor.set() }

    /// Click pass-through to the LiveTextView underneath (which owns the resize-drag).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
