import Foundation
import CoreGraphics

// MARK: - Settings

struct MovieTicketSettings: Codable, Equatable {
    var activeTemplateId: UUID?
    var lastPane: String = "main"

    private static let defaultsKey = "ReceiptPrinter.MovieTicketSettings"

    static func load() -> MovieTicketSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(MovieTicketSettings.self, from: data) else {
            return MovieTicketSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Draft (main page)

struct MovieTicketDraft: Codable, Equatable {
    var movieTitle: String = ""
    var movieDurationMinutes: Int = 0
    var adDurationMinutes: Int = 15
    var seatModeUnallocated: Bool = true
    var seatArea: String = ""
    var serialNumber: String = ""
    var showDate: Date = Calendar.current.startOfDay(for: Date())
    var showStartTime: Date = Date()
    var ticketType: String = ""
    var hall: String = ""
    var ticketPrice: String = ""

    var combinedStart: Date {
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: showDate)
        let t = cal.dateComponents([.hour, .minute, .second], from: showStartTime)
        var c = DateComponents()
        c.year = d.year
        c.month = d.month
        c.day = d.day
        c.hour = t.hour
        c.minute = t.minute
        c.second = t.second ?? 0
        return cal.date(from: c) ?? showStartTime
    }

    var showEndTime: Date {
        let total = max(0, adDurationMinutes) + max(0, movieDurationMinutes)
        return Calendar.current.date(byAdding: .minute, value: total, to: combinedStart) ?? combinedStart
    }

    var displaySeatText: String {
        if seatModeUnallocated { return "" } // template supplies unallocatedSeatLabel at compose
        return seatArea.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var formattedPrice: String {
        let trimmed = ticketPrice.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("$") { return trimmed }
        if let value = Double(trimmed.filter { $0.isNumber || $0 == "." }) {
            return String(format: "$%.2f", value)
        }
        return trimmed
    }

    static func blank(defaultAd: Int = 15) -> MovieTicketDraft {
        var d = MovieTicketDraft()
        d.adDurationMinutes = defaultAd
        return d
    }

    /// Reference draft matching the Ritz Matrix thermal ticket (for 示例对照).
    static func ritzMatrixSample() -> MovieTicketDraft {
        var sample = MovieTicketDraft(
            movieTitle: "35mm The Matrix",
            movieDurationMinutes: 136,
            adDurationMinutes: 20,
            seatModeUnallocated: true,
            serialNumber: "CSH 02081864/001",
            ticketType: "RETRO3",
            hall: "Cinema 1",
            ticketPrice: "0.00"
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var day = DateComponents()
        day.year = 2026; day.month = 6; day.day = 26
        if let d = cal.date(from: day) { sample.showDate = d }
        var time = DateComponents()
        time.hour = 20; time.minute = 0
        if let t0 = cal.date(from: time) { sample.showStartTime = t0 }
        return sample
    }

    /// Reference draft matching the IMAX Sydney Event Cinemas ticket (for 示例对照).
    static func imaxSydneySample() -> MovieTicketDraft {
        var sample = MovieTicketDraft(
            movieTitle: "THE ODYSSEY (M)",
            movieDurationMinutes: 183,
            adDurationMinutes: 0,
            seatModeUnallocated: false,
            seatArea: "L-9",
            serialNumber: "536011/001",
            ticketType: "CBIMAX",
            hall: "IMAX 1",
            ticketPrice: "43.00"
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var day = DateComponents()
        day.year = 2026; day.month = 7; day.day = 16
        if let d = cal.date(from: day) { sample.showDate = d }
        var time = DateComponents()
        time.hour = 17; time.minute = 40
        if let t0 = cal.date(from: time) { sample.showStartTime = t0 }
        return sample
    }
}

// MARK: - Field / element kinds

enum MovieTicketFieldKind: String, Codable, CaseIterable, Identifiable {
    case movieTitle
    case startTime
    case endTime
    case timeRange
    case seatArea
    case ticketPrice
    case ticketType
    case serialNumber
    case hall
    case qrCode
    case barcode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .movieTitle: return "影片名称"
        case .startTime: return "开始时间"
        case .endTime: return "结束时间"
        case .timeRange: return "时间段"
        case .seatArea: return "座位区"
        case .ticketPrice: return "票价"
        case .ticketType: return "票型"
        case .serialNumber: return "流水号"
        case .hall: return "影厅"
        case .qrCode: return "二维码"
        case .barcode: return "条码"
        }
    }

    /// Fields that can be extracted from a PDF recognition rule.
    var isPDFExtractable: Bool {
        switch self {
        case .qrCode, .barcode, .endTime, .timeRange: return false
        default: return true
        }
    }
}

enum MovieTicketElementKind: String, Codable {
    case textBox
    case fieldPlaceholder
    case currentDate
    case currentTime
    case logo
}

enum MovieTicketTimeFormat: String, Codable, CaseIterable, Identifiable {
    case hmma = "h:mm a"
    case HHmm = "HH:mm"
    case hmm = "h:mm"
    case EEEEhmm = "EEE h:mm a"
    /// Ritz-style show start: Fri Jun 26, 2026 08:00 PM
    case eeeMMMdhmma = "EEE MMM d, yyyy hh:mm a"
    /// Ritz-style session end: 26-06-2026 10:36:00 PM
    case ddMMyyyyhmmssa = "dd-MM-yyyy hh:mm:ss a"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hmma: return "6:00 PM"
        case .HHmm: return "18:00"
        case .hmm: return "6:00"
        case .EEEEhmm: return "Sun 6:00 PM"
        case .eeeMMMdhmma: return "Fri Jun 26, 2026 08:00 PM"
        case .ddMMyyyyhmmssa: return "26-06-2026 10:36:00 PM"
        }
    }

