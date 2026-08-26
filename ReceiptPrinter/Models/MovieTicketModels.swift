import Foundation
import CoreGraphics

// MARK: - Settings

struct MovieTicketSettings: Codable, Equatable {
    var activeTemplateId: UUID?
    var lastPane: String = "main"
    /// Ticket-face forms for content ratings (e.g. `MA 15+` → `MA15`).
    var ratingPrintMappings: [MovieTicketRatingPrintMapping] = MovieTicketRatingPrintMapping.defaults

    private static let defaultsKey = "ReceiptPrinter.MovieTicketSettings"

    enum CodingKeys: String, CodingKey {
        case activeTemplateId, lastPane, ratingPrintMappings
    }

    init(
        activeTemplateId: UUID? = nil,
        lastPane: String = "main",
        ratingPrintMappings: [MovieTicketRatingPrintMapping] = MovieTicketRatingPrintMapping.defaults
    ) {
        self.activeTemplateId = activeTemplateId
        self.lastPane = lastPane
        self.ratingPrintMappings = ratingPrintMappings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeTemplateId = try c.decodeIfPresent(UUID.self, forKey: .activeTemplateId)
        lastPane = try c.decodeIfPresent(String.self, forKey: .lastPane) ?? "main"
        ratingPrintMappings = try c.decodeIfPresent(
            [MovieTicketRatingPrintMapping].self,
            forKey: .ratingPrintMappings
        ) ?? MovieTicketRatingPrintMapping.defaults
    }

    static func load() -> MovieTicketSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode(MovieTicketSettings.self, from: data) else {
            return MovieTicketSettings()
        }
        // Migrate old MA15+ → M shorthand so it stays distinct from M.
        var changed = false
        for i in decoded.ratingPrintMappings.indices {
            let src = MovieTicketRatingPrintMapping.normalizedKey(decoded.ratingPrintMappings[i].source)
            let dst = decoded.ratingPrintMappings[i].printAs
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if (src == "MA15+" || src == "MA15") && dst == "M" {
                decoded.ratingPrintMappings[i].printAs = "MA15"
                changed = true
            }
        }
        if changed { decoded.save() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Maps a verified / TMDB rating to the short form printed on the stub.
struct MovieTicketRatingPrintMapping: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Source rating as verified (e.g. `MA15+`, `MA 15+`).
    var source: String
    /// Printed form inside parentheses (e.g. `MA15`).
    var printAs: String

    static let defaults: [MovieTicketRatingPrintMapping] = [
        .init(source: "MA15+", printAs: "MA15"),
        .init(source: "MA 15+", printAs: "MA15"),
        .init(source: "R18+", printAs: "R"),
        .init(source: "R 18+", printAs: "R"),
        .init(source: "X18+", printAs: "X"),
        .init(source: "X 18+", printAs: "X")
    ]

    /// Normalize for lookup: uppercase, keep letters/digits/`+`.
    static func normalizedKey(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return upper.filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }

    static func printLabel(
        for raw: String,
        mappings: [MovieTicketRatingPrintMapping] = MovieTicketRatingPrintMapping.defaults
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let key = normalizedKey(trimmed)
        for row in mappings {
            if normalizedKey(row.source) == key {
                let label = row.printAs.trimmingCharacters(in: .whitespacesAndNewlines)
                return label.isEmpty ? trimmed : label
            }
        }
        return trimmed
    }
}

// MARK: - Draft (main page)

struct MovieTicketDraft: Codable, Equatable {
    var movieTitle: String = ""
    /// Classification / certificate from TMDB (e.g. `M`, `PG`, `MA15+`).
    var contentRating: String = ""
    /// When true, print `movieTitle (contentRating)` on the ticket.
    var printContentRating: Bool = false
    var movieDurationMinutes: Int = 0
    var adDurationMinutes: Int = 15
    var seatModeUnallocated: Bool = true
    /// Primary / first-ticket seat (kept for compatibility + single-seat UI).
    var seatArea: String = ""
    /// Per-ticket seats when `ticketCount` > 1 and seats are allocated.
    var seatAreas: [String] = [""]
    /// Base order / booking id **without** `/001` style ticket index suffix.
    var serialNumber: String = ""
    /// Optional Dendy-style short code under the QR (`Code: #…`). Empty → derive from serial.
    var bookingCode: String = ""
    /// How many physical tickets to print (each gets `/001` … `/00N`).
    var ticketCount: Int = 1
    var showDate: Date = Calendar.current.startOfDay(for: Date())
    var showStartTime: Date = Date()
    var ticketType: String = ""
    var hall: String = ""
    var ticketPrice: String = ""
    /// Custom QR/barcode payloads keyed by element UUID string (when element uses `.custom` source).
    var customCodePayloads: [String: String] = [:]

    /// Title as printed on the stub (optionally appends mapped classification).
    var printedMovieTitle: String {
        printedMovieTitle(using: MovieTicketSettings.load().ratingPrintMappings)
    }

