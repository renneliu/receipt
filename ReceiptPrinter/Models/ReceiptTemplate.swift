import Foundation

struct ReceiptTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var paperWidth: Int = 80
    var blocks: [TemplateBlock] = []
    /// Default field values for preview / test print (e.g. movie ticket form data).
    var defaultData: [String: String] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    mutating func touch() {
        updatedAt = Date()
    }

    func placeholders() -> [String] {
        allPlaceholderKeys().sorted()
    }

    func allPlaceholderKeys() -> [String] {
        var keys = Set<String>()
        for block in blocks {
            keys.formUnion(extractPlaceholders(from: block.content))
            keys.formUnion(extractPlaceholders(from: block.rightContent))
            keys.formUnion(extractPlaceholders(from: block.rightHighlight))
            if let ds = block.dataSource { keys.insert(ds) }
        }
        return Array(keys)
    }

    private func extractPlaceholders(from text: String) -> [String] {
        let pattern = #"\{\{(\w+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    static func substitute(_ text: String, data: [String: String]) -> String {
        var result = text
        for (key, value) in data {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