    func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = rawValue
        return f.string(from: date)
    }
}

enum MovieTicketDateFormat: String, Codable, CaseIterable, Identifiable {
    case ymdDash = "yyyy-MM-dd"
    case mdYSlash = "MM/dd/yyyy"
    case eeeMMMd = "EEE MMM d, yyyy"
    case ymdCN = "yyyy年M月d日"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ymdDash: return "2026-07-15"
        case .mdYSlash: return "07/15/2026"
        case .eeeMMMd: return "Wed Jul 15, 2026"
        case .ymdCN: return "2026年7月15日"
        }
    }

    func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = rawValue
        return f.string(from: date)
    }
}

struct MovieTicketElement: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: MovieTicketElementKind
    var frame: SequencePlaceholderFrame
    var zIndex: Int = 0
    var displayName: String = ""
    var content: String = ""
    var fontSize: CGFloat = AttributedTextView.defaultFontSize
    var isBold: Bool = false
    var alignment: Int = 0
    var isInverted: Bool = false
    var isLocked: Bool = false
    var fieldKind: MovieTicketFieldKind?
    var dateFormat: MovieTicketDateFormat = .eeeMMMd
    var timeFormat: MovieTicketTimeFormat = .hmma
    /// For timeRange: format of start / end and connector between them.
    var rangeStartFormat: MovieTicketTimeFormat = .hmma
    var rangeEndFormat: MovieTicketTimeFormat = .hmma
    var rangeConnector: String = " - "
    /// For `.logo` — relative filename under the template folder.
    var imageFilename: String?
    var logoScalePercent: Double = 100
    var logoBaseWidth: CGFloat = 120
    var logoBaseHeight: CGFloat = 60
    /// When true (used for the movie title): keep the value on a single line and
    /// clip whatever overflows the element box instead of wrapping to a new line.
    /// Optional so older saved templates decode unchanged (nil = wrap, legacy).
    var singleLineClip: Bool? = nil
}