    func printedMovieTitle(using mappings: [MovieTicketRatingPrintMapping]) -> String {
        let base = movieTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let rating = MovieTicketRatingPrintMapping.printLabel(for: contentRating, mappings: mappings)
        guard printContentRating, !base.isEmpty, !rating.isEmpty else { return base }
        let suffix = "(\(rating))"
        if base.hasSuffix(suffix) { return base }
        // Case-insensitive already-present check, e.g. "THE ODYSSEY (M)"
        if base.uppercased().hasSuffix(suffix.uppercased()) { return base }
        return "\(base) \(suffix)"
    }

    /// Strip a trailing `/digits` ticket index from a serial string.
    static func serialBase(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: #"^(.*?)/0*\d+$"#),
              let match = re.firstMatch(
                in: trimmed,
                range: NSRange(location: 0, length: (trimmed as NSString).length)
              ),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: trimmed)
        else { return trimmed }
        return String(trimmed[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var serialBase: String { Self.serialBase(from: serialNumber) }

    /// Serial printed on ticket at `index` (0-based), e.g. `477560/001`.
    func serialForTicket(at index: Int) -> String {
        let base = serialBase
        guard !base.isEmpty else { return "" }
        let n = max(1, index + 1)
        return "\(base)/\(String(format: "%03d", n))"
    }

    /// Clamp count to 1…4 and keep `seatAreas` / `seatArea` in sync.
    mutating func setTicketCount(_ count: Int) {
        ticketCount = max(1, min(4, count))
        syncSeatArrays()
    }

    mutating func syncSeatArrays() {
        var areas = seatAreas
        if areas.isEmpty { areas = [seatArea] }
        while areas.count < ticketCount {
            areas.append("")
        }
        if areas.count > ticketCount {
            areas = Array(areas.prefix(ticketCount))
        }
        if areas.indices.contains(0),
           seatArea != areas[0],
           !seatArea.isEmpty,
           areas[0].isEmpty {
            areas[0] = seatArea
        }
        let syncedSeat = areas.indices.contains(0) ? areas[0] : seatArea
        // Avoid no-op writes: assigning through `@Published draft` always invalidates the UI.
        if areas != seatAreas { seatAreas = areas }
        if seatArea != syncedSeat { seatArea = syncedSeat }
    }

    /// Draft used for preview/print of one physical ticket.
    func draftForTicket(at index: Int) -> MovieTicketDraft {
        var copy = self
        copy.serialNumber = serialForTicket(at: index)
        if !seatModeUnallocated {
            let seats = seatAreas.isEmpty ? [seatArea] : seatAreas
            copy.seatArea = seats.indices.contains(index) ? seats[index] : ""
            copy.seatAreas = [copy.seatArea]
        }
        copy.ticketCount = 1
        return copy
    }

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

    enum CodingKeys: String, CodingKey {
        case movieTitle, contentRating, printContentRating
        case movieDurationMinutes, adDurationMinutes
        case seatModeUnallocated, seatArea, seatAreas, serialNumber, bookingCode, ticketCount
        case showDate, showStartTime, ticketType, hall, ticketPrice, customCodePayloads
    }

    init(
        movieTitle: String = "",
        contentRating: String = "",
        printContentRating: Bool = false,
        movieDurationMinutes: Int = 0,
        adDurationMinutes: Int = 15,
        seatModeUnallocated: Bool = true,
        seatArea: String = "",
        seatAreas: [String] = [""],
        serialNumber: String = "",
        bookingCode: String = "",
        ticketCount: Int = 1,
        showDate: Date = Calendar.current.startOfDay(for: Date()),
        showStartTime: Date = Date(),
        ticketType: String = "",
        hall: String = "",
        ticketPrice: String = "",
        customCodePayloads: [String: String] = [:]
    ) {
        self.movieTitle = movieTitle
        self.contentRating = contentRating
        self.printContentRating = printContentRating
        self.movieDurationMinutes = movieDurationMinutes
        self.adDurationMinutes = adDurationMinutes
        self.seatModeUnallocated = seatModeUnallocated
        self.seatArea = seatArea
        self.seatAreas = seatAreas.isEmpty ? [seatArea] : seatAreas
        self.serialNumber = Self.serialBase(from: serialNumber)
        self.bookingCode = bookingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ticketCount = max(1, min(4, ticketCount))
        self.showDate = showDate
        self.showStartTime = showStartTime
        self.ticketType = ticketType
        self.hall = hall
        self.ticketPrice = ticketPrice
        self.customCodePayloads = customCodePayloads
        syncSeatArrays()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movieTitle = try c.decodeIfPresent(String.self, forKey: .movieTitle) ?? ""
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating) ?? ""
        printContentRating = try c.decodeIfPresent(Bool.self, forKey: .printContentRating) ?? false
        movieDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .movieDurationMinutes) ?? 0
        adDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .adDurationMinutes) ?? 15
        seatModeUnallocated = try c.decodeIfPresent(Bool.self, forKey: .seatModeUnallocated) ?? true
        seatArea = try c.decodeIfPresent(String.self, forKey: .seatArea) ?? ""
        seatAreas = try c.decodeIfPresent([String].self, forKey: .seatAreas) ?? [seatArea]
        serialNumber = Self.serialBase(
            from: try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        )
        bookingCode = (try c.decodeIfPresent(String.self, forKey: .bookingCode) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ticketCount = max(1, min(4, try c.decodeIfPresent(Int.self, forKey: .ticketCount) ?? 1))
        showDate = try c.decodeIfPresent(Date.self, forKey: .showDate)
            ?? Calendar.current.startOfDay(for: Date())
        showStartTime = try c.decodeIfPresent(Date.self, forKey: .showStartTime) ?? Date()
        ticketType = try c.decodeIfPresent(String.self, forKey: .ticketType) ?? ""
        hall = try c.decodeIfPresent(String.self, forKey: .hall) ?? ""
        ticketPrice = try c.decodeIfPresent(String.self, forKey: .ticketPrice) ?? ""
        customCodePayloads = try c.decodeIfPresent([String: String].self, forKey: .customCodePayloads) ?? [:]
        syncSeatArrays()
    }

