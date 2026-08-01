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

    /// Run page-text detectors without a PDF (unit tests + diagnostics).
    static func detectFromPageText(_ fieldKind: MovieTicketFieldKind, text: String) -> String? {
        let full = text
        switch fieldKind {
        case .movieTitle: return detectMovieTitle(in: full)?.value
        case .hall:
            return firstRegex(in: full, #"(?i)\bScreen\s+\d+\b"#)
                ?? firstRegex(in: full, #"(?i)\bIMAX\s+Sydney\b"#)
                ?? firstRegex(in: full, #"(?i)\bCinema\s+\d+\b"#)
        case .seatArea: return detectSeat(in: full)?.value
        case .ticketType: return detectTicketType(in: full)?.value
        case .showDate: return MovieTicketPDFRecognitionService.dateOnly(from: full)
        case .endTime: return detectEndTime(in: full)?.value
        case .startTime, .timeRange:
            return MovieTicketPDFRecognitionService.clockOnly(from: full)
        default:
            return nil
        }
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
            return detectStartTime(in: full, page: page, includeDate: false)
        case .showDate:
            return detectShowDate(in: full, page: page)
        case .endTime:
            return detectEndTime(in: full)
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
            isPageWideAuto: true,
            recognizeDate: previous?.recognizeDate
        )
    }

    /// Auto-detect with optional date for time fields (respects「同时识别日期」).
    static func autoDetect(
        fieldKind: MovieTicketFieldKind,
        from url: URL,
        includeDateWithTime: Bool
    ) -> Hit? {
        guard fieldKind == .startTime || fieldKind == .timeRange else {
            return autoDetect(fieldKind: fieldKind, from: url)
        }
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let full = page.string ?? ""
        return detectStartTime(in: full, page: page, includeDate: includeDateWithTime)
    }

    // MARK: - Field detectors

    private static func detectMovieTitle(in full: String) -> Hit? {
        // Prefer explicit title anchors first. The Seats-adjacent line is often a
        // ticket product ("Retro 3 Pass Redemption x 1"), not the film title.
        // Use multi-line collection so PDF wraps like "35MM J" + "OINT…" become JOINT.
        let anchors = ["YOUR TICKET TO", "YOUR TICKET", "TICKET TO"]
        if let title = MovieTicketPDFRecognitionService.valueAfterKeywords(
            anchors, in: full, fieldKind: .movieTitle
        ),
           isPlausibleTitle(title),
           !looksLikeEmailSubjectTitle(title) {
            let used = anchors.first { full.range(of: $0, options: .caseInsensitive) != nil } ?? anchors[0]
            return Hit(
                value: title,
                keywords: [used],
                extractKind: .afterKeyword,
                extractKeyword: used
            )
        }

        // Web ticket: title near the SHOWING heading (PDF text order is often jumbled).
        if let showingHit = titleNearShowingLabel(in: full) {
            return showingHit
        }

        // Event / Dendy: title is the line under TICKETS (before the session date line).
        if let re = try? NSRegularExpression(
            pattern: #"(?im)^TICKETS\s*\n([^\n]{2,80})\n"#
        ),
           let match = re.firstMatch(
            in: full,
            range: NSRange(location: 0, length: (full as NSString).length)
           ),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: full) {
            let title = String(full[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleTitle(title) {
                return Hit(value: title, keywords: ["TICKETS"], extractKind: .entire, extractKeyword: "")
            }
        }

        // Line immediately above a weekday session line (skip labels like SHOWING).
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^([^\n]{2,80})\n(?=(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b)"#
        ) {
            let ns = full as NSString
            let matches = re.matches(in: full, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges > 1 {
                guard let r = Range(match.range(at: 1), in: full) else { continue }
                let title = String(full[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlausibleTitle(title) {
                    return Hit(value: title, keywords: [], extractKind: .entire, extractKeyword: "")
                }
            }
        }

        // Last: line above booking code + Seats (only if it still looks like a title).
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
        return nil
    }

    /// Prefer a plausible title near SHOWING (above first, then below before the session clock).
    private static func titleNearShowingLabel(in full: String) -> Hit? {
        let lower = full.lowercased()
        guard let showing = lower.range(of: "showing") else { return nil }
        let before = String(full[..<showing.lowerBound])
        let after = String(full[showing.upperBound...])

        let beforeLines = before
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let afterLines = after
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var candidates: [(line: String, score: Int)] = []

        // Closest lines above SHOWING score higher.
        for (offset, line) in beforeLines.reversed().prefix(16).enumerated() {
            guard isPlausibleTitle(line) else { continue }
            candidates.append((line, 70 - offset + titleQualityBonus(line)))
        }
        // Lines under SHOWING until we hit schedule / cinema / seat chrome.
        // Event web PDFs often put the real title here (chrome sits above SHOWING).
        for (offset, line) in afterLines.prefix(10).enumerated() {
            if looksLikeSessionOrVenueLine(line) { break }
            guard isPlausibleTitle(line) else { continue }
            candidates.append((line, 110 - offset + titleQualityBonus(line)))
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        return Hit(
            value: best.line,
            keywords: ["SHOWING"],
            extractKind: .entire,
            extractKeyword: ""
        )
    }

    private static func looksLikeSessionOrVenueLine(_ line: String) -> Bool {
        if MovieTicketPDFRecognitionService.dateOnly(from: line) != nil { return true }
        if MovieTicketPDFRecognitionService.clockOnly(from: line) != nil { return true }
        if line.range(of: #"(?i)\bCinema\s+\d+\b"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"(?i)\bScreen\s+\d+\b"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"(?i)\bRow\s+[A-Z]\s+Seat\b"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"(?i)^X\s*\d+\b"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"(?i)Ends?\s+at\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Boost real film titles; demote generic UI phrases that slipped past the label list.
    private static func titleQualityBonus(_ line: String) -> Int {
        var score = 0
        let words = line.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 2 { score += 8 }
        if words.count >= 3 { score += 10 }
        if line.range(
            of: #"^(The|A|An)\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            score += 20
        }
        if line.count >= 12 { score += 4 }
        if line.count <= 4 { score -= 20 }
        // Single generic two-word UI labels stay weak even if not blacklisted yet.
        if words.count == 2, line.allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "," }) {
            score -= 5
        }
        return score
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
        // IMAX venue line before generic "Cinema N" — Event emails often contain both
        // (venue + unrelated Cinema digit noise). Prefer the explicit IMAX hall.
        if let m = firstRegex(in: full, #"(?i)\bIMAX\s+Sydney\b"#) {
            return Hit(value: m, keywords: ["IMAX Sydney"], extractKind: .entire, extractKeyword: "")
        }
        // Event / Dendy: "X 1 Cinema 3 Row G Seat 7"
        if let m = firstRegex(in: full, #"(?i)\bCinema\s+\d+\b"#) {
            let cleaned = m.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return Hit(value: cleaned, keywords: ["Cinema"], extractKind: .entire, extractKeyword: "")
        }
        return nil
    }

    private static func detectSeat(in full: String) -> Hit? {
        if full.range(of: #"(?i)\bunallocated\b"#, options: .regularExpression) != nil {
            return Hit(value: "Unallocated", keywords: ["Seats"], extractKind: .entire, extractKeyword: "")
        }
        // Event / Dendy: "Row G Seat 7"
        if let m = firstRegex(in: full, #"(?i)\bRow\s+([A-Z])\s+Seat\s+(\d{1,2})\b"#) {
            if let re = try? NSRegularExpression(pattern: #"(?i)\bRow\s+([A-Z])\s+Seat\s+(\d{1,2})\b"#),
               let match = re.firstMatch(
                in: full,
                range: NSRange(location: 0, length: (full as NSString).length)
               ),
               match.numberOfRanges > 2,
               let r1 = Range(match.range(at: 1), in: full),
               let r2 = Range(match.range(at: 2), in: full) {
                let seat = "\(full[r1])\(full[r2])"
                return Hit(value: seat, keywords: ["Seat", "Row"], extractKind: .entire, extractKeyword: "")
            }
            _ = m
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
        // Event / IMAX: "1x Cinebuzz - IMAX" — prefer before Member/Adult prose matches.
        if let nx = firstRegex(in: full, #"(?i)\d+x\s+[^\n]{3,60}"#) {
            let trimmed = nx.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 4, isPlausibleTicketProductLine(trimmed) {
                return Hit(value: trimmed, keywords: [], extractKind: .entire, extractKeyword: "")
            }
        }
        // Product lines like "Retro 3 Pass Redemption x 1" (qty after the name).
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^([^\n]{4,70}?\bx\s*\d+)\s*$"#
        ) {
            let ns = full as NSString
            let matches = re.matches(in: full, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges > 1 {
                guard let r = Range(match.range(at: 1), in: full) else { continue }
                let trimmed = String(full[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlausibleTicketProductLine(trimmed) {
                    return Hit(value: trimmed, keywords: [], extractKind: .entire, extractKeyword: "")
                }
            }
        }
        // Named ticket categories (Adult Event, Child, …) — same line only.
        if let m = firstRegex(
            in: full,
            #"(?i)\b((?:Adult|Child|Senior|Student|Concession|Member|Family)(?:[ \t]+\w+){0,3})\b"#
        ) {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleNamedTicketType(trimmed) {
                return Hit(value: trimmed, keywords: [], extractKind: .entire, extractKeyword: "")
            }
        }
        return nil
    }

    /// Ticket / pass product lines — not film titles or usher instructions.
    private static func isPlausibleTicketProductLine(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, t.count <= 80 else { return false }
        let lower = t.lowercased()
        if lower.contains("usher") || lower.contains("popcorn") || lower.contains("hey ")
            || lower.contains("your ticket to") || lower.contains("proceed")
            || lower.contains("booking -") || lower.contains("show this") {
            return false
        }
        if t.range(of: #"(?i)\bx\s*\d+\b"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"(?i)\d+x\b"#, options: .regularExpression) != nil { return true }
        return lower.contains("pass") || lower.contains("redemption") || lower.contains("voucher")
    }

    /// Reject instructional copy like "member as you exit" while keeping "Adult Event".
    private static func isPlausibleNamedTicketType(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        let upper = trimmed.uppercased()
        if upper.contains("CINEMA") { return false }
        let lower = trimmed.lowercased()
        if lower.contains(" as you ") || lower.contains(" please ") || lower.contains(" click ") {
            return false
        }
        if lower.hasSuffix(" exit") || lower.contains(" thank ") { return false }
        return true
    }

    private static func detectPrice(page: PDFPage, full: String) -> Hit? {
        if let total = MovieTicketPDFRecognitionService.pageTotalCurrency(from: page)
            ?? MovieTicketPDFRecognitionService.totalCurrency(fromPageText: full) {
            return Hit(
                value: total,
                keywords: ["Total"],
                extractKind: .currency,
                extractKeyword: "Total"
            )
        }
        // Whole dollars (Orpheum `Total 29`) and classic `$N.NN`.
        if let m = firstRegex(in: full, #"(?i)Total(?:\s+cost)?\s*:?\s*(\$?\d+(?:\.\d{1,2})?)"#) {
            return Hit(
                value: m,
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

    private static func detectStartTime(in full: String, page: PDFPage, includeDate: Bool) -> Hit? {
        if includeDate,
           let session = MovieTicketPDFRecognitionService.pageSessionDateTime(from: page),
           !session.isEmpty {
            return Hit(
                value: session,
                keywords: ["Time", "SESSION DATE"],
                extractKind: .entire,
                extractKeyword: ""
            )
        }
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
                // SHOWING anchors Dendy web tickets; SESSION DATE is IMAX-style.
                keywords: ["SHOWING", "SESSION DATE", "Time"],
                extractKind: .entire,
                extractKeyword: ""
            )
        }
        return nil
    }

    private static func detectEndTime(in full: String) -> Hit? {
        // Dendy / Event: "Ends at 8:52 pm" or "(Ends at 8:52 pm)"
        if let clock = firstRegex(
            in: full,
            #"(?i)Ends?\s+at\s+(\d{1,2}:\d{2}\s*[AP]M)"#
        ) {
            let normalized = MovieTicketPDFRecognitionService.clockOnly(from: clock)
                ?? clock.trimmingCharacters(in: .whitespacesAndNewlines)
            return Hit(
                value: normalized,
                keywords: ["Ends at", "Ends"],
                extractKind: .entire,
                extractKeyword: "Ends at"
            )
        }
        // Orpheum-style "Until 10:36 pm"
        if let clock = firstRegex(
            in: full,
            #"(?i)Until\s+(\d{1,2}:\d{2}\s*[AP]M)"#
        ) {
            let normalized = MovieTicketPDFRecognitionService.clockOnly(from: clock)
                ?? clock.trimmingCharacters(in: .whitespacesAndNewlines)
            return Hit(
                value: normalized,
                keywords: ["Until"],
                extractKind: .entire,
                extractKeyword: "Until"
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
        if t.range(of: #"(?i)^Cinema\s+\d+$"#, options: .regularExpression) != nil {
            return false
        }
        let labels: Set<String> = [
            "SHOWING", "SESSION", "SESSION DATE", "SESSION TIME", "TICKETS", "ORDERS",
            "HOME", "LOGOUT", "TAX INVOICE", "INVOICE", "ORDER", "ORDERS",
            "ACCOUNT OVERVIEW", "ACCOUNT", "OVERVIEW", "MY ACCOUNT", "MY TICKETS",
            "ORDER HISTORY", "ORDER DETAILS", "PAYMENT", "CHECKOUT", "CART",
            "SIGN IN", "SIGN OUT", "LOG IN", "LOG OUT", "PROFILE", "SETTINGS",
            "HELP", "SUPPORT", "MEMBERSHIP", "GIFT CARDS", "LOCATIONS",
            "CURRENT UPCOMING", "CURRENT", "UPCOMING"
        ]
        if labels.contains(upper) || upper.hasPrefix("THANK YOU") || upper.contains("% OFF") {
            return false
        }
        // Ticket / pass product lines are not film titles.
        if looksLikeTicketProductLine(t) { return false }
        // Incomplete PDF wrap fragment ("35MM J" before "OINT…").
        if let last = t.split(whereSeparator: { $0.isWhitespace }).map(String.init).last,
           last.count == 1, last.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) {
            return false
        }
        // Strip leading emoji / symbols before greeting checks ("👋 Hi, XIAOYU").
        let letterStart = String(t.drop(while: { !$0.isLetter && !$0.isNumber }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let letterUpper = letterStart.uppercased()
        // Web chrome / account greeting / nav.
        if letterUpper.hasPrefix("HI,") || letterUpper.hasPrefix("HI ")
            || letterUpper.hasPrefix("HEY ") || letterUpper.hasPrefix("HEY,")
            || upper.contains("LOGOUT") || upper.contains("TAX INVOICE")
            || upper.hasPrefix("X 1 ") || upper.contains("OVERVIEW")
            || upper.contains("ACCOUNT") || upper.hasPrefix("ORDER ")
            || upper.hasSuffix(" OVERVIEW") || upper.contains("MEMBERSHIP")
            || upper.contains("VIEW & MANAGE") || upper.contains("VIEW AND MANAGE")
            || upper.contains("CURRENT UPCOMING") || upper.hasPrefix("CURRENT ")
            || upper.contains("USHER") || upper.contains("POPCORN")
            || t.contains("👋") {
            return false
        }
        // Must contain at least one letter (reject icon-only / digit-only runs).
        guard t.contains(where: \.isLetter) else { return false }
        // Reject lines that are mostly emoji / symbols.
        let letterCount = t.filter(\.isLetter).count
        if letterCount < 3 { return false }
        return true
    }

    private static func looksLikeTicketProductLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if t.range(of: #"(?i)\bx\s*\d+\s*$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"(?i)^\d+x\b"#, options: .regularExpression) != nil { return true }
        if lower.contains("redemption") || lower.contains(" voucher") { return true }
        if lower.contains(" pass ") || lower.hasSuffix(" pass") || lower.hasPrefix("pass ") {
            return true
        }
        return false
    }

    private static func firstRegex(in text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}
