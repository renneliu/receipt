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

struct AppSettings: Codable {
    var selectedPrinterName: String?
    var printerConfig: PrinterConfig = .default80mm
    var hasCompletedSetup: Bool = false
    var gmailClientID: String = ""
    var gmailClientSecret: String = ""
    var gmailRedirectURI: String = GmailOAuthConfig.defaultRedirectURI
    var gmailSyncEnabled: Bool = false
    var gmailSyncInterval: TimeInterval = 300
    var gmailSearchQuery: String = ""
    var gmailTimeRange: GmailTimeRange = .any
    var gmailCustomStart: Date?
    var gmailCustomEnd: Date?
    var gmailFilter: GmailFilter = GmailFilter()
    var defaultAdvertisingMinutes: Int = 15

    private static let key = "ReceiptPrinter.AppSettings"
    private static let tmdbKeychainKey = "ReceiptPrinter.TMDBAPIKey"

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
        let migrated = GmailOAuthConfig.normalizedRedirectURI(settings.gmailRedirectURI)
        if migrated != settings.gmailRedirectURI {
            settings.gmailRedirectURI = migrated
            settings.save()
        }
        if ["is:unread newer_than:7d", "newer_than:30d"].contains(settings.gmailSearchQuery) {
            settings.gmailSearchQuery = ""
            settings.save()
        }
        // Head→cutter gap on common 80mm POS needs more than the old default of 4 lines.
        if settings.printerConfig.feedLinesBeforeCut < 12 {
            settings.printerConfig.feedLinesBeforeCut = 12
            settings.save()
        }
        return settings
    }

    /// Merges legacy free-text filter, time range, and structured GmailFilter into extra `q` clauses.
    func composedGmailExtraQuery(now: Date = Date()) -> String {
        var parts: [String] = []
        if let time = gmailTimeRange.queryFragment(customStart: gmailCustomStart, customEnd: gmailCustomEnd, now: now) {
            parts.append(time)
        }
        if let filter = gmailFilter.queryFragment() {
            parts.append(filter)
        }
        let legacy = gmailSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            parts.append(legacy)
        }
        return parts.joined(separator: " ")
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