    static func blank(defaultAd: Int = 15) -> MovieTicketDraft {
        var d = MovieTicketDraft()
        d.adDurationMinutes = defaultAd
        d.ticketCount = 1
        d.seatAreas = [""]
        return d
    }

    /// Reference draft matching the Ritz Matrix thermal ticket (for 示例对照).
    static func ritzMatrixSample() -> MovieTicketDraft {
        var sample = MovieTicketDraft(
            movieTitle: "35mm The Matrix",
            movieDurationMinutes: 136,
            adDurationMinutes: 20,
            seatModeUnallocated: true,
            serialNumber: "CSH 02081864",
            ticketCount: 1,
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
            seatAreas: ["L-9"],
            serialNumber: "536011",
            ticketCount: 1,
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

    /// Reference draft matching the classic Hayden Orpheum ticket.
    static func orpheumSample() -> MovieTicketDraft {
        var sample = MovieTicketDraft(
            movieTitle: "Dunkirk 70mm",
            movieDurationMinutes: 117,
            adDurationMinutes: 0,
            seatModeUnallocated: true,
            serialNumber: "DEBI 00687743/001",
            ticketCount: 1,
            ticketType: "Adult",
            hall: "4",
            ticketPrice: "28.00"
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var day = DateComponents()
        day.year = 2026; day.month = 6; day.day = 28
        if let d = cal.date(from: day) { sample.showDate = d }
        var time = DateComponents()
        time.hour = 18; time.minute = 0
        if let t0 = cal.date(from: time) { sample.showStartTime = t0 }
        return sample
    }

    /// Reference draft matching the Dendy-style centered QR ticket.
    static func dendySample() -> MovieTicketDraft {
        var sample = MovieTicketDraft(
            movieTitle: "The Testament of Ann Lee",
            movieDurationMinutes: 157,
            adDurationMinutes: 0,
            seatModeUnallocated: false,
            seatArea: "F7",
            seatAreas: ["F7"],
            serialNumber: "466713335",
            bookingCode: "6924686",
            ticketCount: 1,
            ticketType: "Adult Event",
            hall: "3",
            ticketPrice: "0.00"
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var day = DateComponents()
        day.year = 2026; day.month = 2; day.day = 21
        if let d = cal.date(from: day) { sample.showDate = d }
        var time = DateComponents()
        time.hour = 15; time.minute = 0
        if let t0 = cal.date(from: time) { sample.showStartTime = t0 }
        return sample
    }
}

// MARK: - Hall display

/// How the 影厅 element prints the recognized hall value.
enum MovieTicketHallDisplayMode: String, Codable, CaseIterable, Identifiable {
    /// `Cinema 1` from recognized `Screen 1` / `Cinema 1` / `1`.
    case cinemaNumber
    /// Digits only.
    case numberOnly
    /// `hallNumberPrefix` + digits (e.g. `Screen ` → `Screen 1`).
    case customPrefix
    /// Use PDF/manual draft text as-is (mappings / affixes already applied).
    case asRecognized

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cinemaNumber: return L10n.ui("Cinema + 数字")
        case .numberOnly: return L10n.ui("仅数字")
        case .customPrefix: return L10n.ui("自定义前缀 + 数字")
        case .asRecognized: return L10n.ui("识别原文")
        }
    }
}

// MARK: - Field / element kinds

enum MovieTicketFieldKind: String, Codable, CaseIterable, Identifiable {
    case movieTitle
    case startTime
    case endTime
    case timeRange
    /// Session calendar date (separate from start/end clock time).
    case showDate
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
        case .movieTitle: return L10n.ui("影片名称")
        case .startTime: return L10n.ui("开始时间")
        case .endTime: return L10n.ui("结束时间")
        case .timeRange: return L10n.ui("时间段")
        case .showDate: return L10n.ui("日期")
        case .seatArea: return L10n.ui("座位区")
        case .ticketPrice: return L10n.ui("票价")
        case .ticketType: return L10n.ui("票型")
        case .serialNumber: return L10n.ui("流水号")
        case .hall: return L10n.ui("影厅")
        case .qrCode: return L10n.ui("二维码")
        case .barcode: return L10n.ui("条码")
        }
    }

    /// Fields that can be extracted from a PDF recognition rule.
    var isPDFExtractable: Bool {
        // endTime is extractable (Dendy/Event "Ends at …"); barcode/qr share serial extract.
        true
    }

