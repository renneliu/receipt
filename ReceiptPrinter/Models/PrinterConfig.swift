import Foundation

struct PrinterConfig: Codable, Equatable {
    var paperWidthMM: Int = 80
    var dotsPerLine: Int = 576
    var columnsPerLine: Int = 48
    var encoding: TextEncoding = .gbk
    var cutPaper: Bool = true
    var feedLinesBeforeCut: Int = 12

    static let default80mm = PrinterConfig()

    enum TextEncoding: String, Codable, CaseIterable, Identifiable {
        case utf8 = "UTF-8"
        case gbk = "GBK/CP936"

        var id: String { rawValue }
    }
}

struct AppSettings: Codable, Equatable {
    var selectedPrinterName: String?
    var printerConfig: PrinterConfig = .default80mm
    var hasCompletedSetup: Bool = false
    /// Kept for movie-ticket end-time math; not shown in Settings UI.
    var defaultAdvertisingMinutes: Int = 15
    /// `SidebarItem.rawValue` (stable English id).
    var defaultStartupPageRaw: String = SidebarItem.quickPrint.rawValue
    var appLanguageRaw: String = AppLanguage.installDefault.rawValue
    /// When false, working drafts (quick / excel / POS cart) are cleared on quit and next launch.
    var retainWorkingContentOnQuit: Bool = true

    private static let key = "ReceiptPrinter.AppSettings"
    private static let tmdbKeychainKey = "ReceiptPrinter.TMDBAPIKey"

    enum CodingKeys: String, CodingKey {
        case selectedPrinterName, printerConfig, hasCompletedSetup
        case defaultAdvertisingMinutes
        case defaultStartupPageRaw, appLanguageRaw
        case retainWorkingContentOnQuit
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedPrinterName = try c.decodeIfPresent(String.self, forKey: .selectedPrinterName)
        printerConfig = try c.decodeIfPresent(PrinterConfig.self, forKey: .printerConfig) ?? .default80mm
        hasCompletedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false
        defaultAdvertisingMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultAdvertisingMinutes) ?? 15
        defaultStartupPageRaw = try c.decodeIfPresent(String.self, forKey: .defaultStartupPageRaw)
            ?? SidebarItem.quickPrint.rawValue
        appLanguageRaw = try c.decodeIfPresent(String.self, forKey: .appLanguageRaw)
            ?? AppLanguage.installDefault.rawValue
        retainWorkingContentOnQuit = try c.decodeIfPresent(Bool.self, forKey: .retainWorkingContentOnQuit) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedPrinterName, forKey: .selectedPrinterName)
        try c.encode(printerConfig, forKey: .printerConfig)
        try c.encode(hasCompletedSetup, forKey: .hasCompletedSetup)
        try c.encode(defaultAdvertisingMinutes, forKey: .defaultAdvertisingMinutes)
        try c.encode(defaultStartupPageRaw, forKey: .defaultStartupPageRaw)
        try c.encode(appLanguageRaw, forKey: .appLanguageRaw)
        try c.encode(retainWorkingContentOnQuit, forKey: .retainWorkingContentOnQuit)
    }

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguageRaw) ?? .installDefault }
        set { appLanguageRaw = newValue.rawValue }
    }

    var defaultStartupPage: SidebarItem {
        get {
            let item = SidebarItem.fromPersisted(defaultStartupPageRaw)
            return SidebarItem.sidebarItems.contains(item) ? item : .quickPrint
        }
        set { defaultStartupPageRaw = newValue.rawValue }
    }

    var tmdbAPIKey: String {
        get {
            guard let data = KeychainHelper.load(key: Self.tmdbKeychainKey),
                  let value = String(data: data, encoding: .utf8) else { return "" }
            return value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainHelper.delete(key: Self.tmdbKeychainKey)
            } else if let data = trimmed.data(using: .utf8) {
                KeychainHelper.save(key: Self.tmdbKeychainKey, data: data)
            }
        }
    }

    var tmdbAPIKeyStored: Bool {
        !tmdbAPIKey.isEmpty
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        // Head→cutter gap on common 80mm POS needs more than the old default of 4 lines.
        if settings.printerConfig.feedLinesBeforeCut < 12 {
            settings.printerConfig.feedLinesBeforeCut = 12
            settings.save()
        }
        // Migrate legacy Chinese sidebar labels / removed Gmail pages to stable ids.
        if let legacy = SidebarItem.fromLegacyTitle(settings.defaultStartupPageRaw) {
            settings.defaultStartupPageRaw = legacy.rawValue
            settings.save()
        } else if ["emailExtraction", "orders", "cinemaRules", "gmail"].contains(settings.defaultStartupPageRaw) {
            settings.defaultStartupPageRaw = SidebarItem.quickPrint.rawValue
            settings.save()
        }
        return settings
    }

    /// Factory defaults for the Settings UI (keeps machine-specific printer name).
    static func uiDefaults(keepingPrinter printer: String?) -> (
        printerConfig: PrinterConfig,
        defaultStartupPage: SidebarItem,
        appLanguage: AppLanguage,
        tmdbAPIKey: String
    ) {
        (
            .default80mm,
            .quickPrint,
            .installDefault,
            ""
        )
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
