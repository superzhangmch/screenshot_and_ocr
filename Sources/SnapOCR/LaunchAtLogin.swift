import AppKit
import ServiceManagement

enum LaunchAtLogin {
    static func install() {
        if #available(macOS 13.0, *) {
            do { try SMAppService.mainApp.register() }
            catch {
                NSLog("SMAppService.register failed: \(error)")
                fallbackLaunchAgent()
            }
        } else {
            fallbackLaunchAgent()
        }
    }

    private static func fallbackLaunchAgent() {
        let fm = FileManager.default
        let agents = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try? fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("com.snapocr.agent.plist")
        let exec = Bundle.main.executablePath ?? CommandLine.arguments[0]

        let plist: [String: Any] = [
            "Label": "com.snapocr.agent",
            "ProgramArguments": [exec],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/tmp/snapocr.out.log",
            "StandardErrorPath": "/tmp/snapocr.err.log"
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["load", "-w", plistURL.path]
        try? task.run()
    }
}