struct MovieTicketTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var elements: [MovieTicketElement] = []
    var canvasHeight: CGFloat = 560
    var gridEnabled: Bool = true
    var gridSize: CGFloat = 20
    var backgroundImageFilename: String?
    var backgroundScalePercent: Double = 100
    /// Shown on ticket when main page selects 无特定座位.
    var unallocatedSeatLabel: String = "ADMIT"
    var pdfRuleId: UUID?
    /// Native print layout: `ritz` (default dual-stub) or `imaxSydney` (Event Cinemas IMAX).
    /// Optional so older saved templates decode unchanged.
    var layoutStyle: String? = nil
    /// Lines to advance after ticket content before the cutter fires.
    /// `nil` = use global `PrinterConfig.feedLinesBeforeCut`. Smaller = shorter tail / less waste.
    var feedLinesBeforeCut: Int? = nil

    var paperSize: CGSize { CGSize(width: 302, height: max(200, canvasHeight)) }

    var usesIMAXSydneyLayout: Bool {
        if layoutStyle == "imaxSydney" { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("IMAX SYDNEY") == .orderedSame
    }

    /// Effective cut feed for this template (0…40).
    func resolvedFeedLinesBeforeCut(config: PrinterConfig) -> Int {
        let raw = feedLinesBeforeCut ?? config.feedLinesBeforeCut
        return max(0, min(40, raw))
    }

    mutating func touch() { updatedAt = Date() }

    /// Rebuild stock geometry while keeping identity / name / PDF link / media filenames.
    /// - Returns the new template and the logo element id when the stock layout includes one.
    static func factoryReset(preserving meta: MovieTicketTemplate) -> (template: MovieTicketTemplate, logoElementId: UUID?) {
        if meta.usesIMAXSydneyLayout {
            let made = makeIMAXSydney()
            var t = made.template
            t.id = meta.id
            t.name = meta.name
            t.createdAt = meta.createdAt
            t.pdfRuleId = meta.pdfRuleId
            t.backgroundImageFilename = meta.backgroundImageFilename
            t.backgroundScalePercent = meta.backgroundScalePercent
            t.feedLinesBeforeCut = meta.feedLinesBeforeCut
            return (t, made.logoElementId)
        }
        var t = makeBlank(name: meta.name)
        t.id = meta.id
        t.createdAt = meta.createdAt
        t.pdfRuleId = meta.pdfRuleId
        t.backgroundImageFilename = meta.backgroundImageFilename
        t.backgroundScalePercent = meta.backgroundScalePercent
        t.feedLinesBeforeCut = meta.feedLinesBeforeCut
        t.unallocatedSeatLabel = meta.unallocatedSeatLabel.isEmpty ? t.unallocatedSeatLabel : meta.unallocatedSeatLabel
        return (t, nil)
    }

    /// Ritz Cinemas dual-stub layout (tear-off stub + barcode stub), matching thermal ticket style.
    static func makeBlank(name: String = "新影票模板") -> MovieTicketTemplate {
        var t = MovieTicketTemplate(name: name)
        t.unallocatedSeatLabel = "ADMIT"
        t.canvasHeight = 430
        t.gridSize = 20
        t.feedLinesBeforeCut = 4
        var z = 0
        func nextZ() -> Int {
            z += 1
            return z
        }

        // MARK: Top stub
        t.elements += ritzStubElements(yOffset: 4, zBase: &z, includeBarcode: false)

        // Dashed tear line — continuous hyphens like real Ritz tickets
        t.elements.append(
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: 6, y: 156, width: 290, height: 12),
                zIndex: nextZ(),
                content: String(repeating: "-", count: 42),
                fontSize: 10,
                alignment: 1
            )
        )

        // MARK: Bottom stub + barcode
        t.elements += ritzStubElements(yOffset: 172, zBase: &z, includeBarcode: true)
        t.canvasHeight = 450
        return t
    }

    /// Event Cinemas IMAX Sydney single-stub layout (logo → barcode → title → seat → footer).
    /// Returns the template and the logo element id so the store can attach the bundled PNG.
    static func makeIMAXSydney() -> (template: MovieTicketTemplate, logoElementId: UUID) {
        var t = MovieTicketTemplate(name: "IMAX SYDNEY")
        t.layoutStyle = "imaxSydney"
        t.unallocatedSeatLabel = "SEAT GA"
        t.gridSize = 20
        t.canvasHeight = 520
        t.feedLinesBeforeCut = 4
        var z = 0
        func nextZ() -> Int {
            z += 1
            return z
        }
        let left: CGFloat = 8
        let width: CGFloat = 286
        let logoId = UUID()

        // Header logo — IMAX / SYDNEY wordmark (bundled asset attached at seed time).
        var logo = MovieTicketElement(
            kind: .logo,
            frame: SequencePlaceholderFrame(x: 12, y: 8, width: 278, height: 94),
            zIndex: nextZ(),
            alignment: 1,
            logoScalePercent: 100,
            logoBaseWidth: 278,
            logoBaseHeight: 94
        )
        logo.id = logoId
        t.elements.append(logo)

        t.elements.append(contentsOf: [
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: 82, width: width, height: 14),
                zIndex: nextZ(),
                content: "IMAX Sydney",
                fontSize: 11,
                alignment: 1
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 36, y: 104, width: 230, height: 56),
                zIndex: nextZ(),
                alignment: 1,
                fieldKind: .barcode
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 160, width: width, height: 14),
                zIndex: nextZ(),
                fontSize: 11,
                alignment: 1,
                fieldKind: .serialNumber
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 196, width: width, height: 24),
                zIndex: nextZ(),
                fontSize: 14,
                isBold: true,
                alignment: 0,
                fieldKind: .hall
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 224, width: width, height: 28),
                zIndex: nextZ(),
                fontSize: 16,
                isBold: true,
                alignment: 0,
                fieldKind: .movieTitle,
                singleLineClip: true
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 258, width: width, height: 16),
                zIndex: nextZ(),
                fontSize: 11,
                alignment: 0,
                fieldKind: .timeRange,
                rangeStartFormat: .eeeMMMdhmma,
                rangeEndFormat: .hmma,
                rangeConnector: " - "
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 300, width: width, height: 40),
                zIndex: nextZ(),
                fontSize: 18,
                isBold: true,
                alignment: 0,
                fieldKind: .seatArea
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 348, width: 140, height: 14),
                zIndex: nextZ(),
                fontSize: 11,
                alignment: 0,
                fieldKind: .ticketType
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 168, y: 348, width: 126, height: 14),
                zIndex: nextZ(),
                fontSize: 11,
                alignment: 2,
                fieldKind: .ticketPrice
            ),
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: 368, width: width, height: 12),
                zIndex: nextZ(),
                content: "EFTP | T/N: {serial} | d: {datetime} | u: 9613",
                fontSize: 9,
                alignment: 1
            ),
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: 390, width: width, height: 12),
                zIndex: nextZ(),
                content: String(repeating: "-", count: 42),
                fontSize: 10,
                alignment: 1
            ),
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: 410, width: width, height: 14),
                zIndex: nextZ(),
                content: "PLEASE RETAIN YOUR TICKET AS PROOF OF PURCHASE",
                fontSize: 11,
                alignment: 1
            ),
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: 426, width: width, height: 14),
                zIndex: nextZ(),
                content: "WWW.EVENTCINEMAS.COM.AU",
                fontSize: 11,
                alignment: 1
            )
        ])
        return (t, logoId)
    }

    /// One Ritz ticket half. Tight leading to match thermal print; title uses double-height stretch at render.
    private static func ritzStubElements(
        yOffset: CGFloat,
        zBase: inout Int,
        includeBarcode: Bool
    ) -> [MovieTicketElement] {
        func z() -> Int {
            zBase += 1
            return zBase
        }
        let left: CGFloat = 8
        let width: CGFloat = 286
        // Line pitch ≈ 15–16pt (header), body ≈ 14pt — matches real Ritz density.
        var items: [MovieTicketElement] = [
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: yOffset, width: width, height: 15),
                zIndex: z(),
                content: "Ritz Cinemas",
                fontSize: 13,
                isBold: true,
                alignment: 0
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 15, width: width, height: 15),
                zIndex: z(),
                fontSize: 13,
                isBold: true,
                alignment: 0,
                fieldKind: .hall
            ),
            // Height×3 title frame for preview; print uses GS ! taller (0x02).
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 30, width: width, height: 36),
                zIndex: z(),
                fontSize: 12,
                isBold: true,
                alignment: 0,
                fieldKind: .movieTitle,
                singleLineClip: true
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 68, width: width, height: 14),
                zIndex: z(),
                fontSize: 11,
                alignment: 0,
                fieldKind: .startTime,
                timeFormat: .eeeMMMdhmma
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 82, width: width, height: 14),
                zIndex: z(),
                content: "Session End Time: ",
                fontSize: 11,
                alignment: 0,
                fieldKind: .endTime,
                timeFormat: .ddMMyyyyhmmssa
            ),
            // ADMIT left — RETRO3 + price right (space-between)
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 98, width: 70, height: 14),
                zIndex: z(),
                fontSize: 11,
                isBold: true,
                alignment: 0,
                fieldKind: .seatArea
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 150, y: yOffset + 98, width: 80, height: 14),
                zIndex: z(),
                fontSize: 11,
                alignment: 2,
                fieldKind: .ticketType
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 232, y: yOffset + 98, width: 62, height: 14),
                zIndex: z(),
                fontSize: 11,
                alignment: 2,
                fieldKind: .ticketPrice
            )
        ]

        if includeBarcode {
            items.append(
                MovieTicketElement(
                    kind: .fieldPlaceholder,
                    frame: SequencePlaceholderFrame(x: left, y: yOffset + 116, width: width, height: 72),
                    zIndex: z(),
                    alignment: 1,
                    fieldKind: .barcode
                )
            )
            items.append(
                MovieTicketElement(
                    kind: .fieldPlaceholder,
                    frame: SequencePlaceholderFrame(x: left, y: yOffset + 190, width: width, height: 12),
                    zIndex: z(),
                    fontSize: 9,
                    alignment: 1,
                    fieldKind: .serialNumber
                )
            )
        } else {
            items.append(
                MovieTicketElement(
                    kind: .fieldPlaceholder,
                    frame: SequencePlaceholderFrame(x: left, y: yOffset + 116, width: width, height: 12),
                    zIndex: z(),
                    fontSize: 9,
                    alignment: 1,
                    fieldKind: .serialNumber
                )
            )
        }
        return items
    }

    func hasElement(field kind: MovieTicketFieldKind) -> Bool {
        elements.contains { $0.kind == .fieldPlaceholder && $0.fieldKind == kind }
    }
}

