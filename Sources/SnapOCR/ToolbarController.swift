import AppKit
import Darwin   // for malloc_zone_pressure_relief

final class ToolbarController: NSObject {
    private static var current: ToolbarController?

    static func present(for result: SelectionResult,
                        onClose: @escaping () -> Void,
                        onSelectionResize: @escaping (NSRect) -> Void = { _ in },
                        recropOnResize: @escaping (NSRect) -> CGImage? = { _ in nil }) {
        let c = ToolbarController(result: result, onClose: onClose,
                                  onSelectionResize: onSelectionResize,
                                  recropOnResize: recropOnResize)
        current = c
        c.show()
    }

    private var result: SelectionResult     // mutable so we can update it after a resize
    private let onClose: () -> Void
    private let onSelectionResize: (NSRect) -> Void
    private let recropOnResize: (NSRect) -> CGImage?
    private var imageWindow: NSWindow!
    private var toolbarWindow: NSWindow!
    private var editorView: EditorView!
    private var toolbarView: ToolbarView!
    private var ocrPopup: NSWindow?
    private var localKeyMonitor: Any?

    private init(result: SelectionResult,
                 onClose: @escaping () -> Void,
                 onSelectionResize: @escaping (NSRect) -> Void,
                 recropOnResize: @escaping (NSRect) -> CGImage?) {
        self.result = result
        self.onClose = onClose
        self.onSelectionResize = onSelectionResize
        self.recropOnResize = recropOnResize
    }

    private func show() {
        // Sit ABOVE the frozen overlay (which is at .screenSaver) so the editor + toolbar
        // are interactive while the gray dim + border stay visible behind them.
        let aboveOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

        // The visible selection is `result.globalRect`. The editor window is sized
        // `selection + halo` so users can grab resize handles slightly outside the
        // visible corner. EditorView handles the inset accounting internally.
        let h = EditorView.halo
        let selection = result.globalRect
        let frame = selection.insetBy(dx: -h, dy: -h)
        imageWindow = EditorWindow(contentRect: frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        // Window must be non-opaque + clear-bg for the overlay underneath to show through —
        // EditorView only paints annotations now, the screenshot pixels come from the overlay.
        imageWindow.isOpaque = false
        imageWindow.backgroundColor = .clear
        imageWindow.level = aboveOverlay
        imageWindow.hasShadow = false
        imageWindow.isMovable = false  // belt-and-suspenders: never let AppKit drag us
        imageWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]

        editorView = EditorView(image: result.image, frame: NSRect(origin: .zero, size: frame.size))
        imageWindow.contentView = editorView
        imageWindow.setFrame(frame, display: false)
        imageWindow.makeKeyAndOrderFront(nil)

        // Live resize: editor moves/sizes its own window and translates annotations;
        // we just shadow the change in the overlay (frozen-rect display) and toolbar position.
        editorView.onResize = { [weak self] newFrame in
            guard let self = self else { return }
            self.repositionToolbar(below: newFrame)
            self.onSelectionResize(newFrame)
            self.result = SelectionResult(image: self.result.image,
                                          globalRect: newFrame,
                                          screen: self.result.screen)
        }
        // Drag end: re-crop the snapshot for the new rect and replace the editor's base
        // image so copy/save/OCR see the new pixels.
        editorView.onResizeEnded = { [weak self] newFrame in
            guard let self = self else { return }
            if let cropped = self.recropOnResize(newFrame) {
                self.editorView.replaceBaseImage(cropped)
                self.result = SelectionResult(image: cropped,
                                              globalRect: newFrame,
                                              screen: self.result.screen)
            }
        }

        toolbarView = ToolbarView()
        toolbarView.delegate = self
        // Position toolbar below the VISIBLE selection (not the halo-padded editor).
        let tbFrame = toolbarFrame(below: selection)
        toolbarWindow = NSWindow(contentRect: tbFrame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        toolbarWindow.isOpaque = false
        toolbarWindow.backgroundColor = .clear
        toolbarWindow.level = aboveOverlay
        toolbarWindow.hasShadow = true
        toolbarWindow.contentView = toolbarView
        toolbarWindow.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Local key monitor for editor-wide shortcuts:
        //   - Esc (no text field focused) → exit the tool
        //   - ⌘Z / ⌘⇧Z → undo / redo
        //   - ⌘+ / ⌘- → resize the active text field
        // Esc with focus inside a text view is left to LiveTextView (which commits + dismisses field).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Esc handling first — check before bailing on no-modifier events.
            if event.keyCode == 53 /* Escape */ {
                if !self.editorView.hasActiveTextField {
                    // Defer to next runloop tick: dismiss() removes the local key monitor,
                    // and removing a monitor from inside its own callback frees memory the
                    // monitor's caller is still using → EXC_BAD_ACCESS.
                    DispatchQueue.main.async { [weak self] in self?.dismiss() }
                    return nil
                }
                // If a text view is focused, let it consume Esc (commits the field).
                return event
            }

            // Delete / Forward Delete (when not typing) → remove the selected annotation.
            if !self.editorView.hasActiveTextField,
               event.keyCode == 51 /* Delete */ || event.keyCode == 117 /* Fwd Delete */ {
                if self.editorView.deleteSelectedAnnotation() { return nil }
            }

            guard event.modifierFlags.contains(.command) else { return event }
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            switch chars {
            case "z":
                if event.modifierFlags.contains(.shift) { self.editorView.redo() }
                else                                    { self.editorView.undo() }
                return nil
            case "+", "=":
                if self.editorView.hasActiveTextField {
                    self.editorView.adjustActiveTextSize(by: +2)
                    return nil
                }
            case "-":
                if self.editorView.hasActiveTextField {
                    self.editorView.adjustActiveTextSize(by: -2)
                    return nil
                }
            default: break
            }
            return event
        }
    }

