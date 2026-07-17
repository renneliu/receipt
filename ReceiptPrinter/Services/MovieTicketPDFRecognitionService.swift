import Foundation
import PDFKit
import CoreGraphics

enum MovieTicketPDFRecognitionError: LocalizedError {
    case cannotOpenPDF
    case emptyPage
    case noTextInRegion

    var errorDescription: String? {
        switch self {
        case .cannotOpenPDF: return "无法打开 PDF（请使用文字型 PDF）"
        case .emptyPage: return "PDF 页面为空"
        case .noTextInRegion: return "选区未抽到文本"
        }
    }
}

/// Shared geometry: relative rects are in **display** space (top-left, after page.rotation).
enum MovieTicketPDFGeometry {
    static let boxType: PDFDisplayBox = .cropBox

    static func normalizedRotation(_ page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    /// Visible page size after applying `/Rotate` (matches `PDFPage.thumbnail`).
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: boxType)
        let rot = normalizedRotation(page)
        if rot == 90 || rot == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    /// Convert a top-left relative rect (0…1 over displaySize) into PDFKit page space for `selection(for:)`.
    static func pdfRect(from rel: MovieTicketRelativeRect, page: PDFPage) -> CGRect {
        let box = page.bounds(for: boxType)
        let rot = normalizedRotation(page)
        let disp = displaySize(of: page)
        let r = rel.clamped()

        let dx = CGFloat(r.x) * disp.width
        let dy = CGFloat(r.y) * disp.height
        let dw = CGFloat(r.width) * disp.width
        let dh = CGFloat(r.height) * disp.height

        // Bottom-left version of the same display rect (y up).
        let blX = dx
        let blY = disp.height - dy - dh
        let blW = dw
        let blH = dh

        let pageRect: CGRect
        switch rot {
        case 90:
            pageRect = CGRect(
                x: box.minX + blY,
                y: box.minY + blX,
                width: blH,
                height: blW
            )
        case 180:
            pageRect = CGRect(
                x: box.minX + (box.width - blX - blW),
                y: box.minY + (box.height - blY - blH),
                width: blW,
                height: blH
            )
        case 270:
            pageRect = CGRect(
                x: box.minX + (box.width - blY - blH),
                y: box.minY + (box.height - blX - blW),
                width: blH,
                height: blW
            )
        default:
            pageRect = CGRect(
                x: box.minX + blX,
                y: box.minY + blY,
                width: blW,
                height: blH
            )
        }
        let expanded = pageRect.insetBy(dx: -2, dy: -2)
        let clipped = expanded.intersection(box)
        return clipped.isNull ? pageRect.intersection(box) : clipped
    }

    /// Aspect-fit rectangle for drawing `imageSize` inside `bounds`.
    static func aspectFitContentRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: bounds.minX + (bounds.width - w) * 0.5,
            y: bounds.minY + (bounds.height - h) * 0.5,
            width: w,
            height: h
        )
    }
}