// MARK: - PDF recognition

/// Normalized rect in PDF page space (origin top-left, 0…1).
struct MovieTicketRelativeRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func clamped() -> MovieTicketRelativeRect {
        let w = min(1, max(0.01, width))
        let h = min(1, max(0.01, height))
        let nx = min(1 - w, max(0, x))
        let ny = min(1 - h, max(0, y))
        return MovieTicketRelativeRect(x: nx, y: ny, width: w, height: h)
    }

    func absolute(in pageSize: CGSize) -> CGRect {
        CGRect(
            x: x * pageSize.width,
            y: y * pageSize.height,
            width: width * pageSize.width,
            height: height * pageSize.height
        )
    }

    static func from(absolute rect: CGRect, pageSize: CGSize) -> MovieTicketRelativeRect {
        guard pageSize.width > 0, pageSize.height > 0 else {
            return MovieTicketRelativeRect(x: 0, y: 0, width: 0.2, height: 0.05)
        }
        return MovieTicketRelativeRect(
            x: rect.origin.x / pageSize.width,
            y: rect.origin.y / pageSize.height,
            width: rect.size.width / pageSize.width,
            height: rect.size.height / pageSize.height
        ).clamped()
    }
}

/// How a boxed PDF region is used at recognition time.
enum MovieTicketPDFCaptureMode: String, Codable, CaseIterable, Identifiable {
    /// Extract whatever text sits in the saved rectangle.
    case positionOnly
    /// Prefer text near / after the given keywords inside the rectangle.
    case withKeywords

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .positionOnly: return "仅记住位置"
        case .withKeywords: return "识别关键词"
        }
    }
}

