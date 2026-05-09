import AppKit
import CoreGraphics

struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
    let frame: NSRect
}

/// Lightweight screen capture using `CGDisplayCreateImage`. Synchronous, no helper
/// daemon (vs ScreenCaptureKit which keeps `replayd` resident and adds ~60MB+).
/// The API is deprecated in macOS 14 but still functional and dramatically lighter.
enum CaptureService {
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func captureAllScreens() -> [ScreenSnapshot] {
        var results: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            // CGDisplayCreateImage returns a CGImage at the display's native pixel size.
            guard let img = CGDisplayCreateImage(displayID) else { continue }
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
