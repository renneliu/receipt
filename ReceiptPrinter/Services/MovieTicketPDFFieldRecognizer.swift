import Foundation
import PDFKit

/// Per-field PDF auto-detection (rule editor: try auto first, then manual box).
enum MovieTicketPDFFieldRecognizer {
    struct Hit: Equatable {
        var value: String
        /// Suggested locate keywords for the saved region.
        var keywords: [String]
        var extractKind: MovieTicketPDFExtractKind
        var extractKeyword: String
    }

    /// Attempt page-wide feature detection for a field. Nil = ask user to box-select.
    static func autoDetect(
        fieldKind: MovieTicketFieldKind,
        from url: URL,
        pageIndex: Int = 0
    ) -> Hit? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: pageIndex),
              let full = page.string,
              !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        switch fieldKind {
        case .movieTitle:
            return detectMovieTitle(in: full)
        case .hall:
            return detectHall(in: full, page: page)
        case .seatArea:
            return detectSeat(in: full)
        case .ticketType:
            return detectTicketType(in: full)
        case .ticketPrice:
            return detectPrice(page: page, full: full)
        case .serialNumber, .barcode, .qrCode:
            // Barcode / QR print content comes from the same booking serial.
            return detectSerial(in: full)
        case .startTime, .timeRange:
            return detectStartTime(in: full, page: page)
        case .showDate:
            return detectShowDate(in: full, page: page)
        case .endTime:
            return nil
        }
    }

    /// Upsert a page-wide region after a successful auto-detect.
    static func makeAutoRegion(
        for element: MovieTicketElement,
        hit: Hit,
        existingId: UUID? = nil,
        preserving previous: MovieTicketPDFRegion? = nil
    ) -> MovieTicketPDFRegion? {
        guard let field = element.fieldKind else { return nil }
        return MovieTicketPDFRegion(
            id: existingId ?? UUID(),
            fieldKind: field,
            elementId: element.id,
            rect: MovieTicketRelativeRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            pageIndex: 0,
            captureMode: hit.keywords.isEmpty ? .positionOnly : .withKeywords,
            regionKeywords: hit.keywords,
            extractKind: hit.extractKind,
            extractKeyword: hit.extractKeyword,
            extractSample: hit.value,
            extractedHint: hit.value,
            valueMappings: previous?.valueMappings ?? [],
            printPrefix: previous?.printPrefix ?? "",
            printSuffix: previous?.printSuffix ?? "",
            isPageWideAuto: true
        )
    }

    // MARK: - Field detectors

    private static func detectMovieTitle(in full: String) -> Hit? {
        // Prefer ticket-body title (line above booking code + Seats). Email subjects like
        // "Your ticket to The Bride! at IMAX Sydney" must not win over "The Bride!".
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^([^\n]{2,80})\n[A-Z0-9]{5,12}\s*\nSeats\b"#
        ),
           let match = re.firstMatch(
            in: full,
            range: NSRange(location: 0, length: (full as NSString).length)
           ),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: full) {
            let title = String(full[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleTitle(title) {
                return Hit(value: title, keywords: ["Seats"], extractKind: .entire, extractKeyword: "")
            }
        }

        let anchors = ["YOUR TICKET TO", "YOUR TICKET", "TICKET TO"]
        for anchor in anchors {
            if let range = full.range(of: anchor, options: .caseInsensitive) {
                let after = String(full[range.upperBound...])
                let line = firstMeaningfulLine(after)
                // Skip email-subject style "Title at Cinema".
                if isPlausibleTitle(line), !looksLikeEmailSubjectTitle(line) {
                    return Hit(
                        value: line,
                        keywords: [anchor],
                        extractKind: .afterKeyword,
                        extractKeyword: anchor
                    )
                }
            }
        }
        return nil
    }

    private static func looksLikeEmailSubjectTitle(_ s: String) -> Bool {
        s.range(of: #"\bat\s+\w+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func detectHall(in full: String, page: PDFPage) -> Hit? {
        if let screen = MovieTicketPDFRecognitionService.pageHallScreen(from: page) {
            return Hit(
                value: screen,
                keywords: ["CINEMA NUMBER", "Screen"],
                extractKind: .entire,
                extractKeyword: ""
            )
        }
        if let m = firstRegex(in: full, #"(?i)\bScreen\s+\d+\b"#) {
            return Hit(value: m, keywords: ["Screen"], extractKind: .entire, extractKeyword: "")
        }
        // Venue line used as hall when no Screen N (IMAX Sydney tickets).
        if let m = firstRegex(in: full, #"(?i)\bIMAX\s+Sydney\b"#) {
            return Hit(value: m, keywords: ["IMAX"], extractKind: .entire, extractKeyword: "")
        }
        return nil
    }

    private static func detectSeat(in full: String) -> Hit? {
        if full.range(of: #"(?i)\bunallocated\b"#, options: .regularExpression) != nil {
            return Hit(value: "Unallocated", keywords: ["Seats"], extractKind: .entire, extractKeyword: "")
        }
        if let range = full.range(of: "Seats", options: .caseInsensitive) {
            let after = String(full[range.upperBound...])
            let line = firstMeaningfulLine(after)
            if !line.isEmpty, line.count <= 24, !line.lowercased().contains("saturday") {
                return Hit(
                    value: line,
                    keywords: ["Seats"],
                    extractKind: .afterKeyword,
                    extractKeyword: "Seats"
                )
            }
        }
        if let m = firstRegex(in: full, #"\b[A-Z]\d{1,2}(?:\s*[-–]\s*[A-Z]?\d{1,2})?\b"#) {
            return Hit(value: m, keywords: ["Seats"], extractKind: .entire, extractKeyword: "")
        }
        return nil
    }

    private static func detectTicketType(in full: String) -> Hit? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\d+x\s+[^\n]{3,60}"#),
              let match = re.firstMatch(
                in: full,
                range: NSRange(location: 0, length: (full as NSString).length)
              ),
              let r = Range(match.range, in: full)
        else { return nil }
        let value = String(full[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Hit(value: value, keywords: [], extractKind: .entire, extractKeyword: "")
    }

    private static func detectPrice(page: PDFPage, full: String) -> Hit? {
        if let total = MovieTicketPDFRecognitionService.pageTotalCurrency(from: page) {
            return Hit(
                value: total,
                keywords: ["Total"],
                extractKind: .currency,
                extractKeyword: "Total"
            )
        }
        if let m = firstRegex(in: full, #"(?i)Total(?:\s+cost)?\s*:?\s*\$?\s*(\d+\.\d{2})"#) {
            return Hit(
                value: m.contains("$") ? m : "$\(m)",
                keywords: ["Total"],
                extractKind: .currency,
                extractKeyword: "Total"
            )
        }
        return nil
    }

    private static func detectSerial(in full: String) -> Hit? {
        // Event Cinemas / IMAX: booking code on its own line above "Seats" (e.g. WJKMTX9).
        if let re = try? NSRegularExpression(pattern: #"(?m)^([A-Z0-9]{5,12})\s*\nSeats\b"#),
           let match = re.firstMatch(in: full, range: NSRange(location: 0, length: (full as NSString).length)),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: full) {
            let code = String(full[r])
            return Hit(value: code, keywords: ["Seats"], extractKind: .entire, extractKeyword: "")
        }

        // Prefer longest digit run that is not a card PAN / phone-like blob.
        let ns = full as NSString
        if let reD = try? NSRegularExpression(pattern: #"\b\d{6,14}\b"#) {
            let matches = reD.matches(in: full, range: NSRange(location: 0, length: ns.length))
            var bestDigits = ""
            for m in matches {
                guard let r = Range(m.range, in: full) else { continue }
                let token = String(full[r])
                if token.count > 14 { continue }
                if token.count > bestDigits.count { bestDigits = token }
            }
            if !bestDigits.isEmpty {
                return Hit(value: bestDigits, keywords: [], extractKind: .digits, extractKeyword: "")
            }
        }

        let pattern = #"[A-Z0-9]{5,12}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = re.matches(in: full, range: NSRange(location: 0, length: ns.length))
        var best = ""
        var bestScore = 0
        for m in matches {
            guard let r = Range(m.range, in: full) else { continue }
            let token = String(full[r])
            let upper = token.uppercased()
            if upper.hasPrefix("HTTP") || upper.contains("GMAIL") || upper.contains("IMAX") {
                continue
            }
            let digitCount = token.filter(\.isNumber).count
            let letterCount = token.filter(\.isLetter).count
            // Prefer mixed booking codes over pure letters.
            let score = digitCount * 12 + letterCount * 3 + token.count
            if score > bestScore {
                bestScore = score
                best = token
            }
        }
        guard !best.isEmpty else { return nil }
        return Hit(value: best, keywords: [], extractKind: .entire, extractKeyword: "")
    }

    private static func detectStartTime(in full: String, page: PDFPage) -> Hit? {
        if let session = MovieTicketPDFRecognitionService.pageSessionDateTime(from: page),
           let clock = MovieTicketPDFRecognitionService.clockOnly(from: session)
            ?? MovieTicketPDFRecognitionService.clockOnly(from: full) {
            return Hit(
                value: clock,
                keywords: ["Time"],
                extractKind: .entire,
                extractKeyword: ""
            )
        }
        if let clock = MovieTicketPDFRecognitionService.clockOnly(from: full) {
            return Hit(
                value: clock,
                keywords: ["Time"],
                extractKind: .entire,
                extractKeyword: ""
            )
        }
        return nil
    }

    private static func detectShowDate(in full: String, page: PDFPage) -> Hit? {
        if let date = MovieTicketPDFRecognitionService.dateOnly(from: page)
            ?? MovieTicketPDFRecognitionService.dateOnly(from: full) {
            return Hit(
                value: date,
                keywords: ["Time", "SESSION DATE"],
                extractKind: .entire,
                extractKeyword: ""
            )
        }
        return nil
    }

    // MARK: - Helpers

    private static func firstMeaningfulLine(_ text: String) -> String {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let t = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            return t
        }
        return ""
    }

    private static func isPlausibleTitle(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 80 else { return false }
        let upper = t.uppercased()
        if upper.hasPrefix("SEAT") || upper.hasPrefix("SCREEN") || upper.contains("CINEMA NUMBER") {
            return false
        }
        return true
    }

    private static func firstRegex(in text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}
