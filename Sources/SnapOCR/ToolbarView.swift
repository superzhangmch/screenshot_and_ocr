import AppKit

enum ToolbarTool { case select, line, freehand, text, mosaic, ocrLocal, ocrLLM, undo, redo, copy, close }

protocol ToolbarViewDelegate: AnyObject {
    func toolbar(_ tb: ToolbarView, didSelect tool: ToolbarTool)
    func toolbar(_ tb: ToolbarView, didPickColor color: NSColor)
    func toolbar(_ tb: ToolbarView, didPickWidth width: CGFloat)
}

final class ToolbarView: NSView {
    weak var delegate: ToolbarViewDelegate?

    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white
    ]
    static let widthPresets: [CGFloat] = [1, 2, 3, 5, 8]
    private(set) var currentColor: NSColor = .systemRed
    private(set) var currentWidth: CGFloat = 2

    private struct Item { let symbol: String; let label: String; let tool: ToolbarTool }
    private let items: [Item] = [
        Item(symbol: "cursorarrow",           label: "Select / Move (Del to remove)", tool: .select),
        Item(symbol: "line.diagonal",         label: "Line",     tool: .line),
        Item(symbol: "scribble.variable",     label: "Pencil",   tool: .freehand),
        Item(symbol: "textformat",            label: "Text",     tool: .text),
        Item(symbol: "square.grid.3x3.fill",  label: "Mosaic (redact)", tool: .mosaic),
        Item(symbol: "text.viewfinder",       label: "OCR (Local · Apple Vision · fast)", tool: .ocrLocal),
        Item(symbol: "sparkles",              label: "OCR (LLM · slower, better on hard cases)", tool: .ocrLLM),
        Item(symbol: "arrow.uturn.backward",  label: "Undo (⌘Z)",tool: .undo),
        Item(symbol: "arrow.uturn.forward",   label: "Redo (⌘⇧Z)",tool: .redo),
        Item(symbol: "doc.on.clipboard",      label: "Copy",     tool: .copy),
        Item(symbol: "xmark.circle",          label: "Close",    tool: .close),
    ]

    private var colorWell: ColorSwatchButton!
    private var widthWell: WidthSwatchButton!
    private var toolButtons: [NSButton] = []

    private let buttonW: CGFloat = 36
    private let swatchW: CGFloat = 28        // narrower lane for color + width swatches
    private let pad: CGFloat = 8
    private let sepW: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        // 2 swatches + separator + N tool buttons
        let toolsW = CGFloat(items.count) * buttonW
        return NSSize(width: pad*2 + swatchW*2 + sepW + toolsW, height: 36)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor

        // Color circle — smaller (20pt) and centered in its lane.
        let circleD: CGFloat = 20
        colorWell = ColorSwatchButton(color: currentColor)
        colorWell.frame = NSRect(x: pad + (swatchW - circleD)/2, y: (36 - circleD)/2,
                                  width: circleD, height: circleD)
        colorWell.target = self
        colorWell.action = #selector(showPalette(_:))
        addSubview(colorWell)

        // Stroke-width swatch — small badge that visually shows the current line thickness.
        widthWell = WidthSwatchButton(width: currentWidth)
        widthWell.frame = NSRect(x: pad + swatchW, y: 4, width: swatchW, height: 28)
        widthWell.target = self
        widthWell.action = #selector(showWidthPicker(_:))
        addSubview(widthWell)

        let sep = NSView(frame: NSRect(x: pad + swatchW*2 + 2, y: 8, width: 1, height: 20))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(sep)

        let toolsStartX = pad + swatchW*2 + sepW
        for (i, item) in items.enumerated() {
            let b = NSButton(frame: NSRect(x: toolsStartX + CGFloat(i)*buttonW, y: 4, width: buttonW, height: 28))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.label)
            b.contentTintColor = .white
            b.toolTip = item.label
            b.tag = i
            b.target = self
            b.action = #selector(tap(_:))
            addSubview(b)
            toolButtons.append(b)
        }
        // Visually mark "freehand" (pencil) as the default active tool.
        highlight(tool: .freehand)
    }
    required init?(coder: NSCoder) { fatalError() }

    func highlight(tool: ToolbarTool) {
        for (i, item) in items.enumerated() {
            let active = (item.tool == tool)
            toolButtons[i].contentTintColor = active ? NSColor.systemBlue : .white
        }
    }

    @objc private func tap(_ sender: NSButton) {
        let tool = items[sender.tag].tool
        if tool == .select || tool == .line || tool == .freehand || tool == .text || tool == .mosaic {
            highlight(tool: tool)
        }
        delegate?.toolbar(self, didSelect: tool)
    }

    @objc private func showPalette(_ sender: NSButton) {
        let popover = NSPopover()
        let pv = PaletteView(colors: Self.palette, selected: currentColor) { [weak self, weak popover] color in
            guard let self = self else { return }
            self.currentColor = color
            self.colorWell.setColor(color)
            self.delegate?.toolbar(self, didPickColor: color)
            popover?.close()
        }
        popover.contentSize = pv.intrinsicContentSize
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = pv
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func showWidthPicker(_ sender: NSButton) {
        let popover = NSPopover()
        let pv = WidthPickerView(widths: Self.widthPresets, selected: currentWidth) { [weak self, weak popover] w in
            guard let self = self else { return }
            self.currentWidth = w
            self.widthWell.setWidth(w)
            self.delegate?.toolbar(self, didPickWidth: w)
            popover?.close()
        }
        popover.contentSize = pv.intrinsicContentSize
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = pv
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

/// Small button: shows the current stroke thickness as a horizontal bar inside a rounded chip.
final class WidthSwatchButton: NSButton {
    private var width: CGFloat
    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func setWidth(_ w: CGFloat) { width = w; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle chip background
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        let chip = bounds.insetBy(dx: 3, dy: 4)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        // Horizontal stroke representing current width
        let lineY = bounds.midY
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(min(width, 8))
        ctx.move(to: NSPoint(x: bounds.minX + 8, y: lineY))
        ctx.addLine(to: NSPoint(x: bounds.maxX - 8, y: lineY))
        ctx.strokePath()
    }
}

/// Vertical popover showing each preset width as a row.
final class WidthPickerView: NSView {
    private let widths: [CGFloat]
    private let onPick: (CGFloat) -> Void
    private let rowH: CGFloat = 26
    private let rowW: CGFloat = 140
    private let pad: CGFloat = 6

    override var intrinsicContentSize: NSSize {
        NSSize(width: rowW + pad*2, height: CGFloat(widths.count)*rowH + pad*2)
    }

    init(widths: [CGFloat], selected: CGFloat, onPick: @escaping (CGFloat) -> Void) {
        self.widths = widths
        self.onPick = onPick
        super.init(frame: .zero)
        for (i, w) in widths.enumerated() {
            let b = WidthRowButton(width: w, isSelected: w == selected)
            b.frame = NSRect(x: pad, y: pad + CGFloat(widths.count - 1 - i)*rowH, width: rowW, height: rowH)
            b.tag = i
            b.target = self
            b.action = #selector(pick(_:))
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ sender: NSButton) {
        onPick(widths[sender.tag])
    }
}

private final class WidthRowButton: NSButton {
    private let width: CGFloat
    private let isSel: Bool
    init(width: CGFloat, isSelected: Bool) {
        self.width = width
        self.isSel = isSelected
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isSel {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
            ctx.fill(bounds.insetBy(dx: 2, dy: 2))
        }
        // Stroke sample
        let y = bounds.midY
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)
        ctx.move(to: NSPoint(x: 16, y: y))
        ctx.addLine(to: NSPoint(x: bounds.width - 44, y: y))
        ctx.strokePath()
        // Label
        let label = "\(Int(width)) pt"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        s.draw(at: NSPoint(x: bounds.width - 36, y: y - s.size().height/2))
    }
}

final class ColorSwatchButton: NSButton {
    private var color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    func setColor(_ c: NSColor) {
        color = c
        layer?.backgroundColor = c.cgColor
    }
}

final class PaletteView: NSView {
    private let colors: [NSColor]
    private let onPick: (NSColor) -> Void
    private let cell: CGFloat = 26
    private let pad: CGFloat = 8

    override var intrinsicContentSize: NSSize {
        let cols = 4
        let rows = (colors.count + cols - 1) / cols
        return NSSize(width: CGFloat(cols)*cell + pad*2 + CGFloat(cols-1)*4,
                      height: CGFloat(rows)*cell + pad*2 + CGFloat(rows-1)*4)
    }

    init(colors: [NSColor], selected: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.colors = colors
        self.onPick = onPick
        super.init(frame: .zero)
        let cols = 4
        for (i, c) in colors.enumerated() {
            let row = i / cols
            let col = i % cols
            let b = NSButton(frame: NSRect(
                x: pad + CGFloat(col)*(cell+4),
                y: pad + CGFloat(row)*(cell+4),
                width: cell, height: cell))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.title = ""
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.layer?.backgroundColor = c.cgColor
            if c.isEqual(selected) {
                b.layer?.borderWidth = 2
                b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else {
                b.layer?.borderWidth = 1
                b.layer?.borderColor = NSColor.gridColor.cgColor
            }
            b.tag = i
            b.target = self
            b.action = #selector(pick(_:))
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ sender: NSButton) {
        onPick(colors[sender.tag])
    }
}
