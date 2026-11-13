import Foundation

struct AppSettings: Codable {
    var appearanceMode: String = "auto"
    var aspectMode: String = "fit"
    var enhanceMode: String = "auto_sd"
    var sidebarCollapsed: Bool = false
    var theaterMode: Bool = false
}

final class StorageStore {
    private let appDataDir: URL
    private let settingsFile: URL
    private let favoritesFile: URL
    private let bootstrapFile: URL

    private(set) var settings: AppSettings

    init(appDataDir: URL) {
        self.appDataDir = appDataDir
        self.settingsFile = appDataDir.appendingPathComponent("settings.json")
        self.favoritesFile = appDataDir.appendingPathComponent("favorites.json")
        self.bootstrapFile = appDataDir.appendingPathComponent("bootstrap_v1.json")

        if let data = try? Data(contentsOf: settingsFile),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    var appearanceEnum: YacineAppearanceMode {
        YacineAppearanceMode(rawValue: settings.appearanceMode) ?? .auto
    }

    func updateSettings(fromJsonDict dict: [String: Any]) {
        if let v = dict["appearanceMode"] as? String {
            settings.appearanceMode = v
        }
        if let v = dict["aspectMode"] as? String {
            settings.aspectMode = v
        }
        if let v = dict["enhanceMode"] as? String {
            settings.enhanceMode = v
        }
        if let v = dict["sidebarCollapsed"] as? Bool {
            settings.sidebarCollapsed = v
        }
        if let v = dict["theaterMode"] as? Bool {
            settings.theaterMode = v
        }
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }

    func settingsJsonString() -> String {
        guard let data = try? JSONEncoder().encode(settings),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    func loadFavoritesJson() -> String {
        guard let data = try? Data(contentsOf: favoritesFile),
              let str = String(data: data, encoding: .utf8),
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "[]"
        }
        return str
    }

    func saveFavoritesJson(_ json: String) {
        try? Data(json.utf8).write(to: favoritesFile, options: .atomic)
    }

    func loadBootstrapJson() -> String {
        guard let data = try? Data(contentsOf: bootstrapFile),
              let str = String(data: data, encoding: .utf8),
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "null"
        }
        return str
    }

    func saveBootstrapJson(_ json: String) {
        try? Data(json.utf8).write(to: bootstrapFile, options: .atomic)
    }
}
