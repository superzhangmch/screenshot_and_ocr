# SnapOCR

A tiny native macOS screenshot + annotate + LLM-OCR tool. Runs in the background,
triggered by ⌘⇧A.

(By AI, 个人自娱自乐使用的)

## What it does

1. **⌘⇧A** — screen freezes with a dim overlay
2. **Drag** to select a region (Xnip-style box with corner handles + size badge)
3. On release the cropped image is **already on the clipboard**, an editor opens on top of the selection
4. **Edit** the screenshot with: line, freehand pencil, multi-line text, color picker, line-width picker
5. **OCR** sends the image to an OpenAI-compatible vision chat-completions endpoint with `stream: true` — text fills in live
6. **Resize** the selection by dragging any corner — annotations stay glued to their original screen positions

## Building

Requires Xcode command line tools, Swift 5.9+, macOS 14+.

```bash
./build.sh                                # produces .build/SnapOCR.app
cp -R .build/SnapOCR.app /Applications/   # install
open /Applications/SnapOCR.app            # launch (will prompt for Screen Recording permission)
```

The app is unsigned (ad-hoc); macOS Gatekeeper will prompt the first launch. Right-click → Open if needed.

## Configuring OCR

OCR calls an OpenAI-format `/v1/chat/completions` endpoint with vision input. You provide the endpoint, key, and model name. Three ways to set them, in priority order:

1. **Environment variables** (highest priority):
   - `SNAPOCR_API_BASE` — your endpoint root (no trailing `/v1/...`)
   - `SNAPOCR_API_KEY` — bearer token
   - `SNAPOCR_MODEL`   — model identifier accepted by your endpoint

2. **Config file** at `~/.config/snapocr/config.json` — see [config.example.json](config.example.json).

3. Defaults are blank. With nothing set, OCR shows a helpful error.

Any endpoint that accepts the OpenAI vision format (`image_url` with a `data:image/png;base64,...` URL) works.

## Editor controls

- **Toolbar** (left to right): color · line width · select · line · pencil · text · OCR · undo · redo · copy · save · close
- **Active tool** is highlighted in blue
- **⌘Z / ⌘⇧Z** — undo / redo
- **⌘+ / ⌘-** — resize active text input
- **⏎** — commit text input; **Shift+⏎** — newline
- **Esc** — cancel (closes the editor when no text input focused; commits otherwise)
- **Select tool**: click annotation to select (dashed outline), drag to move, **Delete** to remove. Double-click text to re-edit
- **Resize selection**: grab any corner / edge midpoint — annotations stay at their original screen positions

## Auto-start at login

Once installed, register as a Login Item:

- Via System Settings: **General → Login Items & Extensions → Open at Login → +** SnapOCR
- Or programmatically: open the menu bar icon → "Install Login Item" (if you've enabled `showMenuBarIcon: true` in config)

## How to quit

If `showMenuBarIcon: false` (default), no UI is visible. To quit:

```bash
pkill SnapOCR
```

Or via Activity Monitor.

## Architecture notes

- **Native Swift**, no third-party deps. ~1200 LoC, ~300 KB binary.
- **ScreenCaptureKit** for capture, **Carbon HotKey API** for the global ⌘⇧A.
- The editor sits in a borderless window above the frozen overlay (`.screenSaver+1` level).
- Annotations are stored as enum cases (`line`, `stroke`, `text`); the screenshot pixels come from the overlay's punch-out hole rather than being re-drawn by the editor — eliminates the double-resampling flash.
- Streaming OCR via `URLSession.bytes(for:).lines` and SSE `data:` events.

## License

MIT.
