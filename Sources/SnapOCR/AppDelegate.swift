import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // We're a hotkey-driven background app — usually with NO windows open. macOS
        // applies "automatic termination" to UIElement apps that have nothing visible
        // and reaps them to save resources. That's why the app silently disappeared
        // after launch when the menu bar icon was hidden. Opt out so the process stays
        // alive listening for ⌘⇧A.
        ProcessInfo.processInfo.disableAutomaticTermination("hotkey listener for screen capture")
        ProcessInfo.processInfo.disableSuddenTermination()

        // Menu bar icon is opt-in via config (default off). Without the icon, capture
        // is triggered by the global hotkey only; quit via `pkill SnapOCR` or System
        // Settings → Login Items; edit settings at ~/.config/snapocr/config.json.
        if Config.load().showMenuBarIcon {
            installMenuBarItem()
        }

        hotKey = GlobalHotKey(keyCode: 0x00 /* A */, modifiers: [.command, .shift]) { [weak self] in
            self?.triggerCapture()
        }
        _ = CaptureService.requestScreenRecordingPermission()
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SnapOCR")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture (⌘⇧A)", action: #selector(triggerCapture), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Install Login Item", action: #selector(installLoginItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func triggerCapture() {
        guard overlay == nil else { return }
        Task { @MainActor in
            do {
                let snapshots = try await CaptureService.captureAllScreens()
                let controller = OverlayController(snapshots: snapshots) { [weak self] result in
                    self?.overlay = nil
                    if let result = result { OverlayController.handleSelectionResult(result) }
                }
                self.overlay = controller
                controller.show()
            } catch {
                NSLog("Capture failed: \(error)")
            }
        }
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.configFileURL.path) {
            try? Config.writeDefault()
        }
        NSWorkspace.shared.open(Config.configFileURL)
    }

    @objc private func installLoginItem() {
        LaunchAtLogin.install()
        let alert = NSAlert()
        alert.messageText = "Login Item Installed"
        alert.informativeText = "SnapOCR will start automatically at login."
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