    /// Short description shown in the PDF recognizer panel.
    var recognizerSummary: String {
        switch self {
        case .movieTitle: return L10n.ui("搜索 PDF 中的影片名称；找不到再框选定位")
        case .hall: return L10n.ui("搜索 PDF 中的影厅/Screen；找不到再框选定位")
        case .seatArea: return L10n.ui("搜索座位；可设「无指定座位」跳过检索")
        case .ticketType: return L10n.ui("搜索票型；支持关键词映射或默认票型")
        case .ticketPrice: return L10n.ui("优先取 Total 后的金额；找不到再框选")
        case .serialNumber: return L10n.ui("识别订票码/流水号；找不到再框选")
        case .barcode: return L10n.ui("识别订票码，填入条码内容（与流水号同源）")
        case .qrCode: return L10n.ui("识别订票码，填入二维码内容（与流水号同源）")
        case .timeRange: return L10n.ui("识别开场时间（与开始时间共用逻辑）；可勾选同时识别日期")
        case .startTime: return L10n.ui("识别开场时间；可勾选同时识别日期；找不到再框选定位")
        case .showDate: return L10n.ui("识别场次日期；找不到再框选定位")
        case .endTime: return L10n.ui("搜索 Ends at / Until 结束时间；找不到再框选定位")
        }
    }
}

/// Where QR / barcode payload comes from on the main page.
enum MovieTicketCodeContentSource: String, Codable, CaseIterable, Identifiable {
    case serialNumber
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serialNumber: return L10n.ui("流水号")
        case .custom: return L10n.ui("自定义")
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
    /// Calendar day without year: February 21
    case MMMMd = "MMMM d"
    /// Dendy session date with year: February 21, 2026
    case MMMMdyyyy = "MMMM d, yyyy"
    case ymdCN = "yyyy年M月d日"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ymdDash: return "2026-07-15"
        case .mdYSlash: return "07/15/2026"
        case .eeeMMMd: return "Wed Jul 15, 2026"
        case .MMMMd: return "February 21"
        case .MMMMdyyyy: return "February 21, 2026"
        case .ymdCN: return L10n.ui("2026年7月15日")
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
    var fontSize: CGFloat = 11
    var isBold: Bool = false
    var alignment: Int = 0
    /// Extra right-side character spacing in ESC/POS dots (`ESC SP n`). 0 = default.
    var characterSpacing: Int = 0
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
    /// When true: keep text on a single line and clip overflow past the element box width.
    /// When false/nil: wrap within the box width and clip lines that exceed the box height.
    /// Optional so older saved templates decode unchanged.
    var singleLineClip: Bool? = nil
    /// Explicit GS ! height magnification (1…3). Independent of the element box (print region).
    /// `nil` = legacy templates; inferred once from box height then persisted via migration.
    var printHeightScale: Int? = nil
    /// Hall print shape. `nil` defaults to `.cinemaNumber` for `.hall` elements.
    var hallDisplayMode: MovieTicketHallDisplayMode? = nil
    /// Prefix before the hall number when `hallDisplayMode == .customPrefix`.
    /// Optional so older saved templates (without this key) still decode.
    var hallNumberPrefix: String? = nil
    /// QR/barcode payload source. `nil` = `.serialNumber` (legacy).
    var codeContentSource: MovieTicketCodeContentSource? = nil
    /// Serial HRI style: wrap digits with `* … *`. `nil` = true (legacy IMAX/Ritz).
    var serialHRIIncludeAsterisks: Bool? = nil

    /// Text / date / time fields that expose the wrap control (not logo / QR / barcode).
    var supportsTextWrapControl: Bool {
        switch kind {
        case .textBox, .currentDate, .currentTime:
            return true
        case .fieldPlaceholder:
            guard let fieldKind else { return true }
            return fieldKind != .qrCode && fieldKind != .barcode
        case .logo:
            return false
        }
    }

    /// `true` when the box may wrap (default for nil `singleLineClip`).
    var allowsTextWrap: Bool { singleLineClip != true }

    /// Whether spaced serial HRI includes leading/trailing `*` (default on for older templates).
    var includesSerialHRIAsterisks: Bool { serialHRIIncludeAsterisks != false }

