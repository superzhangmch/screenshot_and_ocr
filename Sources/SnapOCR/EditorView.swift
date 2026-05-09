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
    enum Tool { case select, line, freehand, text }

    private(set) var baseImage: CGImage
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []

    private var lineDragStart: NSPoint?
    private var liveLineEnd: NSPoint?
    private var liveStrokePoints: [NSPoint] = []

    /// Currently selected annotation (highlighted with a dashed outline). Click an
    /// annotation to select; click empty space to deselect; press Delete to remove.
    private var selectedAnnotationIndex: Int?
    /// Dragging any annotation by its index. Set on mouseDown when a click hits an
    /// existing annotation; cleared on mouseUp.
    private var draggingAnnotationIndex: Int?
    private var dragLastPoint: NSPoint = .zero

    /// Active text view, if any. Auto-commits on next mouseDown / tool switch.
    private weak var activeTextView: LiveTextView?

    /// Active resize-handle drag (set on mouseDown over a handle, cleared on mouseUp).
    private var draggingHandle: ResizeHandle?
    private var anchorWindowFrame: NSRect = .zero
    private var anchorMouseScreen: NSPoint = .zero

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
    var strokeWidth: CGFloat = 1

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

    /// Generous corner-first hit test. The 4 corners get a 30pt Euclidean radius (the
    /// closest corner wins if multiple match — avoids ambiguity on small selections).
    /// The 4 edge midpoints fall back to a 14pt radius after corners miss.
    private func hitTestResizeHandle(at p: NSPoint) -> ResizeHandle? {
        let r = bounds
        let cornerR: CGFloat = 15
        let edgeR:   CGFloat = 10

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
        // Don't allow flipping or sub-minimum sizes.
        let minSide: CGFloat = 30
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
            } else {
                selectedAnnotationIndex = nil
            }
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
        case .text:
            dropTextField(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Resize drag — highest priority.
        if let handle = draggingHandle, let win = window {
            let mouseScreen = win.convertPoint(toScreen: event.locationInWindow)
            let dx = mouseScreen.x - anchorMouseScreen.x
            let dy = mouseScreen.y - anchorMouseScreen.y
            let newFrame = newFrameForResize(handle, dx: dx, dy: dy)
            applyNewWindowFrame(newFrame)
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
        switch tool {
        case .line where lineDragStart != nil:
            liveLineEnd = p; needsDisplay = true
        case .freehand where !liveStrokePoints.isEmpty:
            liveStrokePoints.append(p); needsDisplay = true
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Resize finished — fire the "ended" callback so the controller can re-crop.
        if draggingHandle != nil {
            draggingHandle = nil
            if let frame = window?.frame {
                onResizeEnded?(frame)
            }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if draggingAnnotationIndex != nil {
            draggingAnnotationIndex = nil
            NSCursor.pop()
            return
        }
        switch tool {
        case .select:
            break
        case .line:
            if let s = lineDragStart, hypot(p.x - s.x, p.y - s.y) >= 2 {
                pushAnnotation(.line(from: s, to: p, color: strokeColor, width: strokeWidth))
            }
            lineDragStart = nil; liveLineEnd = nil
        case .freehand:
            if liveStrokePoints.count >= 2 {
                pushAnnotation(.stroke(points: liveStrokePoints, color: strokeColor, width: strokeWidth))
            }
            liveStrokePoints.removeAll()
        case .text:
            break
        }
        needsDisplay = true
    }

    private func drawResizeHandles(in ctx: CGContext) {
        let r = bounds
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

    /// Resize the editor window to `newFrame` (screen coords) and translate annotations
    /// by the inverse origin delta so they stay glued to the same screen pixels.
    private func applyNewWindowFrame(_ newFrame: NSRect) {
        guard let win = window else { return }
        let oldFrame = win.frame
        let dx = newFrame.minX - oldFrame.minX
        let dy = newFrame.minY - oldFrame.minY

        win.setFrame(newFrame, display: true)
        // -dx, -dy because: editor moved by (dx, dy) in screen, so to keep annotations
        // at the same screen position their local coords must shift by (-dx, -dy).
        translateAllAnnotations(dx: -dx, dy: -dy)

        onResize?(newFrame)
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
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self = self, let tv = tv else { return }
            self.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        }
        tv.autoResize()
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
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self = self, let tv = tv else { return }
            self.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        }
        tv.autoResize()
    }

    private func commitActiveTextField() {
        guard let tv = activeTextView else { return }
        // Force a synchronous final resize so the stored frame matches what the user
        // actually saw (textDidChange's autoResize is deferred via DispatchQueue.async
        // to avoid a TextKit re-entrancy crash; on commit we want the latest layout).
        tv.autoResize()
        if !tv.string.isEmpty {
            let inset: CGFloat = 4
            let frame = tv.frame.insetBy(dx: inset, dy: inset)
            pushAnnotation(.text(string: tv.string,
                                  frame: frame,
                                  color: tv.textColor ?? strokeColor,
                                  font: tv.font ?? .systemFont(ofSize: 18, weight: .medium)))
        }
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

        // 2) Annotations only — the screenshot pixels come from the overlay underneath.
        for a in annotations { a.draw(in: ctx) }

        // 3) Resize handles at the editor bounds corners + edge midpoints. Visible while
        //    the editor is open so the user can grab them to resize the captured area.
        drawResizeHandles(in: ctx)

        // 3) Selection highlight (dashed blue outline around the chosen annotation's bbox).
        if let idx = selectedAnnotationIndex, idx < annotations.count {
            let bbox = annotations[idx].boundingRect().insetBy(dx: -4, dy: -4)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(bbox)
            ctx.restoreGState()
        }

        // 4) Live previews for the in-progress line/stroke.
        if let s = lineDragStart, let e = liveLineEnd {
            Annotation.line(from: s, to: e, color: strokeColor, width: strokeWidth).draw(in: ctx)
        }
        if liveStrokePoints.count >= 2 {
            Annotation.stroke(points: liveStrokePoints, color: strokeColor, width: strokeWidth).draw(in: ctx)
        }
    }

    func flattenedCGImage() -> CGImage? {
        commitActiveTextField()
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(baseImage, in: bounds)
        for a in annotations { a.draw(in: ctx) }
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
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        backgroundColor = NSColor.white.withAlphaComponent(0.85)
        drawsBackground = true
        isRichText = false
        isFieldEditor = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        insertionPointColor = .systemBlue
        textContainerInset = NSSize(width: 4, height: 4)
        autoresizingMask = []
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return, 53 = Escape
        if event.keyCode == 36 {
            if event.modifierFlags.contains(.shift) {
                // Shift+Return → newline
                self.insertText("\n", replacementRange: self.selectedRange())
            } else {
                commitCallback?()
            }
            return
        }
        if event.keyCode == 53 {
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
        let newH = max(28, ceil(used.height) + inset.height*2 + 4)
        let newW = max(120, ceil(used.width)  + inset.width*2  + 8)
        if abs(frame.size.height - newH) > 0.5 || abs(frame.size.width - newW) > 0.5 {
            var f = frame
            // Keep top-left fixed: when growing taller, drop bottom; when growing wider, extend right.
            f.origin.y -= (newH - f.size.height)
            f.size.height = newH
            f.size.width = newW
            // Update text container width to match new view width so wrapping uses the new width.
            tc.size = NSSize(width: newW - inset.width*2, height: .greatestFiniteMagnitude)
            self.frame = f
        }
    }
}

enum Annotation {
    case line(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat)
    case stroke(points: [NSPoint], color: NSColor, width: CGFloat)
    case text(string: String, frame: NSRect, color: NSColor, font: NSFont)

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
        }
    }

    /// Replace the stroke width (line/stroke only — text is unchanged).
    func withWidth(_ width: CGFloat) -> Annotation {
        switch self {
        case .line(let a, let b, let c, _):
            return .line(from: a, to: b, color: c, width: width)
        case .stroke(let pts, let c, _):
            return .stroke(points: pts, color: c, width: width)
        case .text:
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

    func draw(in ctx: CGContext) {
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
            // Draw line-by-line into the unflipped (Y-up) context. NSAttributedString.draw(at:)
            // places the BASELINE at the given y. Line layout matches NSTextView with the
            // default text container inset (4pt top): first baseline = frame.maxY - ascender,
            // subsequent baselines step down by font.lineHeight.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let lines = str.components(separatedBy: "\n")
            let lineH = font.ascender - font.descender + font.leading
            for (i, line) in lines.enumerated() {
                let lineStr = NSAttributedString(string: line, attributes: attrs)
                let baseline = frame.maxY - font.ascender - CGFloat(i) * lineH
                lineStr.draw(at: NSPoint(x: frame.minX, y: baseline))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
