import Foundation

/// Business print history for Quick Print / Excel sequence (not diagnostic SHA logs).
struct ModulePrintHistoryRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// `quickPrint` or `spreadsheetSequence`
    var kind: String
    var summary: String
    var plainText: String
    /// Optional RTFD body for richer reload.
    var rtfdData: Data?
    var previewPNG: Data
    /// Excel sequence: how many rows were printed (0 = single current row).
    var sequenceRowCount: Int = 0

    var createdAtText: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

enum ModulePrintHistoryStore {
    private static func directory(kind: String) -> URL {
        AppPaths.subdirectory("ModulePrintHistory/\(kind)")
    }

    private static func indexURL(kind: String) -> URL {
        directory(kind: kind).appendingPathComponent("index.json")
    }

    static func loadAll(kind: String) -> [ModulePrintHistoryRecord] {
        guard let data = try? Data(contentsOf: indexURL(kind: kind)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([ModulePrintHistoryRecord].self, from: data)) ?? []
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    static func saveAll(_ records: [ModulePrintHistoryRecord], kind: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL(kind: kind), options: .atomic)
    }

    static func append(_ record: ModulePrintHistoryRecord, kind: String, limit: Int = 100) {
        var all = loadAll(kind: kind)
        all.insert(record, at: 0)
        if all.count > limit {
            all = Array(all.prefix(limit))
        }
        saveAll(all, kind: kind)
    }

    static func delete(id: UUID, kind: String) {
        var all = loadAll(kind: kind)
        all.removeAll { $0.id == id }
        saveAll(all, kind: kind)
    }

    static func clear(kind: String) {
        saveAll([], kind: kind)
    }

    static func clearAllKnown() {
        clear(kind: "quickPrint")
        clear(kind: "spreadsheetSequence")
    }
}