/// After locating the region, optionally keep only a slice of its text.
/// Usually inferred from a user-provided sample via `analyzeExtractSample`.
enum MovieTicketPDFExtractKind: String, Codable, CaseIterable, Identifiable {
    /// Keep the whole located string.
    case entire
    /// Keep text immediately after `extractKeyword`.
    case afterKeyword
    /// Keep a `$12.34` / `12.34` amount (after keyword if set, else last amount in region).
    case currency
    /// Keep the first digit run (optionally after keyword).
    case digits

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .entire: return "全部文字"
        case .afterKeyword: return "关键词之后"
        case .currency: return "金额"
        case .digits: return "数字"
        }
    }
}

/// Result of learning an extract rule from a user sample inside region preview text.
struct MovieTicketPDFExtractAnalysis: Equatable {
    var kind: MovieTicketPDFExtractKind
    var keyword: String
    var sample: String
    /// Short Chinese summary for the mapping UI.
    var summary: String
}

/// Maps an extracted PDF value to a print-friendly short form
/// (e.g. match "Member Adult" → replacement "Mem Adu").
struct MovieTicketPDFValueMapping: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Text to look for in the extracted value (case-insensitive; substring or whole).
    var match: String
    /// Value used for the ticket draft / print when `match` is found.
    var replacement: String

    enum CodingKeys: String, CodingKey {
        case id, match, replacement
    }

    init(id: UUID = UUID(), match: String, replacement: String) {
        self.id = id
        self.match = match
        self.replacement = replacement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        match = try c.decode(String.self, forKey: .match)
        replacement = try c.decode(String.self, forKey: .replacement)
    }
}