    private func toolbarFrame(below selection: NSRect) -> NSRect {
        let tbHeight: CGFloat = 36
        let tbWidth = toolbarView?.intrinsicContentSize.width ?? 360
        let scr = result.screen.frame
        // Default: BELOW the selection (selection.minY is the bottom edge in Y-up).
        var f = NSRect(x: selection.minX,
                       y: selection.minY - tbHeight - 6,
                       width: tbWidth, height: tbHeight)
        // If that would clip the bottom of the screen, place it ABOVE the selection.
        if f.minY < scr.minY + 4 {
            f.origin.y = selection.maxY + 6
        }
        // If "above" would also clip the top (rare — near-fullheight selection),
        // fall back to inside the selection at the bottom edge.
        if f.maxY > scr.maxY - 4 {
            f.origin.y = selection.minY + 6
        }
        return f
    }

    private func repositionToolbar(below selection: NSRect) {
        guard let win = toolbarWindow else { return }
        win.setFrame(toolbarFrame(below: selection), display: true)
    }

    fileprivate func dismiss() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        // Tear down windows + break contentView refs so AppKit / ARC can reclaim
        // the editor's CGImage, NSTextView layout managers, etc. promptly.
        imageWindow?.orderOut(nil); imageWindow?.contentView = nil; imageWindow = nil
        toolbarWindow?.orderOut(nil); toolbarWindow?.contentView = nil; toolbarWindow = nil
        ocrPopup?.orderOut(nil); ocrPopup?.contentView = nil; ocrPopup = nil
        editorView = nil
        toolbarView = nil
        ToolbarController.current = nil
        onClose()
        // Hint to malloc to actually return free pages to the OS instead of caching them
        // forever. This is what makes RSS shrink between captures (private memory was
        // already stable; this just makes the visible "RSS climbing" trend stop).
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }
}

/// Custom NSWindow so the borderless editor accepts key events (needed for the ⌘Z monitor
/// + first-responder text fields).
private final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension ToolbarController: ToolbarViewDelegate {
    func toolbar(_ tb: ToolbarView, didSelect tool: ToolbarTool) {
        switch tool {
        case .select:   editorView.tool = .select
        case .line:     editorView.tool = .line
        case .freehand: editorView.tool = .freehand
        case .text:     editorView.tool = .text
        case .mosaic:   editorView.tool = .mosaic
        case .undo:     editorView.undo()
        case .redo:     editorView.redo()
        case .ocrLocal: runLocalOCR()
        case .ocrLLM:   runOCR()
        case .copy:     copyEditedImage()
        case .save:     saveEditedImage()
        case .close:    dismiss()
        }
    }

    func toolbar(_ tb: ToolbarView, didPickColor color: NSColor) {
        editorView.strokeColor = color
        // Recolor only applies to the selected annotation in select mode (per request).
        // Active-text recolor was removed: while typing, color picks no longer change the
        // input box. Commit, switch to select, click the annotation, then change color.
        editorView.applyColorToSelected(color)
    }

    func toolbar(_ tb: ToolbarView, didPickWidth width: CGFloat) {
        editorView.strokeWidth = width
        editorView.applyWidthToSelected(width)
    }
}

extension ToolbarController {
    private func copyEditedImage() {
        guard let img = editorView.flattenedCGImage() else { return }
        ClipboardService.copy(image: img)
        // Per request: Copy → copy + immediately dismiss everything (editor, toolbar, frozen overlay).
        // No HUD needed; the disappearance itself signals success.
        dismiss()
    }

    private func saveEditedImage() {
        guard let img = editorView.flattenedCGImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "snapocr-\(stamp).png"
        if panel.runModal() == .OK, let url = panel.url {
            let rep = NSBitmapImageRep(cgImage: img)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
        }
    }