    /// Resolved printable string for canvas / inspector preview (mirrors IMAX field resolve).
    func resolvedPrintableText(
        from draft: MovieTicketDraft,
        template: MovieTicketTemplate,
        now: Date = Date()
    ) -> String {
        switch kind {
        case .textBox:
            return content
        case .currentDate:
            return dateFormat.format(now)
        case .currentTime:
            return timeFormat.format(now)
        case .logo:
            return ""
        case .fieldPlaceholder:
            guard let fieldKind else { return "" }
            switch fieldKind {
            case .movieTitle:
                return draft.printedMovieTitle
            case .showDate:
                return dateFormat.format(draft.showDate)
            case .startTime:
                return timeFormat.format(draft.combinedStart)
            case .endTime:
                let body = timeFormat.format(draft.showEndTime)
                return content.isEmpty ? body : content + body
            case .timeRange:
                let a = rangeStartFormat.format(draft.combinedStart)
                let b = rangeEndFormat.format(draft.showEndTime)
                return "\(a)\(rangeConnector)\(b)"
            case .seatArea:
                if draft.seatModeUnallocated { return template.unallocatedSeatLabel }
                return draft.seatArea
            case .ticketPrice:
                return draft.formattedPrice
            case .ticketType:
                return draft.ticketType
            case .serialNumber:
                return draft.serialNumber
            case .hall:
                return resolvedHallText(from: draft)
            case .qrCode, .barcode:
                return resolvedCodePayload(from: draft)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, frame, zIndex, displayName, content, fontSize, isBold, alignment
        case characterSpacing
        case isInverted, isLocked, fieldKind, dateFormat, timeFormat
        case rangeStartFormat, rangeEndFormat, rangeConnector, imageFilename
        case logoScalePercent, logoBaseWidth, logoBaseHeight
        case singleLineClip, printHeightScale, hallDisplayMode, hallNumberPrefix
        case codeContentSource, serialHRIIncludeAsterisks
    }

    init(
        id: UUID = UUID(),
        kind: MovieTicketElementKind,
        frame: SequencePlaceholderFrame,
        zIndex: Int = 0,
        displayName: String = "",
        content: String = "",
        fontSize: CGFloat = 11,
        isBold: Bool = false,
        alignment: Int = 0,
        characterSpacing: Int = 0,
        isInverted: Bool = false,
        isLocked: Bool = false,
        fieldKind: MovieTicketFieldKind? = nil,
        dateFormat: MovieTicketDateFormat = .eeeMMMd,
        timeFormat: MovieTicketTimeFormat = .hmma,
        rangeStartFormat: MovieTicketTimeFormat = .hmma,
        rangeEndFormat: MovieTicketTimeFormat = .hmma,
        rangeConnector: String = " - ",
        imageFilename: String? = nil,
        logoScalePercent: Double = 100,
        logoBaseWidth: CGFloat = 120,
        logoBaseHeight: CGFloat = 60,
        singleLineClip: Bool? = nil,
        printHeightScale: Int? = nil,
        hallDisplayMode: MovieTicketHallDisplayMode? = nil,
        hallNumberPrefix: String? = nil,
        codeContentSource: MovieTicketCodeContentSource? = nil,
        serialHRIIncludeAsterisks: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.zIndex = zIndex
        self.displayName = displayName
        self.content = content
        self.fontSize = fontSize
        self.isBold = isBold
        self.alignment = alignment
        self.characterSpacing = max(0, min(32, characterSpacing))
        self.isInverted = isInverted
        self.isLocked = isLocked
        self.fieldKind = fieldKind
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
        self.rangeStartFormat = rangeStartFormat
        self.rangeEndFormat = rangeEndFormat
        self.rangeConnector = rangeConnector
        self.imageFilename = imageFilename
        self.logoScalePercent = logoScalePercent
        self.logoBaseWidth = logoBaseWidth
        self.logoBaseHeight = logoBaseHeight
        self.singleLineClip = singleLineClip
        self.printHeightScale = printHeightScale.map { max(1, min(3, $0)) }
        self.hallDisplayMode = hallDisplayMode
        self.hallNumberPrefix = hallNumberPrefix
        self.codeContentSource = codeContentSource
        self.serialHRIIncludeAsterisks = serialHRIIncludeAsterisks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(MovieTicketElementKind.self, forKey: .kind)
        frame = try c.decode(SequencePlaceholderFrame.self, forKey: .frame)
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 11
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        alignment = try c.decodeIfPresent(Int.self, forKey: .alignment) ?? 0
        characterSpacing = max(0, min(32, try c.decodeIfPresent(Int.self, forKey: .characterSpacing) ?? 0))
        isInverted = try c.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        fieldKind = try c.decodeIfPresent(MovieTicketFieldKind.self, forKey: .fieldKind)
        dateFormat = try c.decodeIfPresent(MovieTicketDateFormat.self, forKey: .dateFormat) ?? .eeeMMMd
        timeFormat = try c.decodeIfPresent(MovieTicketTimeFormat.self, forKey: .timeFormat) ?? .hmma
        rangeStartFormat = try c.decodeIfPresent(MovieTicketTimeFormat.self, forKey: .rangeStartFormat) ?? .hmma
        rangeEndFormat = try c.decodeIfPresent(MovieTicketTimeFormat.self, forKey: .rangeEndFormat) ?? .hmma
        rangeConnector = try c.decodeIfPresent(String.self, forKey: .rangeConnector) ?? " - "
        imageFilename = try c.decodeIfPresent(String.self, forKey: .imageFilename)
        logoScalePercent = try c.decodeIfPresent(Double.self, forKey: .logoScalePercent) ?? 100
        logoBaseWidth = try c.decodeIfPresent(CGFloat.self, forKey: .logoBaseWidth) ?? 120
        logoBaseHeight = try c.decodeIfPresent(CGFloat.self, forKey: .logoBaseHeight) ?? 60
        singleLineClip = try c.decodeIfPresent(Bool.self, forKey: .singleLineClip)
        if let h = try c.decodeIfPresent(Int.self, forKey: .printHeightScale) {
            printHeightScale = max(1, min(3, h))
        } else {
            printHeightScale = nil
        }
        hallDisplayMode = try c.decodeIfPresent(MovieTicketHallDisplayMode.self, forKey: .hallDisplayMode)
        hallNumberPrefix = try c.decodeIfPresent(String.self, forKey: .hallNumberPrefix)
        codeContentSource = try c.decodeIfPresent(MovieTicketCodeContentSource.self, forKey: .codeContentSource)
        serialHRIIncludeAsterisks = try c.decodeIfPresent(Bool.self, forKey: .serialHRIIncludeAsterisks)
    }

    /// Digits from a hall string (`Screen 2` / `Cinema 1` / `IMAX 1` → `2` / `1` / `1`).
    static func extractHallNumber(from raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if let re = try? NSRegularExpression(pattern: #"(\d+)\s*$"#),
           let match = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(match.range(at: 1), in: t) {
            return String(t[r])
        }
        return String(t.filter(\.isNumber))
    }

    /// Printed hall text for this element (or raw draft hall when not a hall field).
    func resolvedHallText(from draft: MovieTicketDraft) -> String {
        let raw = draft.hall.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fieldKind == .hall else { return raw }
        let mode = hallDisplayMode ?? .cinemaNumber
        switch mode {
        case .asRecognized:
            return raw
        case .numberOnly:
            let n = Self.extractHallNumber(from: raw)
            return n.isEmpty ? raw : n
        case .cinemaNumber:
            let n = Self.extractHallNumber(from: raw)
            return n.isEmpty ? raw : "Cinema \(n)"
        case .customPrefix:
            let n = Self.extractHallNumber(from: raw)
            guard !n.isEmpty else { return raw }
            let prefix = hallNumberPrefix ?? ""
            if prefix.isEmpty { return n }
            if prefix.last?.isWhitespace == true { return prefix + n }
            return prefix + " " + n
        }
    }

    /// Raw payload for QR/barcode before layout-specific formatting (e.g. barcode digit filter).
    func resolvedCodePayload(from draft: MovieTicketDraft) -> String {
        switch codeContentSource ?? .serialNumber {
        case .custom:
            let key = id.uuidString
            return (draft.customCodePayloads[key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .serialNumber:
            let booking = draft.bookingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if fieldKind == .qrCode, !booking.isEmpty { return booking }
            return draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var usesCustomCodePayload: Bool {
        (fieldKind == .qrCode || fieldKind == .barcode)
            && (codeContentSource ?? .serialNumber) == .custom
    }
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
    /// Background image offset in paper points (top-leading origin). Optional for old templates.
    var backgroundOffsetX: CGFloat? = nil
    var backgroundOffsetY: CGFloat? = nil
    /// Shown on ticket when main page selects 无特定座位.
    var unallocatedSeatLabel: String = "ADMIT"
    var pdfRuleId: UUID?
    /// Native print layout: `ritz` (locked dual-stub), `imaxSydney`, or nil/`canvas` (WYSIWYG elements).
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

    /// Locked Ritz dual-stub ESC/POS path (not canvas WYSIWYG).
    var usesRitzLayout: Bool {
        if usesIMAXSydneyLayout || usesOrpheumLayout || usesDendyLayout { return false }
        if layoutStyle == "ritz" { return true }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.caseInsensitiveCompare("Ritz") == .orderedSame { return true }
        if n == "示例影票" { return true }
        return false
    }

    var usesOrpheumLayout: Bool {
        if layoutStyle == "orpheum" { return true }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.localizedCaseInsensitiveContains("orpheum")
            || n.localizedCaseInsensitiveContains("hayden")
    }

    var usesDendyLayout: Bool {
        if layoutStyle == "dendy" { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("dendy")
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
            t.backgroundOffsetX = meta.backgroundOffsetX
            t.backgroundOffsetY = meta.backgroundOffsetY
            t.feedLinesBeforeCut = meta.feedLinesBeforeCut
            return (t, made.logoElementId)
        }
        if meta.usesOrpheumLayout {
            var t = makeOrpheum(name: meta.name)
            t.id = meta.id
            t.createdAt = meta.createdAt
            t.pdfRuleId = meta.pdfRuleId
            t.backgroundImageFilename = meta.backgroundImageFilename
            t.backgroundScalePercent = meta.backgroundScalePercent
            t.backgroundOffsetX = meta.backgroundOffsetX
            t.backgroundOffsetY = meta.backgroundOffsetY
            t.feedLinesBeforeCut = meta.feedLinesBeforeCut
            t.unallocatedSeatLabel = meta.unallocatedSeatLabel.isEmpty ? t.unallocatedSeatLabel : meta.unallocatedSeatLabel
            return (t, nil)
        }
        if meta.usesDendyLayout {
            var t = makeDendy(name: meta.name)
            t.id = meta.id
            t.createdAt = meta.createdAt
            t.pdfRuleId = meta.pdfRuleId
            t.backgroundImageFilename = meta.backgroundImageFilename
            t.backgroundScalePercent = meta.backgroundScalePercent
            t.backgroundOffsetX = meta.backgroundOffsetX
            t.backgroundOffsetY = meta.backgroundOffsetY
            t.feedLinesBeforeCut = meta.feedLinesBeforeCut
            t.unallocatedSeatLabel = meta.unallocatedSeatLabel.isEmpty ? t.unallocatedSeatLabel : meta.unallocatedSeatLabel
            return (t, nil)
        }
        var t = makeRitz(name: meta.name)
        t.id = meta.id
        t.createdAt = meta.createdAt
        t.pdfRuleId = meta.pdfRuleId
        t.backgroundImageFilename = meta.backgroundImageFilename
        t.backgroundScalePercent = meta.backgroundScalePercent
        t.backgroundOffsetX = meta.backgroundOffsetX
        t.backgroundOffsetY = meta.backgroundOffsetY
        t.feedLinesBeforeCut = meta.feedLinesBeforeCut
        t.unallocatedSeatLabel = meta.unallocatedSeatLabel.isEmpty ? t.unallocatedSeatLabel : meta.unallocatedSeatLabel
        return (t, nil)
    }

    /// Empty canvas for 「新建模板」— user adds fields from the toolbar.
    static func makeBlank(name: String = "新影票模板") -> MovieTicketTemplate {
        var t = MovieTicketTemplate(name: name)
        t.layoutStyle = "canvas"
        t.unallocatedSeatLabel = "ADMIT"
        t.canvasHeight = 450
        t.gridSize = 20
        t.feedLinesBeforeCut = 4
        t.elements = []
        return t
    }

    /// Ritz Cinemas dual-stub layout (tear-off stub + barcode stub), matching thermal ticket style.
    static func makeRitz(name: String = "示例影票") -> MovieTicketTemplate {
        var t = MovieTicketTemplate(name: name)
        t.layoutStyle = "ritz"
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

    /// Hayden Orpheum dual-stub: venue + Cinema highlight, title, session, ADMIT / type·price.
    static func makeOrpheum(name: String = "Orpheum") -> MovieTicketTemplate {
        var t = MovieTicketTemplate(name: name)
        t.layoutStyle = "orpheum"
        t.unallocatedSeatLabel = "ADMIT"
        t.canvasHeight = 430
        t.gridSize = 20
        t.feedLinesBeforeCut = 4
        var z = 0
        func nextZ() -> Int {
            z += 1
            return z
        }

        t.elements += orpheumStubElements(yOffset: 4, zBase: &z, includeBarcode: false)
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
        t.elements += orpheumStubElements(yOffset: 172, zBase: &z, includeBarcode: true)
        t.canvasHeight = 450
        return t
    }

    /// Dendy Cinemas vertical QR ticket (title → cinema/seat → session → QR → codes).
    /// Title + cinema/seat default to print scale 2×3 (between prior 3×3 and plain 2×2).
    static func makeDendy(name: String = "Dendy") -> MovieTicketTemplate {
        var t = MovieTicketTemplate(name: name)
        t.layoutStyle = "dendy"
        t.unallocatedSeatLabel = "GA"
        t.canvasHeight = 560
        t.gridSize = 20
        t.feedLinesBeforeCut = 4
        var z = 0
        func nextZ() -> Int {
            z += 1
            return z
        }
        let left: CGFloat = 16
        let width: CGFloat = 270
        // Paper-point heights ≈ Font A cell × scale on 80mm (see MovieTicketPrintMetrics).
        let h3: CGFloat = 38
        let h2: CGFloat = 25
        let h1: CGFloat = 13

        t.elements = [
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 16, width: width, height: h3 * 2),
                zIndex: nextZ(),
                fontSize: 14,
                isBold: true,
                alignment: 1,
                fieldKind: .movieTitle,
                singleLineClip: false
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 100, width: 130, height: h3),
                zIndex: nextZ(),
                fontSize: 14,
                alignment: 1,
                fieldKind: .hall,
                hallDisplayMode: .cinemaNumber
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 156, y: 100, width: 130, height: h3),
                zIndex: nextZ(),
                fontSize: 14,
                alignment: 1,
                fieldKind: .seatArea
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 148, width: width, height: h2),
                zIndex: nextZ(),
                fontSize: 14,
                alignment: 1,
                fieldKind: .showDate,
                dateFormat: .MMMMdyyyy
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 178, width: width, height: h2),
                zIndex: nextZ(),
                fontSize: 14,
                alignment: 1,
                fieldKind: .startTime,
                timeFormat: .hmma
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 210, width: width, height: h1),
                zIndex: nextZ(),
                content: "Ends at ",
                fontSize: 11,
                alignment: 1,
                fieldKind: .endTime,
                timeFormat: .hmma
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 66, y: 240, width: 170, height: 170),
                zIndex: nextZ(),
                alignment: 1,
                fieldKind: .qrCode
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 422, width: width, height: h2),
                zIndex: nextZ(),
                content: "Code: #",
                fontSize: 14,
                alignment: 1,
                fieldKind: .serialNumber
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: 456, width: width, height: h2),
                zIndex: nextZ(),
                fontSize: 11,
                isBold: true,
                alignment: 1,
                fieldKind: .ticketType
            ),
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: 490, width: width, height: h1),
                zIndex: nextZ(),
                content: "Ticket #{serial}",
                fontSize: 11,
                alignment: 1
            )
        ]
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
                fieldKind: .hall,
                // IMAX tickets print hall as recognized (e.g. "IMAX 1"), not "Cinema 1".
                hallDisplayMode: .asRecognized
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

    /// One Orpheum ticket half (matches classic `OrpheumTicketRenderer` layout).
    private static func orpheumStubElements(
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
        var items: [MovieTicketElement] = [
            // Venue left + hall number (inverted) right — same row as classic Orpheum.
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: left, y: yOffset, width: 150, height: 28),
                zIndex: z(),
                content: "Orpheum",
                fontSize: 16,
                isBold: true,
                alignment: 0
            ),
            MovieTicketElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: 170, y: yOffset + 6, width: 70, height: 18),
                zIndex: z(),
                content: "Cinema",
                fontSize: 12,
                alignment: 2
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 242, y: yOffset + 4, width: 52, height: 22),
                zIndex: z(),
                fontSize: 14,
                isBold: true,
                alignment: 1,
                isInverted: true,
                fieldKind: .hall,
                hallDisplayMode: .numberOnly
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 34, width: width, height: 36),
                zIndex: z(),
                fontSize: 14,
                isBold: true,
                alignment: 1,
                fieldKind: .movieTitle,
                singleLineClip: true
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 74, width: width, height: 16),
                zIndex: z(),
                fontSize: 11,
                alignment: 0,
                fieldKind: .timeRange,
                rangeStartFormat: .eeeMMMdhmma,
                rangeEndFormat: .hmma,
                rangeConnector: " Until "
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: left, y: yOffset + 96, width: 70, height: 14),
                zIndex: z(),
                fontSize: 11,
                isBold: true,
                alignment: 0,
                fieldKind: .seatArea
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 150, y: yOffset + 96, width: 80, height: 14),
                zIndex: z(),
                fontSize: 11,
                alignment: 2,
                fieldKind: .ticketType
            ),
            MovieTicketElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 232, y: yOffset + 96, width: 62, height: 14),
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
        case .positionOnly: return L10n.ui("仅记住位置")
        case .withKeywords: return L10n.ui("识别关键词")
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
        case .entire: return L10n.ui("全部文字")
        case .afterKeyword: return L10n.ui("关键词之后")
        case .currency: return L10n.ui("金额")
        case .digits: return L10n.ui("数字")
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
    /// Text inserted before the recognized value when filling the draft / print string.
    var printPrefix: String = ""
    /// Text appended after the recognized value when filling the draft / print string.
    var printSuffix: String = ""
    /// Auto-detect / page-wide rules: do not draw a rubber-band box on the PDF canvas.
    var isPageWideAuto: Bool = false
    /// For `.timeRange` / `.startTime`: when true, keep calendar date in the extract and
    /// write `draft.showDate` (unless a dedicated date region already hit).
    /// `nil` / false = clock only (legacy default).
    var recognizeDate: Bool? = nil

    /// Effective flag for time fields (default off = clock-only).
    var recognizesDateWithTime: Bool { recognizeDate == true }

    enum CodingKeys: String, CodingKey {
        case id, fieldKind, elementId, rect, pageIndex, captureMode, regionKeywords
        case extractKind, extractKeyword, extractSample, extractedHint, valueMappings
        case printPrefix, printSuffix, isPageWideAuto, recognizeDate
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
        valueMappings: [MovieTicketPDFValueMapping] = [],
        printPrefix: String = "",
        printSuffix: String = "",
        isPageWideAuto: Bool = false,
        recognizeDate: Bool? = nil
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
        self.printPrefix = printPrefix
        self.printSuffix = printSuffix
        self.isPageWideAuto = isPageWideAuto
        self.recognizeDate = recognizeDate
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
        printPrefix = try c.decodeIfPresent(String.self, forKey: .printPrefix) ?? ""
        printSuffix = try c.decodeIfPresent(String.self, forKey: .printSuffix) ?? ""
        if let flagged = try c.decodeIfPresent(Bool.self, forKey: .isPageWideAuto) {
            isPageWideAuto = flagged
        } else {
            // Legacy auto regions used a near-full-page rect.
            isPageWideAuto = rect.width >= 0.9 && rect.height >= 0.9
        }
        recognizeDate = try c.decodeIfPresent(Bool.self, forKey: .recognizeDate)
    }

    /// Whether this region should draw/hit-test as a blue box on the sample PDF.
    var showsCanvasBox: Bool {
        if isPageWideAuto { return false }
        return !(rect.width >= 0.9 && rect.height >= 0.9)
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
    /// When true, PDF import never searches/fills seat — treat as 无指定座位.
    var skipSeatRecognition: Bool = false
    /// Used when ticket-type region misses or is absent.
    var defaultTicketType: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, detectorKeywords, regions, linkedTemplateId
        case samplePDFFilename, samplePageWidth, samplePageHeight
        case skipSeatRecognition, defaultTicketType
        case createdAt, updatedAt
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
        skipSeatRecognition: Bool = false,
        defaultTicketType: String = "",
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
        self.skipSeatRecognition = skipSeatRecognition
        self.defaultTicketType = defaultTicketType
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
        skipSeatRecognition = try c.decodeIfPresent(Bool.self, forKey: .skipSeatRecognition) ?? false
        defaultTicketType = try c.decodeIfPresent(String.self, forKey: .defaultTicketType) ?? ""
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
        if title.isEmpty { return L10n.ui("（无片名）") }
        return title
    }
}