struct MovieTicketPDFRegion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Target field on the ticket draft (derived from the linked template element).
    var fieldKind: MovieTicketFieldKind
    /// Concrete template element block this region fills (optional for older rules).
    var elementId: UUID? = nil
    var rect: MovieTicketRelativeRect
    var pageIndex: Int = 0
    var captureMode: MovieTicketPDFCaptureMode = .positionOnly
    /// Keywords used when `captureMode == .withKeywords` (locate the region across page sizes).
    var regionKeywords: [String] = []
    /// After locating, which slice of the region text to keep (inferred from sample).
    var extractKind: MovieTicketPDFExtractKind = .entire
    /// Keyword used by `.afterKeyword` / as an anchor for `.currency` / `.digits`.
    var extractKeyword: String = ""
    /// User-entered example of the value to keep (e.g. "20.45"); empty = keep all.
    var extractSample: String = ""
    /// Sample text captured when the region was defined (UI hint only).
    var extractedHint: String = ""
    /// Optional rewrite rules applied after extract (e.g. "Member Adult" → "Mem Adu").
    var valueMappings: [MovieTicketPDFValueMapping] = []

    enum CodingKeys: String, CodingKey {
        case id, fieldKind, elementId, rect, pageIndex, captureMode, regionKeywords
        case extractKind, extractKeyword, extractSample, extractedHint, valueMappings
    }

    init(
        id: UUID = UUID(),
        fieldKind: MovieTicketFieldKind,
        elementId: UUID? = nil,
        rect: MovieTicketRelativeRect,
        pageIndex: Int = 0,
        captureMode: MovieTicketPDFCaptureMode = .positionOnly,
        regionKeywords: [String] = [],
        extractKind: MovieTicketPDFExtractKind = .entire,
        extractKeyword: String = "",
        extractSample: String = "",
        extractedHint: String = "",
        valueMappings: [MovieTicketPDFValueMapping] = []
    ) {
        self.id = id
        self.fieldKind = fieldKind
        self.elementId = elementId
        self.rect = rect
        self.pageIndex = pageIndex
        self.captureMode = captureMode
        self.regionKeywords = regionKeywords
        self.extractKind = extractKind
        self.extractKeyword = extractKeyword
        self.extractSample = extractSample
        self.extractedHint = extractedHint
        self.valueMappings = valueMappings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fieldKind = try c.decode(MovieTicketFieldKind.self, forKey: .fieldKind)
        elementId = try c.decodeIfPresent(UUID.self, forKey: .elementId)
        rect = try c.decode(MovieTicketRelativeRect.self, forKey: .rect)
        pageIndex = try c.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0
        captureMode = try c.decodeIfPresent(MovieTicketPDFCaptureMode.self, forKey: .captureMode) ?? .positionOnly
        regionKeywords = try c.decodeIfPresent([String].self, forKey: .regionKeywords) ?? []
        extractKind = try c.decodeIfPresent(MovieTicketPDFExtractKind.self, forKey: .extractKind) ?? .entire
        extractKeyword = try c.decodeIfPresent(String.self, forKey: .extractKeyword) ?? ""
        extractSample = try c.decodeIfPresent(String.self, forKey: .extractSample) ?? ""
        extractedHint = try c.decodeIfPresent(String.self, forKey: .extractedHint) ?? ""
        valueMappings = try c.decodeIfPresent([MovieTicketPDFValueMapping].self, forKey: .valueMappings) ?? []
    }
}