    /// On-device OCR via Apple Vision. Synchronous-ish (runs on a background queue,
    /// no network), usually 50-200ms. Lighter than LLM-OCR for normal text.
    private func runLocalOCR() {
        guard let img = editorView.flattenedCGImage() else { return }
        if let prev = ocrPopup {
            prev.orderOut(nil)
            prev.contentView = nil
        }
        let popup = makeOCRPopup(initialText: "Running local OCR…")
        ocrPopup = popup
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            do {
                let text = try VisionOCRService.recognize(image: img)
                result = text.isEmpty ? "(No text detected)" : text
            } catch {
                result = "OCR failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.ocrPopup === popup else { return }
                self.updateOCRPopup(popup, text: result)
            }
        }
    }

    private func runOCR() {
        guard let img = editorView.flattenedCGImage() else { return }
        // If a previous OCR popup is still around (user clicked OCR twice), tear it
        // down first — otherwise the old NSWindow stays in the app's window list,
        // pinning its NSTextView + scroll view in memory.
        if let prev = ocrPopup {
            prev.orderOut(nil)
            prev.contentView = nil
        }
        let popup = makeOCRPopup(initialText: "Running LLM OCR…")
        ocrPopup = popup
        Task { @MainActor in
            var accum = ""
            do {
                var first = true
                for try await chunk in OCRService.recognize(image: img) {
                    if first { accum = ""; first = false }   // clear "Running OCR…" on first byte
                    accum += chunk
                    self.updateOCRPopup(popup, text: accum)
                }
                if accum.isEmpty {
                    self.updateOCRPopup(popup, text: "(No text detected)")
                }
            } catch {
                self.updateOCRPopup(popup, text: "OCR failed: \(error.localizedDescription)")
            }
        }
    }

    private func makeOCRPopup(initialText: String) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        // Default for programmatic NSWindows is isReleasedWhenClosed=true → clicking the
        // window's [X] frees the NSWindow, leaving our `ocrPopup` reference dangling.
        // Disable it so close just hides the window; our reference stays valid.
        win.isReleasedWhenClosed = false
        win.title = "OCR Result"
        // Sit ABOVE the editor + overlay (which are at .screenSaver and .screenSaver+1).
        // Using .floating (3) put it underneath, which is why the popup wasn't appearing.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 460, height: 280))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        // Non-editable so a single click on a .link range opens the URL instead of
        // moving the caret. User can still select text and use the Copy button.
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.font = .systemFont(ofSize: 13)
        // Make .link ranges open in default browser on click.
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        tv.string = initialText
        tv.autoresizingMask = [.width]
        scroll.documentView = tv

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyOCRText(_:)))
        copyBtn.frame = NSRect(x: 260, y: 8, width: 90, height: 28)
        copyBtn.bezelStyle = .rounded
        objc_setAssociatedObject(copyBtn, &OCRPopupKey.tv, tv, .OBJC_ASSOCIATION_RETAIN)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeOCRPopup(_:)))
        closeBtn.frame = NSRect(x: 360, y: 8, width: 90, height: 28)
        closeBtn.bezelStyle = .rounded

        let container = NSView(frame: win.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        container.addSubview(copyBtn)
        container.addSubview(closeBtn)
        win.contentView = container

        let sel = result.globalRect
        var origin = NSPoint(x: sel.maxX + 12, y: sel.midY - 160)
        let scr = result.screen.frame
        if origin.x + 460 > scr.maxX { origin.x = sel.minX - 472 }
        if origin.x < scr.minX + 8 { origin.x = scr.minX + 8 }
        win.setFrameOrigin(origin)
        win.makeKeyAndOrderFront(nil)
        return win
    }

    private func updateOCRPopup(_ win: NSWindow, text: String) {
        guard let scroll = win.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let tv = scroll.documentView as? NSTextView else { return }
        // Build an attributed string with .link attributes on any detected URLs so
        // they render underlined and are clickable (NSTextView opens .link via NSWorkspace).
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.textColor
        ]
        let s = NSMutableAttributedString(string: text, attributes: attrs)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let full = NSRange(location: 0, length: (text as NSString).length)
            detector.enumerateMatches(in: text, range: full) { m, _, _ in
                if let m = m, let url = m.url {
                    s.addAttribute(.link, value: url, range: m.range)
                }
            }
        }
        tv.textStorage?.setAttributedString(s)
    }

    @objc private func closeOCRPopup(_ sender: NSButton) {
        if let win = sender.window {
            win.orderOut(nil)
            win.contentView = nil
            if ocrPopup === win { ocrPopup = nil }
        }
    }

    @objc private func copyOCRText(_ sender: NSButton) {
        if let tv = objc_getAssociatedObject(sender, &OCRPopupKey.tv) as? NSTextView {
            ClipboardService.copy(text: tv.string)
            flashHUD("Text copied")
        }
        // Close the popup after copying (per request: don't leave a window hanging
        // around once the user's grabbed the text they wanted).
        if let win = sender.window {
            win.orderOut(nil)
            win.contentView = nil
            if ocrPopup === win { ocrPopup = nil }
        }
    }

    private func flashHUD(_ msg: String) {
        let hud = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 36),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        let v = NSView(frame: hud.contentView!.bounds)
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        let lbl = NSTextField(labelWithString: msg)
        lbl.textColor = .white
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.frame.origin = NSPoint(x: 18, y: 8)
        lbl.sizeToFit()
        v.addSubview(lbl)
        hud.contentView = v

        let sel = result.globalRect
        hud.setFrameOrigin(NSPoint(x: sel.midX - 80, y: sel.maxY + 12))
        hud.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { hud.orderOut(nil) }
    }
}

private enum OCRPopupKey { static var tv: UInt8 = 0 }
