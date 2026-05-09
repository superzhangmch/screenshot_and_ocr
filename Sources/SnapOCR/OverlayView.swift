import AppKit

final class OverlayView: NSView {
    private let snapshot: ScreenSnapshot
    private var dragStart: NSPoint?
    private var currentRect: NSRect?
    /// When true, the view stops accepting drag input and just renders the dim + selected
    /// rect's border — used to keep the gray context visible while the editor is open.
    private var frozen: Bool = false

    var onSelectionFinished: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    /// Lock the current selection rectangle in place; ignore further mouse input.
    func freeze(at lockedRect: NSRect) {
        frozen = true
        currentRect = lockedRect
        dragStart = nil
        needsDisplay = true
    }

    private let dimAlpha: CGFloat = 0.45
    private let borderColor = NSColor.systemBlue
    private let borderWidth: CGFloat = 1.5

    init(snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard !frozen else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        currentRect = NSRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !frozen, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = rect(from: start, to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !frozen else { return }
        defer { dragStart = nil }
        guard let r = currentRect, r.width >= 4, r.height >= 4 else {
            currentRect = nil; needsDisplay = true; return
        }
        onSelectionFinished?(r)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(snapshot.image, in: bounds)

        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        if let sel = currentRect, sel.width > 0, sel.height > 0 {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(sel)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)

            ctx.setStrokeColor(borderColor.cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.stroke(sel.insetBy(dx: -borderWidth/2, dy: -borderWidth/2))

            // After freeze, the editor sits on top and draws its own handles (which are
            // also the click targets). Drawing them here too led to visually-overlapping
            // hit zones and a "sometimes works, sometimes doesn't" feel. Show our handles
            // only during the initial drag-to-select.
            if !frozen { drawHandles(in: ctx, around: sel) }

            let label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded())) pt"
            drawSizeBadge(label, anchorTop: NSPoint(x: sel.minX, y: sel.maxY))
        } else {
            ctx.fill(bounds)
        }
    }

    private func drawSizeBadge(_ text: String, anchorTop: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 6
        let bgW = size.width + pad*2
        let bgH = size.height + pad
        var y = anchorTop.y + 6
        if y + bgH > bounds.maxY - 2 { y = anchorTop.y - bgH - 6 }
        let bg = NSRect(x: anchorTop.x, y: y, width: bgW, height: bgH)
        borderColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: bg.minX + pad, y: bg.minY + pad/2))
    }

    private func drawHandles(in ctx: CGContext, around r: NSRect) {
        let s: CGFloat = 6
        let pts: [NSPoint] = [
            NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
            NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY),
            NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
        ]
        ctx.setFillColor(borderColor.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        for p in pts {
            let h = NSRect(x: p.x - s/2, y: p.y - s/2, width: s, height: s)
            ctx.fill(h); ctx.stroke(h)
        }
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
