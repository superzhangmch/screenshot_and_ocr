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
        // Vertical: if BELOW would clip the bottom of the screen, place ABOVE the
        // selection. If "above" also clips the top, fall back to inside.
        if f.minY < scr.minY + 4 { f.origin.y = selection.maxY + 6 }
        if f.maxY > scr.maxY - 4 { f.origin.y = selection.minY + 6 }
        // Horizontal: if the toolbar would extend past the right edge of the screen
        // (selection is near the right side and toolbar is wider than the remaining
        // space), shift it leftward so all buttons stay visible. Then clamp to the
        // left edge for the extreme narrow-screen case.
        if f.maxX > scr.maxX - 4 { f.origin.x = scr.maxX - 4 - tbWidth }
        if f.origin.x < scr.minX + 4 { f.origin.x = scr.minX + 4 }
        return f
    }

    private func repositionToolbar(below selection: NSRect) {
        guard let win = toolbarWindow else { return }
        win.setFrame(toolbarFrame(below: selection), display: true)
    }

    fileprivate func dismiss() {
        dismiss(keepingPopup: false)
    }

    /// Tear down the capture session. If `keepingPopup` is true, the OCR/explainer popup
    /// is left alive (held by `Self.standalonePopup`) so a deferred LLM call can still
    /// stream into it after the editor / overlay are gone.
    fileprivate func dismiss(keepingPopup: Bool) {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        imageWindow?.orderOut(nil); imageWindow?.contentView = nil; imageWindow = nil
        toolbarWindow?.orderOut(nil); toolbarWindow?.contentView = nil; toolbarWindow = nil
        if !keepingPopup {
            ocrPopup?.orderOut(nil); ocrPopup?.contentView = nil; ocrPopup = nil
        } else if let popup = ocrPopup {
            // Hand the popup over to a static slot so it survives the controller dying.
            if let prev = Self.standalonePopup {
                objc_setAssociatedObject(prev, &Self.controllerOwnerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                prev.orderOut(nil); prev.contentView = nil
            }
            Self.standalonePopup = popup
            // Pin self alive on the popup so its button targets stay valid until close.
            objc_setAssociatedObject(popup, &Self.controllerOwnerKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            ocrPopup = nil
        }
        editorView = nil
        toolbarView = nil
        ToolbarController.current = nil
        onClose()
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }

    /// Holds an OCR/explainer popup that should outlive its ToolbarController (e.g.
    /// "Explain English" tears down the capture session immediately but keeps the
    /// streaming result window on screen). Cleared when the user closes that popup.
    static var standalonePopup: NSWindow?
    /// Associated-object key — pins the controller alive on the standalone popup so
    /// the popup's button targets (which point at the controller) stay valid until
    /// the user closes the popup, even after the editor session has been torn down.
    private static var controllerOwnerKey: UInt8 = 0
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
        case .rectangle: editorView.tool = .rectangle
        case .text:     editorView.tool = .text
        case .mosaic:   editorView.tool = .mosaic
        case .undo:     editorView.undo()
        case .redo:     editorView.redo()
        case .ocrLocal: runLocalOCR()
        case .ocrLLM:   runOCR()
        case .englishExplain: runEnglishExplainer()
        case .copy:     copyEditedImage()
        case .close:    dismiss()
        }
    }

    func toolbar(_ tb: ToolbarView, didPickColor color: NSColor) {
        editorView.strokeColor = color
        editorView.applyColorToSelected(color)
        editorView.applyColorToActiveText(color)
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

    /// Explain difficult English in the captured region. Streams an LLM reply with
     /// uncommon vocab / idioms / unusual usages / overall sentence meaning, in Chinese.
     /// The capture session (editor + overlay) is torn down immediately — only the
     /// streaming popup remains on screen so the user can keep using whatever app
     /// they grabbed the text from.
    private func runEnglishExplainer() {
        guard let img = editorView.flattenedCGImage() else { return }
        if let prev = ocrPopup { prev.orderOut(nil); prev.contentView = nil }
        let popup = makeOCRPopup(initialText: "解读中…", explainerMode: true)
        popup.title = "English explainer"
        ocrPopup = popup

        let prompt = """
        请按以下顺序处理图中的英文:

        1. 先抄录出英文原文 (类似 OCR). 只抄录用户真正关心的英文正文; 忽略无关内容 (UI 文字、按钮、广告、水印等), 也忽略被截断的、半句的、上一段或下一段的残缺片段. 凡是没有完整呈现在图中的文字 (任意一边被裁掉、显示不全), 一律忽略.

        空一行.

        2. 中文翻译 (自然些, 忠于原文).

        空一行.

        3. 用大白话简要 restate 一下这段话其实在说啥 (通俗复述, 抓重点, 不长篇, 也不是再翻一遍).

        空一行.

        4. 如果有真正难懂的地方 —— 不常见的词 / idiom, 不寻常的语法或搭配, 常见词的不熟悉含义 —— 简明解读. 简单常见的不用讲. 没有难点就不写这一段, 不要硬凑.

        纯文本输出, 不要任何 Markdown 标记 (不要 #, *, **, `, -, 表格等). 用自然分段和换行表达结构. 不要序号小标题如 "1." "2." 也不要写"英文原文:" "翻译:" 这种 label. 直接按顺序给四块内容, 中间用空行分隔.
        """

        Task { @MainActor in
            var accum = ""
            do {
                var first = true
                for try await chunk in OCRService.recognize(image: img, prompt: prompt) {
                    if first { accum = ""; first = false }
                    accum += chunk
                    self.updateOCRPopup(popup, text: accum)
                }
                if accum.isEmpty { self.updateOCRPopup(popup, text: "(无内容)") }
            } catch {
                self.updateOCRPopup(popup, text: "解读失败: \(error.localizedDescription)")
            }
        }

        // Hand the popup off to the standalone slot and tear down editor + overlay.
        dismiss(keepingPopup: true)
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

    private func makeOCRPopup(initialText: String, explainerMode: Bool = false) -> NSWindow {
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

        let container = NSView(frame: win.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(scroll)

        if explainerMode {
            // Explainer popup: just one Exit button. No copy actions — the user is here
            // to read, not to capture text. Return AND Esc both close.
            let exitBtn = NSButton(title: "Exit", target: self,
                                    action: #selector(closeOCRPopup(_:)))
            exitBtn.frame = NSRect(x: 360, y: 8, width: 90, height: 28)
            exitBtn.bezelStyle = .rounded
            exitBtn.keyEquivalent = "\r"
            exitBtn.attributedTitle = NSAttributedString(
                string: "Exit",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.boldSystemFont(ofSize: 13)
                ]
            )
            container.addSubview(exitBtn)
        } else {
            // OCR popup: [ Copy ]  [ Copy & Exit ]  [ Close ]
            let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyOCRText(_:)))
            copyBtn.frame = NSRect(x: 150, y: 8, width: 90, height: 28)
            copyBtn.bezelStyle = .rounded
            objc_setAssociatedObject(copyBtn, &OCRPopupKey.tv, tv, .OBJC_ASSOCIATION_RETAIN)

            let copyExitBtn = NSButton(title: "Copy & Exit",
                                        target: self, action: #selector(copyOCRTextAndExit(_:)))
            copyExitBtn.frame = NSRect(x: 245, y: 8, width: 120, height: 28)
            copyExitBtn.bezelStyle = .rounded
            copyExitBtn.keyEquivalent = "\r"
            copyExitBtn.attributedTitle = NSAttributedString(
                string: "Copy & Exit",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.boldSystemFont(ofSize: 13)
                ]
            )
            objc_setAssociatedObject(copyExitBtn, &OCRPopupKey.tv, tv, .OBJC_ASSOCIATION_RETAIN)

            let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeOCRPopup(_:)))
            closeBtn.frame = NSRect(x: 370, y: 8, width: 80, height: 28)
            closeBtn.bezelStyle = .rounded
            closeBtn.keyEquivalent = "\u{1b}"

            container.addSubview(copyBtn)
            container.addSubview(copyExitBtn)
            container.addSubview(closeBtn)
        }
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

    @objc private func copyOCRTextAndExit(_ sender: NSButton) {
        if let tv = objc_getAssociatedObject(sender, &OCRPopupKey.tv) as? NSTextView {
            ClipboardService.copy(text: tv.string)
        }
        if let win = sender.window, ToolbarController.standalonePopup === win {
            // Editor + overlay are already gone (popup is in standalone mode); just close the popup.
            dismissPopupWindow(win)
        } else {
            dismiss()
        }
    }

    @objc private func closeOCRPopup(_ sender: NSButton) {
        if let win = sender.window { dismissPopupWindow(win) }
    }

    /// Close a popup window, clearing both `ocrPopup` and `standalonePopup` slots if
    /// either points at it, and release the associated controller-pinning object.
    private func dismissPopupWindow(_ win: NSWindow) {
        win.orderOut(nil)
        win.contentView = nil
        if ocrPopup === win { ocrPopup = nil }
        if ToolbarController.standalonePopup === win {
            objc_setAssociatedObject(win, &ToolbarController.controllerOwnerKey,
                                      nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            ToolbarController.standalonePopup = nil
        }
    }

    @objc private func copyOCRText(_ sender: NSButton) {
        if let tv = objc_getAssociatedObject(sender, &OCRPopupKey.tv) as? NSTextView {
            ClipboardService.copy(text: tv.string)
            flashHUD("Text copied")
        }
        if let win = sender.window { dismissPopupWindow(win) }
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
