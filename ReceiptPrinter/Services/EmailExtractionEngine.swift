import Foundation

enum EmailExtractionEngine {
    static func extractFields(from body: String, schema: EmailExtractionSchema) -> [String: String] {
        var result: [String: String] = [:]
        for field in schema.fields {
            result[field.id] = extractField(field, from: body) ?? ""
        }
        return result
    }

    static func extractField(_ field: EmailExtractionField, from body: String) -> String? {
        switch field.strategy {
        case .anchorBeforeAfter(let before, let after):
            return extractAnchor(before: before, after: after, in: body)
        case .regex(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(body.startIndex..., in: body)
            guard let match = regex.firstMatch(in: body, range: range),
                  match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        case .fixedValue(let value):
            return value
        }
    }

    static func suggestRegex(from selection: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: selection.trimmingCharacters(in: .whitespacesAndNewlines))
        return "(\\Q\(escaped)\\E)"
    }

    private static func extractAnchor(before: String, after: String, in body: String) -> String? {
        guard !before.isEmpty || !after.isEmpty else { return nil }
        if !before.isEmpty, let range = body.range(of: before) {
            let start = range.upperBound
            if !after.isEmpty, let endRange = body.range(of: after, range: start..<body.endIndex) {
                return String(body[start..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(body[start...].prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !after.isEmpty, let range = body.range(of: after) {
            return String(body[..<range.lowerBound].suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

/// Lists Gmail messages for extraction rule testing (reuses sync auth).
struct GmailSearchService {
    let auth: GmailAuthService

    func searchMessages(query: String, maxResults: Int = 20) async throws -> [GmailMessageSummary] {
        let settings = AppSettings.load()
        let token = try await auth.validAccessToken(clientID: settings.gmailClientID, clientSecret: settings.gmailClientSecret)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NSError(domain: "GmailSearch", code: status) }
        let decoded = try JSONDecoder().decode(GmailListResponse.self, from: data)
        return decoded.messages ?? []
    }

    func fetchPlainBody(messageId: String) async throws -> String {
        let settings = AppSettings.load()
        let token = try await auth.validAccessToken(clientID: settings.gmailClientID, clientSecret: settings.gmailClientSecret)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)?format=full")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let detail = try JSONDecoder().decode(GmailMessageDetail.self, from: data)
        return GmailBodyExtractor.plainBody(from: detail.payload)
    }
}

enum GmailBodyExtractor {
    static func plainBody(from payload: GmailMessagePayload?) -> String {
        guard let payload else { return "" }
        if let plain = extract(payload: payload, mimeContains: "plain") { return plain }
        if let html = extract(payload: payload, mimeContains: "html") {
            return EmailParserService.plainText(from: html)
        }
        return ""
    }

    private static func extract(payload: GmailMessagePayload, mimeContains: String) -> String? {
        if payload.mimeType?.contains(mimeContains) == true,
           let data = payload.body?.data,
           let text = decodeBase64URL(data) { return text }
        for part in payload.parts ?? [] {
            if let nested = extract(payload: part, mimeContains: mimeContains) { return nested }
        }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> String? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = 4 - base64.count % 4
        if padding < 4 { base64 += String(repeating: "=", count: padding) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
