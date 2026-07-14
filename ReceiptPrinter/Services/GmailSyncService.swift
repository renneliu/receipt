import Foundation

struct GmailMessageSummary: Decodable {
    let id: String
    let threadId: String?
}

struct GmailListResponse: Decodable {
    let messages: [GmailMessageSummary]?
}

struct GmailHeader: Decodable {
    let name: String
    let value: String
}

struct GmailMessagePayload: Decodable {
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailMessagePayload]?
    let mimeType: String?
}

struct GmailBody: Decodable {
    let data: String?
    let size: Int?
}

struct GmailMessageDetail: Decodable {
    let id: String
    let snippet: String?
    let payload: GmailMessagePayload?
    let internalDate: String?
}

final class GmailSyncService {
    var onNewOrder: ((PendingOrder) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var rulesProvider: (() -> [CinemaRule])?
    var settingsProvider: (() -> AppSettings)?
    var templatesProvider: (() -> [ReceiptTemplate])?
    var hasOrderForMessageId: ((String) -> Bool)?
    var hasProcessedMessageId: ((String) -> Bool)?

    private let auth: GmailAuthService
    private var timer: Timer?
    private var isSyncing = false

    /// Whether the periodic Gmail poll timer is active (used to note status-polling state per print job).
    var isRunning: Bool { timer != nil }

    init(auth: GmailAuthService) {
        self.auth = auth
    }

    func start(interval: TimeInterval) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let rules = self.rulesProvider?() ?? []
                let settings = self.settingsProvider?() ?? AppSettings.load()
                await self.syncNow(rules: rules, settings: settings)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    func syncNow(rules: [CinemaRule], settings: AppSettings) async {
        guard !isSyncing else { return }
        guard auth.isAuthenticated else {
            onStatusChange?("未连接 Gmail")
            return
        }
        isSyncing = true
        onStatusChange?("同步中...")
        defer { isSyncing = false }

        do {
            let token = try await auth.validAccessToken(clientID: settings.gmailClientID, clientSecret: settings.gmailClientSecret)
            let enabledRules = rules.filter(\.enabled)
            let buildResult = GmailSearchQueryBuilder.build(rules: rules, settings: settings)
            guard case .success(let searchQuery, let usedRuleCriteria) = buildResult else {
                if case .failure(let error) = buildResult {
                    onStatusChange?(error.localizedDescription)
                }
                return
            }
            let messages = try await fetchMessageList(token: token, query: searchQuery)
            var count = 0
            for summary in messages {
                if hasOrderForMessageId?(summary.id) == true {
                    continue
                }
                guard let detail = try await fetchMessage(token: token, id: summary.id) else { continue }
                let parsed = parseMessage(detail)
                guard let rule = enabledRules.first(where: { $0.matchRules.matches(sender: parsed.sender, subject: parsed.subject, body: parsed.plainBody) }) else {
                    continue
                }
                let (fields, missing) = extractOrderFields(
                    rule: rule,
                    sender: parsed.sender,
                    subject: parsed.subject,
                    plainText: parsed.plainBody,
                    html: parsed.htmlBody
                )
                let order = PendingOrder(
                    messageId: summary.id,
                    ruleId: rule.id,
                    ruleName: rule.cinemaName,
                    templateId: rule.templateId,
                    cinemaName: rule.cinemaName,
                    subject: parsed.subject,
                    sender: parsed.sender,
                    receivedAt: parsed.date,
                    fields: fields,
                    missingFields: missing,
                    emailSnippet: parsed.snippet,
                    emailPlainBody: parsed.plainBody,
                    status: .pending
                )
                onNewOrder?(order)
                count += 1
            }
            if messages.isEmpty {
                if usedRuleCriteria {
                    onStatusChange?("未找到匹配影院规则的邮件。搜索: \(searchQuery)")
                } else {
                    onStatusChange?("未找到邮件（搜索: \(searchQuery)）。可扩大时间范围或完善规则中的发件人/主题。")
                }
            } else if enabledRules.isEmpty {
                onStatusChange?("获取 \(messages.count) 封邮件，但没有启用的影院规则。请先在「影院规则」添加并保存。")
            } else {
                onStatusChange?("上次同步: \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))，获取 \(messages.count) 封，新增 \(count) 条")
            }
        } catch {
            onStatusChange?("同步失败: \(GmailAPIErrorHelper.userMessage(for: error))")
        }
    }

    private func extractOrderFields(
        rule: CinemaRule,
        sender: String,
        subject: String,
        plainText: String,
        html: String
    ) -> (fields: [String: String], missing: [String]) {
        let templates = templatesProvider?() ?? []
        let template = templates.first { $0.id == rule.templateId }
        let useOrpheum = OrpheumEmailParser.isOrpheumEmail(sender: sender, subject: subject, body: plainText)
            || (template.map { MovieTicketData.isMovieTicketTemplate($0) } ?? false)

        if useOrpheum, let parsed = OrpheumEmailParser.parse(plainText: plainText, html: html, subject: subject) {
            return (parsed, [])
        }
        let generic = EmailParserService.extractFields(rule: rule, plainText: plainText, html: html)
        if useOrpheum {
            return (OrpheumEmailParser.normalizeLegacyFieldKeys(generic.fields), generic.missing)
        }
        return generic
    }

    private func fetchMessageList(token: String, query: String) async throws -> [GmailMessageSummary] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "20")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "HTTP \(status)"
            throw NSError(domain: "GmailSync", code: status, userInfo: [NSLocalizedDescriptionKey: GmailAPIErrorHelper.userMessage(forAPIError: message)])
        }
        let decoded = try JSONDecoder().decode(GmailListResponse.self, from: data)
        return decoded.messages ?? []
    }

    private func fetchMessage(token: String, id: String) async throws -> GmailMessageDetail? {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GmailMessageDetail.self, from: data)
    }

    private struct ParsedEmail {
        let sender: String
        let subject: String
        let plainBody: String
        let htmlBody: String
        let snippet: String
        let date: Date
    }

    private func parseMessage(_ message: GmailMessageDetail) -> ParsedEmail {
        let headers = message.payload?.headers ?? []
        let sender = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? ""
        let html = extractBody(payload: message.payload, preferHTML: true)
        let plain = extractBody(payload: message.payload, preferHTML: false)
        let plainText = plain.isEmpty ? EmailParserService.plainText(from: html) : plain
        let date: Date
        if let ms = message.internalDate, let interval = TimeInterval(ms) {
            date = Date(timeIntervalSince1970: interval / 1000)
        } else {
            date = Date()
        }
        return ParsedEmail(sender: sender, subject: subject, plainBody: plainText, htmlBody: html, snippet: message.snippet ?? plainText.prefix(200).description, date: date)
    }

    private func extractBody(payload: GmailMessagePayload?, preferHTML: Bool) -> String {
        guard let payload else { return "" }
        if preferHTML {
            if payload.mimeType?.contains("html") == true, let data = payload.body?.data, let text = decodeBase64URL(data) { return text }
            for part in payload.parts ?? [] {
                if part.mimeType?.contains("html") == true, let data = part.body?.data, let text = decodeBase64URL(data) { return text }
                let nested = extractBody(payload: part, preferHTML: true)
                if !nested.isEmpty { return nested }
            }
        } else {
            if payload.mimeType?.contains("plain") == true, let data = payload.body?.data, let text = decodeBase64URL(data) { return text }
            for part in payload.parts ?? [] {
                if part.mimeType?.contains("plain") == true, let data = part.body?.data, let text = decodeBase64URL(data) { return text }
                let nested = extractBody(payload: part, preferHTML: false)
                if !nested.isEmpty { return nested }
            }
        }
        return ""
    }

    private func decodeBase64URL(_ string: String) -> String? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = 4 - base64.count % 4
        if padding < 4 { base64 += String(repeating: "=", count: padding) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
