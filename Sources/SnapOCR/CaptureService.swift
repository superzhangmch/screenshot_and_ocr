import AppKit
import CoreGraphics
import ScreenCaptureKit

struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
    let frame: NSRect
}

enum CaptureService {
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func captureAllScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var results: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = scDisplay.width * 2
            cfg.height = scDisplay.height * 2
            cfg.showsCursor = false
            cfg.capturesAudio = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            results.append(ScreenSnapshot(screen: screen, image: img, frame: screen.frame))
        }
        return results
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
