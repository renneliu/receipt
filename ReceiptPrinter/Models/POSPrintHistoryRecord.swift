import Foundation

/// One completed POS receipt print (business history, not diagnostic SHA logs).
struct POSPrintHistoryRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var templateId: UUID?
    var templateName: String
    var items: [POSLineItem]
    var surcharge: String
    /// e.g. `"10%"` when surcharge came from a percent shortcut; empty if manual.
    var surchargePercentLabel: String
    /// PNG of the rendered ticket for quick preview / PDF export.
    var previewPNG: Data

    var itemSummary: String {
        let names = items.map(\.name).filter { !$0.isEmpty }
        if names.isEmpty { return "（无条目）" }
        if names.count <= 2 { return names.joined(separator: "、") }
        return "\(names[0])、\(names[1]) 等\(items.count)项"
    }

    var amountTotalText: String {
        POSReceiptTotals.formatAmount(POSReceiptTotals.amountTotal(items: items, surcharge: surcharge))
    }
}

enum POSPrintHistoryStore {
    private static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("ReceiptPrinter", isDirectory: true)
            .appendingPathComponent("POSPrintHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    static func loadAll() -> [POSPrintHistoryRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([POSPrintHistoryRecord].self, from: data)) ?? []
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    static func saveAll(_ records: [POSPrintHistoryRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func append(_ record: POSPrintHistoryRecord, limit: Int = 100) {
        var all = loadAll()
        all.insert(record, at: 0)
        if all.count > limit {
            all = Array(all.prefix(limit))
        }
        saveAll(all)
    }

    static func delete(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
    }

    static func clear() {
        saveAll([])
    }
}
