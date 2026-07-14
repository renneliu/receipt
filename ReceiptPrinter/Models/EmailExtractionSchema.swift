import Foundation

/// Placeholder model for Phase 5 email extraction schemas.
struct EmailExtractionSchema: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var searchQuery: String = ""
    var fields: [EmailExtractionField] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct EmailExtractionField: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var strategy: ExtractionStrategy
}

enum ExtractionStrategy: Codable, Equatable {
    case anchorBeforeAfter(before: String, after: String)
    case regex(pattern: String)
    case fixedValue(String)
}

final class ExtractionSchemaStore {
    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = appSupport.appendingPathComponent("ReceiptPrinter/ExtractionSchemas", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() -> [EmailExtractionSchema] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> EmailExtractionSchema? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(EmailExtractionSchema.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ schema: EmailExtractionSchema) {
        var updated = schema
        updated.updatedAt = Date()
        let url = directory.appendingPathComponent("\(schema.id.uuidString).json")
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func delete(_ schema: EmailExtractionSchema) {
        let url = directory.appendingPathComponent("\(schema.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
