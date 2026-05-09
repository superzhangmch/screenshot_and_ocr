import Foundation

struct Config: Codable {
    var apiBase: String
    var apiKey: String
    var ocrModel: String
    /// Show the ✂ icon in the system menu bar. Default false (hidden) — capture is
    /// triggered via the global hotkey ⌘⇧A. Set true in config.json to restore the icon.
    var showMenuBarIcon: Bool

    /// Default values are intentionally blank for the API endpoint / key / model so
    /// that nothing sensitive ships in the source. Real values live in
    /// `~/.config/snapocr/config.json` (see config.example.json) or are passed via
    /// SNAPOCR_API_BASE / SNAPOCR_API_KEY / SNAPOCR_MODEL environment variables.
    static let `default` = Config(
        apiBase: "",
        apiKey: "",
        ocrModel: "",
        showMenuBarIcon: false
    )

    enum CodingKeys: String, CodingKey {
        case apiBase, apiKey, ocrModel, showMenuBarIcon
    }

    init(apiBase: String, apiKey: String, ocrModel: String, showMenuBarIcon: Bool) {
        self.apiBase = apiBase
        self.apiKey = apiKey
        self.ocrModel = ocrModel
        self.showMenuBarIcon = showMenuBarIcon
    }

    /// Custom decoder that falls back to defaults for any missing key — lets us
    /// add new config fields without breaking existing config.json files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        self.apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase) ?? d.apiBase
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        self.ocrModel = try c.decodeIfPresent(String.self, forKey: .ocrModel) ?? d.ocrModel
        self.showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
    }

    static var configFileURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("snapocr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        var cfg = Config.default
        if let data = try? Data(contentsOf: configFileURL),
           let parsed = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = parsed
        }
        let env = ProcessInfo.processInfo.environment
        if let v = env["SNAPOCR_API_BASE"], !v.isEmpty { cfg.apiBase = v }
        if let v = env["SNAPOCR_API_KEY"],  !v.isEmpty { cfg.apiKey  = v }
        if let v = env["SNAPOCR_MODEL"],    !v.isEmpty { cfg.ocrModel = v }
        if let v = env["SNAPOCR_SHOW_MENU_BAR"] {
            cfg.showMenuBarIcon = (v == "1" || v.lowercased() == "true")
        }
        return cfg
    }

    static func writeDefault() throws {
        let url = configFileURL
        if FileManager.default.fileExists(atPath: url.path) { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Config.default).write(to: url)
    }
}
