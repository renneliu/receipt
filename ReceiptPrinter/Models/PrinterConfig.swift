import Foundation

struct PrinterConfig: Codable, Equatable {
    var paperWidthMM: Int = 80
    var dotsPerLine: Int = 576
    var columnsPerLine: Int = 48
    var encoding: TextEncoding = .gbk
    var cutPaper: Bool = true
    var feedLinesBeforeCut: Int = 4

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

    private static let key = "ReceiptPrinter.AppSettings"

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
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