struct MovieTicketPDFRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var detectorKeywords: [String] = []
    var regions: [MovieTicketPDFRegion] = []
    var linkedTemplateId: UUID?
    /// Relative filename under rules folder (copied sample PDF).
    var samplePDFFilename: String?
    /// Display size of the sample page when regions were defined (points).
    var samplePageWidth: Double?
    var samplePageHeight: Double?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, detectorKeywords, regions, linkedTemplateId
        case samplePDFFilename, samplePageWidth, samplePageHeight, createdAt, updatedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        detectorKeywords: [String] = [],
        regions: [MovieTicketPDFRegion] = [],
        linkedTemplateId: UUID? = nil,
        samplePDFFilename: String? = nil,
        samplePageWidth: Double? = nil,
        samplePageHeight: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.detectorKeywords = detectorKeywords
        self.regions = regions
        self.linkedTemplateId = linkedTemplateId
        self.samplePDFFilename = samplePDFFilename
        self.samplePageWidth = samplePageWidth
        self.samplePageHeight = samplePageHeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        detectorKeywords = try c.decodeIfPresent([String].self, forKey: .detectorKeywords) ?? []
        regions = try c.decodeIfPresent([MovieTicketPDFRegion].self, forKey: .regions) ?? []
        linkedTemplateId = try c.decodeIfPresent(UUID.self, forKey: .linkedTemplateId)
        samplePDFFilename = try c.decodeIfPresent(String.self, forKey: .samplePDFFilename)
        samplePageWidth = try c.decodeIfPresent(Double.self, forKey: .samplePageWidth)
        samplePageHeight = try c.decodeIfPresent(Double.self, forKey: .samplePageHeight)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    mutating func touch() { updatedAt = Date() }

    mutating func recordSamplePageSize(_ size: CGSize) {
        samplePageWidth = Double(size.width)
        samplePageHeight = Double(size.height)
    }

    /// Returns true when `size` differs from the size used when regions were boxed.
    func samplePageSizeMismatch(_ size: CGSize, tolerance: CGFloat = 2) -> Bool {
        guard let w = samplePageWidth, let h = samplePageHeight, !regions.isEmpty else { return false }
        return abs(CGFloat(w) - size.width) > tolerance || abs(CGFloat(h) - size.height) > tolerance
    }
}

// MARK: - Print history

struct MovieTicketPrintHistoryRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var templateId: UUID?
    var templateName: String
    var draft: MovieTicketDraft
    var previewPNG: Data

    var summary: String {
        let title = draft.movieTitle.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return "（无片名）" }
        return title
    }
}