enum MovieTicketPDFRecognitionService {
    static func extractPlainText(from url: URL, maxPages: Int = 3) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw MovieTicketPDFRecognitionError.cannotOpenPDF }
        var parts: [String] = []
        let count = min(doc.pageCount, maxPages)
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            parts.append(page.string ?? "")
        }
        return parts.joined(separator: "\n")
    }

    static func matchRules(text: String, rules: [MovieTicketPDFRule]) -> [MovieTicketPDFRule] {
        let lower = text.lowercased()
        return rules.filter { rule in
            rule.detectorKeywords.contains { key in
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { return false }
                return lower.contains(k.lowercased())
            }
        }
    }

    static func pageSize(doc: PDFDocument, pageIndex: Int) -> CGSize? {
        guard let page = doc.page(at: pageIndex) else { return nil }
        return MovieTicketPDFGeometry.displaySize(of: page)
    }

    static func extractText(from url: URL, region: MovieTicketPDFRegion) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw MovieTicketPDFRecognitionError.cannotOpenPDF }
        guard let page = doc.page(at: region.pageIndex) else { throw MovieTicketPDFRecognitionError.emptyPage }
        let rel = region.rect.clamped()

        // Cross-page-size strategy:
        // 0) Hall: page-wide "Screen N" (label text layer is often broken)
        // 1) Keyword anchor on full page (robust when margins/aspect differ)
        // 2) Relative rect scaled to this page
        // 3) Expanded relative rect for slight layout drift
        var text = ""
        var pathUsed = "none"

        // Hall: page-wide "Screen N" is stable across PDF page sizes.
        if region.fieldKind == .hall,
           let screen = extractHallScreenFromPage(page) {
            text = screen
            pathUsed = "pageScreen"
        }

        // Price: page-wide "Total … $N.NN" is stable across page sizes (rect drifts badly).
        if text.isEmpty, region.fieldKind == .ticketPrice,
           region.extractKind == .currency || region.extractKind == .entire || !region.extractSample.isEmpty,
           let total = extractTotalCurrencyFromPage(page) {
            text = total
            pathUsed = "pageTotal"
        }

        if text.isEmpty, region.captureMode == .withKeywords || !region.regionKeywords.isEmpty {
            var keywords = region.regionKeywords
            if region.fieldKind == .movieTitle {
                keywords.append(contentsOf: ["YOUR TICKET TO", "YOUR TICKET", "TICKET TO"])
            }
            if region.fieldKind == .hall {
                keywords.append(contentsOf: ["CINEMA NUMBER", "CINEMA NUMER"])
            }
            if region.fieldKind == .ticketPrice {
                keywords.append(contentsOf: ["Total", "TOTAL"])
            }
            // Prefer strong locate anchors over weak ones like GST.
            if !region.extractKeyword.isEmpty {
                keywords.insert(region.extractKeyword, at: 0)
            }
            if let anchored = extractByKeywordAnchor(on: page, keywords: keywords, fieldKind: region.fieldKind) {
                let cleaned = finalizeFieldValue(anchored, for: region.fieldKind)
                if isPlausibleFieldValue(cleaned, for: region.fieldKind) {
                    text = cleaned
                    pathUsed = "keyword"
                }
            }
        }

        if text.isEmpty {
            let pdfRect = MovieTicketPDFGeometry.pdfRect(from: rel, page: page)
            if !pdfRect.isNull, !pdfRect.isEmpty,
               let selection = page.selection(for: pdfRect) {
                let raw = textFromSelection(selection)
                if !raw.isEmpty {
                    var refined = (region.captureMode == .withKeywords)
                        ? refineWithKeywords(raw, keywords: region.regionKeywords, allowNextLine: true)
                        : raw
                    refined = finalizeFieldValue(refined, for: region.fieldKind)
                    if isPlausibleFieldValue(refined, for: region.fieldKind) || region.captureMode == .positionOnly {
                        text = refined
                        pathUsed = "rect"
                    }
                }
            }
        }

        if text.isEmpty {
            let expanded = MovieTicketRelativeRect(
                x: rel.x - rel.width * 0.25,
                y: rel.y - rel.height * 0.25,
                width: rel.width * 1.5,
                height: rel.height * 1.5
            ).clamped()
            let pdfRect = MovieTicketPDFGeometry.pdfRect(from: expanded, page: page)
            if !pdfRect.isNull, !pdfRect.isEmpty,
               let selection = page.selection(for: pdfRect) {
                let raw = textFromSelection(selection)
                if !raw.isEmpty {
                    var refined = (region.captureMode == .withKeywords)
                        ? refineWithKeywords(raw, keywords: region.regionKeywords, allowNextLine: true)
                        : raw
                    refined = finalizeFieldValue(refined, for: region.fieldKind)
                    if isPlausibleFieldValue(refined, for: region.fieldKind) || region.fieldKind != .hall {
                        text = refined
                        pathUsed = "expanded"
                    }
                }
            }
        }

        if text.isEmpty {
            throw MovieTicketPDFRecognitionError.noTextInRegion
        }

        // pageTotal already is the currency amount — skip filter that may re-anchor on GST.
        let filtered: String
        if pathUsed == "pageTotal" {
            filtered = text
        } else {
            filtered = applyExtractFilter(
                text,
                kind: region.extractKind,
                keyword: preferredExtractKeyword(region)
            )
        }
        let rawValue = filtered.isEmpty ? text : filtered
        return applyValueMappings(rawValue, mappings: region.valueMappings)
    }

    /// Rewrite extracted text using user-defined print aliases (longest match wins).
    static func applyValueMappings(
        _ text: String,
        mappings: [MovieTicketPDFValueMapping]
    ) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return source }
        let rules = mappings
            .map {
                (
                    match: $0.match.trimmingCharacters(in: .whitespacesAndNewlines),
                    replacement: $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.match.isEmpty }
            .sorted { $0.match.count > $1.match.count }
        guard !rules.isEmpty else { return source }
        let lower = source.lowercased()
        for rule in rules {
            if lower == rule.match.lowercased()
                || lower.contains(rule.match.lowercased()) {
                return rule.replacement.isEmpty ? source : rule.replacement
            }
        }
        return source
    }

    /// Prefer Total over weak anchors like GST for currency fields.
    private static func preferredExtractKeyword(_ region: MovieTicketPDFRegion) -> String {
        let key = region.extractKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if region.extractKind == .currency || region.fieldKind == .ticketPrice {
            let weak: Set<String> = ["GST", "ABN", "INC", "FEE"]
            if key.isEmpty || weak.contains(key.uppercased()) {
                return "Total"
            }
        }
        return key
    }

    /// Find Total (inc. GST) $N.NN on the full page — independent of page size / rect.
    private static func extractTotalCurrencyFromPage(_ page: PDFPage) -> String? {
        guard let full = page.string, !full.isEmpty else { return nil }
        let patterns = [
            #"(?i)Total(?:\s*\([^)]*\))?\s*(\$?\d{1,3}(?:,\d{3})*\.\d{2})"#,
            #"(?i)Total\s+(?:inc\.?\s*)?GST\s*(\$?\d{1,3}(?:,\d{3})*\.\d{2})"#
        ]
        let ns = full as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: full, range: fullRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: full) else { continue }
            return String(full[range])
        }
        // Fallback: amount immediately after the word Total (flexible glyph spacing).
        if let range = firstMatchRange(of: "Total", in: full) {
            let after = String(full[range.upperBound...].prefix(80))
            if let amount = firstCurrencyAmount(in: after) {
                return amount
            }
        }
        return nil
    }

    /// Learn extract features from a user-typed sample that appears in the region preview.
    static func analyzeExtractSample(_ sample: String, in fullText: String) -> MovieTicketPDFExtractAnalysis {
        let sampleTrim = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sampleTrim.isEmpty else {
            return MovieTicketPDFExtractAnalysis(
                kind: .entire,
                keyword: "",
                sample: "",
                summary: "未填写 → 保留选区内全部文字"
            )
        }
        guard !full.isEmpty else {
            return MovieTicketPDFExtractAnalysis(
                kind: classifySampleShape(sampleTrim),
                keyword: "",
                sample: sampleTrim,
                summary: "预览为空，仅按样例形态：\(classifySampleShape(sampleTrim).displayName)"
            )
        }

        guard let matchRange = findSampleRange(sampleTrim, in: full) else {
            let kind = classifySampleShape(sampleTrim)
            return MovieTicketPDFExtractAnalysis(
                kind: kind,
                keyword: "",
                sample: sampleTrim,
                summary: "预览中未找到「\(sampleTrim)」，将按\(kind.displayName)形态提取"
            )
        }

        let kind = classifySampleShape(sampleTrim)
        let keyword = inferAnchorKeyword(before: String(full[..<matchRange.lowerBound]))
        let preview = applyExtractFilter(full, kind: kind, keyword: keyword)
        let anchorPart = keyword.isEmpty ? "无锚定词" : "锚定「\(keyword)」"
        let previewPart = preview.isEmpty ? "未匹配" : preview
        return MovieTicketPDFExtractAnalysis(
            kind: kind,
            keyword: keyword,
            sample: sampleTrim,
            summary: "\(kind.displayName) · \(anchorPart) → \(previewPart)"
        )
    }

    private static func classifySampleShape(_ sample: String) -> MovieTicketPDFExtractKind {
        let t = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^\$?\d{1,3}(?:,\d{3})*\.\d{2}$"#, options: .regularExpression) != nil {
            return .currency
        }
        if t.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            return .digits
        }
        return .afterKeyword
    }

    private static func findSampleRange(_ sample: String, in full: String) -> Range<String.Index>? {
        if let r = full.range(of: sample, options: [.caseInsensitive, .diacriticInsensitive]) {
            return r
        }
        let stripped = sample.replacingOccurrences(of: "$", with: "")
        if stripped != sample,
           let r = full.range(of: stripped, options: [.caseInsensitive]) {
            // Prefer including a leading $ if present in full.
            if r.lowerBound > full.startIndex {
                let prev = full.index(before: r.lowerBound)
                if full[prev] == "$" {
                    return prev..<r.upperBound
                }
            }
            return r
        }
        return nil
    }

    private static func inferAnchorKeyword(before: String) -> String {
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Higher score wins. "GST" is weak (often inside "Total (inc. GST)").
        let known: [(String, Int)] = [
            ("Total", 100),
            ("Subtotal", 95),
            ("Amount", 90),
            ("Booking Number", 85),
            ("Booking Fee", 70),
            ("SESSION DATE & TIME", 80),
            ("SESSION DATE", 75),
            ("CINEMA NUMBER", 75),
            ("Ticket", 40),
            ("Screen", 40),
            ("GST", 15),
            ("ABN", 10)
        ]
        let upper = trimmed.uppercased()
        var bestLabel = ""
        var bestScore = Int.min
        var bestPos = -1
        for (label, score) in known {
            if let r = upper.range(of: label.uppercased(), options: [.backwards]) {
                let pos = upper.distance(from: upper.startIndex, to: r.lowerBound)
                // Prefer higher score; if tied, prefer the label closer to the sample (later pos).
                if score > bestScore || (score == bestScore && pos > bestPos) {
                    let start = trimmed.index(trimmed.startIndex, offsetBy: pos)
                    let end = trimmed.index(trimmed.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: r.upperBound))
                    bestLabel = String(trimmed[start..<end])
                    bestScore = score
                    bestPos = pos
                }
            }
        }
        if !bestLabel.isEmpty { return bestLabel }

        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { tok in
                let letters = tok.filter(\.isLetter)
                return letters.count >= 2
            }
        guard !tokens.isEmpty else { return "" }
        if let last = tokens.last, last.count >= 3 {
            return last.trimmingCharacters(in: .punctuationCharacters)
        }
        return Array(tokens.suffix(min(3, tokens.count)))
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// Slice located region text down to the configured extract kind.
    static func applyExtractFilter(
        _ text: String,
        kind: MovieTicketPDFExtractKind,
        keyword: String
    ) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return source }
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped: String = {
            guard !key.isEmpty, let range = firstMatchRange(of: key, in: source) else {
                return source
            }
            return String(source[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        switch kind {
        case .entire:
            return source
        case .afterKeyword:
            guard !key.isEmpty else { return source }
            if let range = firstMatchRange(of: key, in: source) {
                let after = source[range.upperBound...]
                let sameLine = String(after.prefix(while: { $0 != "\n" && $0 != "\r" }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sameLine.isEmpty {
                    // Prefer first currency/digits token if present (sample was usually a short value).
                    if let amount = firstCurrencyAmount(in: sameLine) { return amount }
                    if let digits = firstDigitRun(in: sameLine) { return digits }
                    return sameLine
                }
            }
            return scoped
        case .currency:
            if let amount = firstCurrencyAmount(in: scoped) ?? (!key.isEmpty ? nil : lastCurrencyAmount(in: source)) {
                return amount
            }
            return scoped.isEmpty ? source : scoped
        case .digits:
            if let digits = firstDigitRun(in: scoped) ?? (!key.isEmpty ? nil : firstDigitRun(in: source)) {
                return digits
            }
            return scoped.isEmpty ? source : scoped
        }
    }

    private static func firstCurrencyAmount(in text: String) -> String? {
        currencyAmounts(in: text).first
    }

    private static func lastCurrencyAmount(in text: String) -> String? {
        currencyAmounts(in: text).last
    }

    private static func currencyAmounts(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})"#) else {
            return []
        }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstDigitRun(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// Find "Screen N" on the page (Ritz-style cinema number). Independent of page size.
    private static func extractHallScreenFromPage(_ page: PDFPage) -> String? {
        guard let full = page.string, !full.isEmpty else { return nil }
        let ns = full as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        // Prefer Screen that follows a broken/spaced "CINEMA NUMBER" label (B often missing).
        if let re = try? NSRegularExpression(
            pattern: #"(?i)C\s*I\s*N\s*E\s*M\s*A[\s\S]{0,80}?(\bScreen\s+\d+\b)"#
        ),
           let match = re.firstMatch(in: full, range: fullRange),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: full) {
            return String(full[range])
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)\bScreen\s+\d+\b"#),
           let match = re.firstMatch(in: full, range: fullRange),
           let range = Range(match.range, in: full) {
            return String(full[range])
        }
        return nil
    }

    /// Normalize + field-specific cleanup.
    private static func finalizeFieldValue(_ raw: String, for kind: MovieTicketFieldKind) -> String {
        var text = normalizeExtractedText(stripLeadingTrivialTokens(raw), for: kind)
        if kind == .hall {
            text = refineHallValue(text)
        }
        return text
    }

    /// Prefer "Screen N"; strip "CINEMA NUMBER" label fragments and trailing glyph noise.
    private static func refineHallValue(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let re = try? NSRegularExpression(pattern: #"(?i)\bScreen\s+\d+\b"#) {
            let ns = trimmed as NSString
            if let match = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               let range = Range(match.range, in: trimmed) {
                return String(trimmed[range])
            }
        }
        var tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let labelBits: Set<String> = [
            "CINEM", "CINEMA", "NUM", "NUMER", "NUMBER", "A", "ER", "BER", "UM"
        ]
        while let first = tokens.first {
            let letters = String(first.uppercased().filter(\.isLetter))
            if labelBits.contains(letters) {
                tokens.removeFirst()
                continue
            }
            break
        }
        while let last = tokens.last, last.count == 1, last.first?.isLetter == true {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fix PDFKit glyph-spacing artifacts: "PALAC E" → "PALACE", "SE CURITY" → "SECURITY", "颐和 园" → "颐和园".
    private static func normalizeExtractedText(_ raw: String, for fieldKind: MovieTicketFieldKind? = nil) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove spaces between CJK characters.
        if let re = try? NSRegularExpression(pattern: #"(\p{Han})\s+(\p{Han})"#) {
            var prev = ""
            while prev != text {
                prev = text
                text = re.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: "$1$2"
                )
            }
        }
        // Collapse Latin fragments left by per-glyph PDF spacing.
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var i = 0
        while i < tokens.count - 1 {
            let a = tokens[i]
            let b = tokens[i + 1]
            if shouldMergeLatinFragments(a, b) {
                tokens[i] = a + b
                tokens.remove(at: i + 1)
                continue
            }
            i += 1
        }
        let joined = tokens.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch fieldKind {
        case .startTime, .endTime, .timeRange:
            return refineDateTimeValue(joined)
        default:
            return cutAtSectionLabel(joined)
        }
    }

    /// Extract session date+time value; never strip the clock portion.
    private static func refineDateTimeValue(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{1,2}\s+[A-Za-z]{3,9},?\s+\d{1,2}:\d{2}\s*(?:[AP]M|am|pm)\b"#,
            #"(?i)\d{1,2}\s+[A-Za-z]{3,9},?\s+\d{1,2}:\d{2}\s*(?:[AP]M|am|pm)\b"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = trimmed as NSString
            if let match = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               let range = Range(match.range, in: trimmed) {
                return String(trimmed[range])
            }
        }
        return trimmed
    }

    private static func containsClockTime(_ s: String) -> Bool {
        s.range(
            of: #"\d{1,2}:\d{2}\s*(?:[AP]M|am|pm)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// True when `a`+`b` are mid-word splits in ALL-CAPS PDF glyph runs
    /// (e.g. SE+CURITY, TESTA+MENT, PALAC+E). Never merge title-case English words.
    private static func shouldMergeLatinFragments(_ a: String, _ b: String) -> Bool {
        guard isLatinWordToken(a), isLatinWordToken(b) else { return false }
        // Only fix ALL-CAPS fragments from PDFKit; leave "Ann Lee" / "The Testament" alone.
        guard isAllCapsLatin(a), isAllCapsLatin(b) else { return false }
        let aUp = a.uppercased()
        let bUp = b.uppercased()
        let stop: Set<String> = [
            "AN", "THE", "OF", "AND", "OR", "FOR", "TO", "IN", "ON", "AT", "BY", "VS", "AS", "IF"
        ]
        let realWords: Set<String> = [
            "SHOWING", "FEBRUARY", "JANUARY", "MARCH", "APRIL", "JUNE", "JULY", "AUGUST",
            "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER", "ENDS", "STARTS", "SCREEN",
            "CINEMA", "SESSION", "TICKETS", "SEATS", "MEMBER", "ADULT", "CHILD"
        ]

        // Single-letter tail first (before stop-list): "CINEM"+"A", "ARE"+"A", "PALAC"+"E"
        if b.count == 1 {
            if bUp == "A" || bUp == "I" {
                return a.count >= 3 && a.count <= 5
            }
            return a.count >= 2
        }
        if stop.contains(aUp) || stop.contains(bUp) || realWords.contains(bUp) { return false }

        // 2–3 letter ALL-CAPS head: "SE"+"CURITY" (not a lone "S")
        if a.count >= 2, a.count <= 3, b.count >= 2 {
            return true
        }
        // Suffix continuation: "TESTA"+"MENT"
        let suffixes = ["MENT", "TION", "SION", "NESS", "ALLY", "ENCE", "ANCE", "TURE", "HOOD", "SHIP"]
        if a.count >= 4, a.count <= 6, suffixes.contains(where: { bUp == $0 || bUp.hasPrefix($0) }) {
            return true
        }
        return false
    }

    private static func isAllCapsLatin(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    private static func isLatinWordToken(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") }
    }

    /// Cut title before section headings, dates, or show times.
    private static func cutAtSectionLabel(_ text: String) -> String {
        let patterns = [
            #"\bC\s*I\s*N\s*E\s*M\s*A\b"#,
            #"\bS\s*E\s*S\s*S\s*I\s*O\s*N\b"#,
            #"\bT\s*I\s*C\s*K\s*E\s*T\s*S\b"#,
            #"\bS\s*E\s*A\s*T\s*S\b"#,
            #"\bS\s*C\s*A\s*N\s+C\s*O\s*D\s*E\b"#,
            #"\bB\s*O\s*O\s*K\s*I\s*N\s*G\s+N\s*U\s*M"#,
            #"(?i)\b(January|February|March|April|May|June|July|August|September|October|November|December)\b"#,
            #"(?i)\bEnds\s+at\b"#,
            #"(?i)\b\d{1,2}:\d{2}\s*(am|pm)\b"#,
            #"(?i)\b\d{1,2}(st|nd|rd|th),?\b"#
        ]
        var cutIndex: String.Index? = nil
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = text as NSString
            if let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               match.range.location != NSNotFound,
               match.range.location > 0,
               let idx = Range(match.range, in: text)?.lowerBound {
                if cutIndex == nil || idx < cutIndex! {
                    cutIndex = idx
                }
            }
        }
        var result = text
        if let cut = cutIndex {
            result = String(text[..<cut])
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop leading schedule verbs ("SHOWING", "S SHOWING", "SSHOWING").
        if let re = try? NSRegularExpression(pattern: #"^(?i)S?\s*SHOWING\s+"#) {
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Find keyword on the whole page, then take value after it (same line + continuation lines).
    private static func extractByKeywordAnchor(
        on page: PDFPage,
        keywords: [String],
        fieldKind: MovieTicketFieldKind? = nil
    ) -> String? {
        let keys = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty, let full = page.string, !full.isEmpty else { return nil }
        let ordered = keys.sorted { $0.count > $1.count }
        for key in ordered {
            guard let range = firstMatchRange(of: key, in: full) else { continue }
            let afterKey = full[range.upperBound...]
            let value = collectValueLines(after: afterKey, for: fieldKind)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// PDFKit often inserts newlines mid-value. Keep reading until a section label.
    private static func collectValueLines(
        after afterKey: Substring,
        for fieldKind: MovieTicketFieldKind? = nil,
        maxLines: Int = 6
    ) -> String {
        let rawLines = afterKey.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        var parts: [String] = []
        for line in rawLines {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let t = stripLeadingTrivialTokens(trimmed)
            if t.isEmpty {
                if parts.isEmpty { continue }
                break
            }
            if isSectionLabel(t) { break }
            // Later lines that are pure schedule shouldn't append to the title.
            if !parts.isEmpty, isScheduleLine(t) { break }
            parts.append(t)
            // Time fields: one line with clock time is complete; ignore trailing glyph noise ("B").
            if fieldKind == .startTime || fieldKind == .endTime || fieldKind == .timeRange,
               containsClockTime(t) {
                return normalizeExtractedText(t, for: fieldKind)
            }
            let joined = joinTitleParts(parts)
            // Hall values like "Screen 2" are complete on their own.
            let hall = refineHallValue(joined)
            if hall.range(of: #"^Screen\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return hall
            }
            // Title with year in parentheses is usually complete.
            if joined.contains("("), joined.contains(")"), joined.count >= 8 {
                return normalizeExtractedText(joined, for: fieldKind)
            }
            if parts.count >= maxLines { break }
        }
        return normalizeExtractedText(joinTitleParts(parts), for: fieldKind)
    }

    private static func joinTitleParts(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }
        var result = parts[0]
        let realWords: Set<String> = [
            "SHOWING", "FEBRUARY", "JANUARY", "MARCH", "APRIL", "JUNE", "JULY", "AUGUST",
            "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER", "ENDS", "STARTS", "SCREEN",
            "CINEMA", "SESSION", "TICKETS", "SEATS", "THE", "OF", "AND"
        ]
        for i in 1..<parts.count {
            let next = parts[i]
            // Glue only "SUMMER P"+"ALAC…" style mid-word wraps — never "S"+"SHOWING".
            let lastTok = result.split(whereSeparator: { $0.isWhitespace }).map(String.init).last ?? ""
            let nextHead = String(next.prefix(while: { $0.isLetter }))
            let shouldGlue =
                isAllCapsLatin(lastTok) && lastTok.count == 1
                && isAllCapsLatin(nextHead)
                && nextHead.count >= 2 && nextHead.count <= 5
                && !realWords.contains(nextHead.uppercased())
            if shouldGlue {
                result += next
            } else if result.last?.isWhitespace == true {
                result += next
            } else {
                result += " " + next
            }
        }
        return result.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSectionLabel(_ s: String) -> Bool {
        // Compact spaces so "CINEM A NUM ER" still matches CINEMA…
        // Note: do NOT treat "Screen 2" as a label — that is the hall value.
        let compact = String(s.uppercased().filter { !$0.isWhitespace })
        let labels = [
            "CINEMANUMBER", "CINEMA", "SESSIONDATE", "SESSION", "TICKETS", "SEATS",
            "SCANCODE", "BOOKINGNUMBER", "BOOKINGFEE", "TAXINVOICE", "ADDTOAPPLE",
            "ADDTOGOOGLE"
        ]
        return labels.contains { compact.hasPrefix($0) }
    }

    /// Stop collecting title lines once schedule / showtime content begins.
    private static func isScheduleLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if let re = try? NSRegularExpression(
            pattern: #"(?i)^(S?\s*SHOWING\b)|(January|February|March|April|May|June|July|August|September|October|November|December)\b|\d{1,2}:\d{2}\s*(am|pm)\b|Ends\s+at\b"#
        ) {
            let ns = t as NSString
            if re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil {
                return true
            }
        }
        return false
    }

    /// Case-insensitive match allowing flexible whitespace between words and letters
    /// (PDFKit often yields "CINEM A NUM ER" for "CINEMA NUMBER").
    private static func firstMatchRange(of keyword: String, in full: String) -> Range<String.Index>? {
        var pattern = ""
        var pendingWordGap = false
        for ch in keyword {
            if ch.isWhitespace {
                pendingWordGap = true
                continue
            }
            if pendingWordGap {
                pattern += #"\s+"#
                pendingWordGap = false
            }
            pattern += NSRegularExpression.escapedPattern(for: String(ch))
            if ch.isLetter || ch.isNumber {
                pattern += #"\s*"#
            }
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return full.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive])
        }
        let ns = full as NSString
        guard let match = re.firstMatch(in: full, options: [], range: NSRange(location: 0, length: ns.length)),
              let range = Range(match.range, in: full) else { return nil }
        return range
    }

    private static func stripLeadingTrivialTokens(_ s: String) -> String {
        var tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Only strip label leftovers (e.g. "TO" after "YOUR TICKET"), never "A" —
        // that letter is often the end of AREA / PALACE splits on the next line.
        while let first = tokens.first, isLeadingLabelLeftover(first) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    private static func isLeadingLabelLeftover(_ s: String) -> Bool {
        let upper = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let leftovers: Set<String> = ["TO", "OF", "-", "–", "—", ":", "："]
        return leftovers.contains(upper)
    }

    private static func isTrivialToken(_ s: String) -> Bool {
        isLeadingLabelLeftover(s)
    }

    /// Leftovers like "TO", ":", "-" after matching a partial label.
    private static func isTrivialSameLineRemainder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        return isTrivialToken(t)
    }

    private static func isPlausibleFieldValue(_ text: String, for kind: MovieTicketFieldKind) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if isTrivialSameLineRemainder(t) { return false }
        switch kind {
        case .movieTitle:
            let upper = t.uppercased()
            if upper.contains("CINEMA NUMBER")
                || upper.contains("SESSION DATE")
                || upper.contains("SCAN CODE")
                || upper.hasPrefix("SCREEN ")
                || (upper.hasPrefix("CINEM") && upper.contains("SCREEN")) {
                return false
            }
            return t.count >= 4
        case .serialNumber:
            return t.count >= 4
        case .hall:
            // Reject date fragments from wrong rect on differently sized pages ("Thu 9").
            if t.range(
                of: #"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return false
            }
            if t.range(of: #"(?i)^Screen\s+\d+$"#, options: .regularExpression) != nil {
                return true
            }
            return t.count >= 2
        case .ticketType, .seatArea:
            return t.count >= 2
        default:
            return t.count >= 2
        }
    }

    private static func textFromSelection(_ selection: PDFSelection) -> String {
        let lines = selection.selectionsByLine()
        if !lines.isEmpty {
            let parts = lines.compactMap { line -> String? in
                let s = (line.string ?? "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            let shortGlyphRuns = parts.filter { $0.count == 1 }.count
            let joined: String
            if parts.count >= 5, shortGlyphRuns >= (parts.count * 3) / 4 {
                joined = parts.joined()
            } else {
                joined = parts.joined(separator: " ")
            }
            if !joined.isEmpty { return joined }
        }
        return (selection.string ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func refineWithKeywords(
        _ text: String,
        keywords: [String],
        allowNextLine: Bool = false
    ) -> String {
        let keys = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty else {
            return text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let source = text
        let lower = source.lowercased()
        let ordered = keys.sorted { $0.count > $1.count }
        for key in ordered {
            let k = key.lowercased()
            guard let range = lower.range(of: k) else { continue }
            let after = source[range.upperBound...]
            let sameLine = String(after.prefix(while: { $0 != "\n" && $0 != "\r" }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = after.drop(while: { $0 == "\n" || $0 == "\r" || $0.isWhitespace })
            let nextLine = String(rest.prefix(while: { $0 != "\n" && $0 != "\r" }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isTrivialSameLineRemainder(sameLine), allowNextLine, !nextLine.isEmpty {
                return nextLine
            }
            if !sameLine.isEmpty, !isTrivialSameLineRemainder(sameLine) {
                return sameLine
            }
            if allowNextLine, !nextLine.isEmpty {
                return nextLine
            }
            break
        }
        return text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractAllFields(from url: URL, rule: MovieTicketPDFRule) -> [MovieTicketFieldKind: String] {
        var out: [MovieTicketFieldKind: String] = [:]
        for region in rule.regions where region.fieldKind.isPDFExtractable {
            if let text = try? extractText(from: url, region: region), !text.isEmpty {
                out[region.fieldKind] = text
            }
        }
        return out
    }

    static func apply(fields: [MovieTicketFieldKind: String], to draft: inout MovieTicketDraft) {
        if let v = fields[.movieTitle], !v.isEmpty { draft.movieTitle = v }
        if let v = fields[.ticketType], !v.isEmpty { draft.ticketType = v }
        if let v = fields[.hall], !v.isEmpty { draft.hall = v }
        if let v = fields[.ticketPrice], !v.isEmpty {
            draft.ticketPrice = v.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        }
        if let v = fields[.serialNumber], !v.isEmpty {
            draft.serialNumber = v.replacingOccurrences(of: " ", with: "")
        }
        if let v = fields[.seatArea] {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased().contains("unallocated") {
                draft.seatModeUnallocated = true
                draft.seatArea = ""
            } else {
                draft.seatModeUnallocated = false
                draft.seatArea = trimmed
            }
        }
        if let v = fields[.startTime], let date = parseFlexibleDateTime(v) {
            draft.showDate = Calendar.current.startOfDay(for: date)
            draft.showStartTime = date
        }
    }

    private static func parseFlexibleDateTime(_ raw: String) -> Date? {
        let formats = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd h:mm a",
            "dd/MM/yyyy HH:mm",
            "dd/MM/yyyy h:mm a",
            "MM/dd/yyyy HH:mm",
            "MM/dd/yyyy h:mm a",
            "EEE d MMM, h:mma",
            "EEE d MMM, h:mm a",
            "EEE MMM d, yyyy h:mm a",
            "EEE MMM d yyyy h:mm a",
            "h:mma",
            "h:mm a",
            "HH:mm"
        ]
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: trimmed) {
                if format == "h:mm a" || format == "h:mma" || format == "HH:mm" {
                    let cal = Calendar.current
                    var c = cal.dateComponents([.year, .month, .day], from: Date())
                    let t = cal.dateComponents([.hour, .minute], from: d)
                    c.hour = t.hour
                    c.minute = t.minute
                    return cal.date(from: c)
                }
                return d
            }
        }
        return nil
    }
}
