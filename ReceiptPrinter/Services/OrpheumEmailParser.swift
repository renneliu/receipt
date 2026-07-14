import Foundation

/// Parses Hayden Orpheum booking confirmation emails into movie-ticket template data.
enum OrpheumEmailParser {
    private static let showtimePattern = #"(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\s+[A-Za-z]+\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s*(?:AM|PM)"#

    static func isOrpheumEmail(sender: String, subject: String, body: String) -> Bool {
        let haystack = "\(sender) \(subject) \(body)".lowercased()
        return haystack.contains("orpheum") || haystack.contains("hayden")
    }

    static func parse(plainText: String, html: String, subject: String = "") -> [String: String]? {
        let text = combinedText(plainText: plainText, html: html, subject: subject)
        guard !text.isEmpty else { return nil }

        let showtimeString = firstMatch(pattern: showtimePattern, in: text)
        let showStart = showtimeString.flatMap { parseShowtime($0) }
        let movieTitle = extractMovieFromSubject(subject)
            ?? (showtimeString.flatMap { extractMovieTitle(in: text, showtime: $0) })
            ?? extractMovieFromOrderLine(in: text)
            ?? ""
        let hallNumber = extractHallNumber(in: text) ?? "4"
        let reference = firstCapture(pattern: #"Reference\s*#\s*:?\s*(\d+)"#, in: text)
        let total = firstCapture(pattern: #"Total\s*[\s\n\*]*(\d+(?:\.\d+)?)"#, in: text, options: [.dotMatchesLineSeparators])

        guard !movieTitle.isEmpty || showtimeString != nil || reference != nil || total != nil else {
            return nil
        }

        var ticket = MovieTicketData.orpheumBlank
        ticket.hallNumber = hallNumber
        if !movieTitle.isEmpty { ticket.movieTitle = movieTitle }
        if let showStart { ticket.showStartTime = showStart }
        if let total { ticket.ticketPrice = total }
        if let reference {
            let digits = reference.filter(\.isNumber)
            ticket.barcodeBase = MovieTicketData.padBarcodeBase(digits)
            ticket.ticketSerial = "001"
        }

        var rendered = ticket.renderedDictionary()
        if movieTitle.isEmpty {
            rendered["movieTitle"] = ""
        }
        if showtimeString == nil {
            rendered["showDateTime"] = ""
        }
        if let reference {
            let digits = reference.filter(\.isNumber)
            rendered["barcode"] = digits
            rendered["ticketCode"] = "DEBI \(MovieTicketData.padBarcodeBase(digits))/\(ticket.normalizedTicketSerial)"
            rendered["barcodeLabel"] = "* \(digits.map(String.init).joined(separator: " ")) *"
        }

        return rendered
    }

    static func parseForOrder(_ order: PendingOrder) -> [String: String]? {
        parse(
            plainText: order.emailPlainBody.isEmpty ? order.emailSnippet : order.emailPlainBody,
            html: "",
            subject: order.subject
        )
    }

    private static func combinedText(plainText: String, html: String, subject: String) -> String {
        let body = plainText.isEmpty ? EmailParserService.plainText(from: html) : plainText
        if body.isEmpty { return subject }
        return body
    }

    static func extractMovieFromSubject(_ subject: String) -> String? {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = firstCapture(pattern: #"(?i)booking for\s+(.+)"#, in: trimmed) {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let title = firstCapture(pattern: #"(?i)booking:\s*(.+)"#, in: trimmed) {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractMovieTitle(in text: String, showtime: String) -> String? {
        guard let range = text.range(of: showtime) else { return nil }
        let before = String(text[..<range.lowerBound])
        let lines = before
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let candidate = lines.last else { return nil }
        if candidate.localizedCaseInsensitiveContains("hayden") { return nil }
        if candidate.localizedCaseInsensitiveContains("reference") { return nil }
        return candidate
    }

    private static func extractMovieFromOrderLine(in text: String) -> String? {
        guard let raw = firstCapture(pattern: #"\d+\s*x\s+(.+?)\s*\|\s*C\d+\s+Orpheum"#, in: text) else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractHallNumber(in text: String) -> String? {
        if let hall = firstCapture(pattern: #"\bC(\d+)\s+Orpheum\b"#, in: text) { return hall }
        if let hall = firstCapture(pattern: #"\|\s*C(\d+)\s+Orpheum"#, in: text) { return hall }
        return nil
    }

    private static func parseShowtime(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, MMMM d, yyyy h:mm a"
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func firstCapture(pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeLegacyFieldKeys(_ fields: [String: String]) -> [String: String] {
        var mapped = fields
        if mapped["movieTitle"] == nil, let v = mapped["movieName"] { mapped["movieTitle"] = v }
        if mapped["hallNumber"] == nil, let v = mapped["hall"] { mapped["hallNumber"] = v }
        if mapped["venueName"] == nil, let v = mapped["cinemaName"] { mapped["venueName"] = v }
        if mapped["showDateTime"] == nil, let v = mapped["showTime"] { mapped["showDateTime"] = v }
        if mapped["ticketPrice"] == nil, let v = mapped["total"] { mapped["ticketPrice"] = v }
        if mapped["barcode"] == nil, let v = mapped["orderNo"] { mapped["barcode"] = v }
        return mapped
    }
}

extension MovieTicketData {
    static var orpheumBlank: MovieTicketData {
        MovieTicketData(
            venueName: "Orpheum",
            hallNumber: "4",
            movieTitle: "",
            showStartTime: Date(),
            adDurationMinutes: 0,
            movieDurationMinutes: 120,
            ticketType: "Adult",
            ticketPrice: "",
            barcodeBase: "00000000",
            ticketSerial: "001"
        )
    }

    static func padBarcodeBase(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.isEmpty { return "00000000" }
        if digits.count >= 8 { return String(digits.suffix(8)) }
        return String(repeating: "0", count: 8 - digits.count) + digits
    }
}

enum OrderPrintData {
    static let orpheumFieldLabels: [String: String] = [
        "movieTitle": "影片名",
        "showDateTime": "放映时间",
        "venueName": "影院",
        "hallNumber": "影厅号",
        "ticketPrice": "票价",
        "ticketType": "票种",
        "barcode": "条码",
        "ticketCode": "票号",
        "barcodeBase": "条码前缀",
        "ticketSerial": "条码序号"
    ]

    static func isOrpheumOrder(_ order: PendingOrder, templates: [ReceiptTemplate]) -> Bool {
        guard let template = templates.first(where: { $0.id == order.templateId }) else { return false }
        return MovieTicketData.isMovieTicketTemplate(template)
    }

    static func editableKeys(for order: PendingOrder, templates: [ReceiptTemplate]) -> [String] {
        if isOrpheumOrder(order, templates: templates) {
            return ["movieTitle", "showDateTime", "venueName", "hallNumber", "ticketPrice", "ticketType", "barcode"]
        }
        let keys = Set(order.fields.keys).union(order.manualFields.keys).union(order.missingFields)
        return keys.sorted()
    }

    static func resolvedFields(for order: PendingOrder, templates: [ReceiptTemplate]) -> [String: String] {
        var data = OrpheumEmailParser.normalizeLegacyFieldKeys(order.fields)
        if isOrpheumOrder(order, templates: templates), !hasOrpheumContent(data) {
            if let reparsed = OrpheumEmailParser.parseForOrder(order) {
                data = reparsed
            }
        }
        return data
    }

    static func merged(for order: PendingOrder, templates: [ReceiptTemplate]) -> [String: String] {
        var data = resolvedFields(for: order, templates: templates)
        for (key, value) in order.manualFields where !value.isEmpty {
            data[key] = value
        }

        guard isOrpheumOrder(order, templates: templates) else { return data }

        var ticket = MovieTicketData.orpheumBlank
        if let title = data["movieTitle"], !title.isEmpty { ticket.movieTitle = title }
        if let hall = data["hallNumber"], !hall.isEmpty { ticket.hallNumber = hall }
        if let venue = data["venueName"], !venue.isEmpty { ticket.venueName = venue }
        if let price = data["ticketPrice"], !price.isEmpty {
            ticket.ticketPrice = price.replacingOccurrences(of: "$", with: "")
        }
        if let type = data["ticketType"], !type.isEmpty { ticket.ticketType = type }
        if let barcode = data["barcode"], !barcode.isEmpty {
            ticket.syncBarcodeFromFullCode(barcode)
        }

        var rendered = ticket.renderedDictionary()
        if let manualShow = order.manualFields["showDateTime"], !manualShow.isEmpty {
            rendered["showDateTime"] = manualShow
        } else if let storedShow = data["showDateTime"], !storedShow.isEmpty {
            rendered["showDateTime"] = storedShow
        } else if !hasMeaningfulShowtime(data) {
            rendered["showDateTime"] = ""
        }
        if let manualTitle = order.manualFields["movieTitle"], !manualTitle.isEmpty {
            rendered["movieTitle"] = manualTitle
        } else if let title = data["movieTitle"], !title.isEmpty {
            rendered["movieTitle"] = title
        }
        if let barcode = data["barcode"], !barcode.isEmpty {
            rendered["barcode"] = barcode.filter(\.isNumber)
        }
        if let code = data["ticketCode"], !code.isEmpty { rendered["ticketCode"] = code }
        if let label = data["barcodeLabel"], !label.isEmpty { rendered["barcodeLabel"] = label }
        return rendered
    }

    private static func hasOrpheumContent(_ data: [String: String]) -> Bool {
        ["movieTitle", "showDateTime", "barcode", "ticketPrice"].contains { key in
            !(data[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasMeaningfulShowtime(_ data: [String: String]) -> Bool {
        !(data["showDateTime"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
