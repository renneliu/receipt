import Foundation

struct ReceiptTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var paperWidth: Int = 80
    var blocks: [TemplateBlock] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    mutating func touch() {
        updatedAt = Date()
    }

    func placeholders() -> [String] {
        var keys = Set<String>()
        for block in blocks {
            keys.formUnion(extractPlaceholders(from: block.content))
            if let ds = block.dataSource { keys.insert(ds) }
        }
        return keys.sorted()
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
