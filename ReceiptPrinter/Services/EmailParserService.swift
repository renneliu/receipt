import Foundation

enum EmailParserService {
    static func plainText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractFields(rule: CinemaRule, plainText: String, html: String) -> (fields: [String: String], missing: [String]) {
        var fields: [String: String] = [:]
        var missing: [String] = []
        for (key, extractor) in rule.fieldExtractors {
            let source = extractor.source == .html ? html : plainText
            guard let regex = try? NSRegularExpression(pattern: extractor.pattern, options: [.dotMatchesLineSeparators]) else {
                missing.append(key)
                continue
            }
            let range = NSRange(source.startIndex..., in: source)
            let matches = regex.matches(in: source, range: range)
            guard !matches.isEmpty else {
                missing.append(key)
                continue
            }
            let match = extractor.pick == .last ? matches.last! : matches.first!
            if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: source) {
                fields[key] = String(source[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let r = Range(match.range, in: source) {
                fields[key] = String(source[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                missing.append(key)
            }
        }
        return (fields, missing)
    }
}
