import Foundation

/// Editable fields for cinema admission tickets (Orpheum-style).
/// Ad duration and movie duration are used for end-time calculation only — not printed directly.
struct MovieTicketData: Codable, Equatable {
    var venueName: String = "Orpheum"
    var hallNumber: String = "4"
    var movieTitle: String = "Dunkirk 70mm"
    var showStartTime: Date = MovieTicketData.defaultShowStart
    var adDurationMinutes: Int = 0
    var movieDurationMinutes: Int = 117
    var ticketType: String = "Adult"
    var ticketPrice: String = "28.00"
    var barcodeBase: String = "00687743"
    var ticketSerial: String = "001"

    static let defaultShowStart: Date = {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = .current
        components.year = 2026
        components.month = 6
        components.day = 28
        components.hour = 18
        components.minute = 0
        return components.date ?? Date()
    }()

    static var sample: MovieTicketData { MovieTicketData() }

    var totalDurationMinutes: Int { max(0, adDurationMinutes) + max(0, movieDurationMinutes) }

    var showEndTime: Date {
        Calendar.current.date(byAdding: .minute, value: totalDurationMinutes, to: showStartTime) ?? showStartTime
    }

    var normalizedBarcodeBase: String {
        Self.padDigits(barcodeBase, length: 8)
    }

    var normalizedTicketSerial: String {
        Self.padDigits(ticketSerial, length: 3)
    }

    var barcode: String {
        normalizedBarcodeBase + normalizedTicketSerial
    }

    var ticketCode: String {
        "DEBI \(normalizedBarcodeBase)/\(normalizedTicketSerial)"
    }

    var barcodeLabel: String {
        let core = "\(normalizedBarcodeBase)/\(normalizedTicketSerial)"
        let spaced = core.map { String($0) }.joined(separator: " ")
        return "* \(spaced) *"
    }

    var formattedTicketPrice: String {
        let trimmed = ticketPrice.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$") { return trimmed }
        if let value = Double(trimmed.filter { $0.isNumber || $0 == "." }) {
            return String(format: "$%.2f", value)
        }
        return "$\(trimmed)"
    }

    private static let displayTimeZone: TimeZone = .current

    var showDateTime: String {
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "en_US_POSIX")
        startFormatter.timeZone = Self.displayTimeZone
        startFormatter.dateFormat = "EEE MMM d, yyyy hh:mm a"

        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        endFormatter.timeZone = Self.displayTimeZone
        endFormatter.dateFormat = "h:mm a"

        return "\(startFormatter.string(from: showStartTime)) Until \(endFormatter.string(from: showEndTime))"
    }

    /// Keys stored in template `defaultData` (input fields only).
    func storageDictionary() -> [String: String] {
        [
            "venueName": venueName,
            "hallNumber": hallNumber,
            "movieTitle": movieTitle,
            "showStartISO": Self.isoFormatter.string(from: showStartTime),
            "adDurationMinutes": String(adDurationMinutes),
            "movieDurationMinutes": String(movieDurationMinutes),
            "ticketType": ticketType,
            "ticketPrice": ticketPrice,
            "barcodeBase": normalizedBarcodeBase,
            "ticketSerial": normalizedTicketSerial
        ]
    }

    /// Full dictionary for template rendering / preview.
    func renderedDictionary() -> [String: String] {
        var data = storageDictionary()
        data["showDateTime"] = showDateTime
        data["ticketPrice"] = formattedTicketPrice
        data["barcode"] = barcode
        data["ticketCode"] = ticketCode
        data["barcodeLabel"] = barcodeLabel
        return data
    }

    mutating func syncBarcodeFromFullCode(_ full: String) {
        let digits = full.filter(\.isNumber)
        guard digits.count >= 3 else { return }
        ticketSerial = Self.padDigits(String(digits.suffix(3)), length: 3)
        barcodeBase = Self.padDigits(String(digits.dropLast(3).suffix(8)), length: 8)
    }

    mutating func syncFromTicketCode(_ code: String) {
        let trimmed = code.replacingOccurrences(of: "DEBI", with: "").trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        barcodeBase = Self.padDigits(parts[0].filter(\.isNumber), length: 8)
        ticketSerial = Self.padDigits(parts[1].filter(\.isNumber), length: 3)
    }

    static func from(dictionary: [String: String]) -> MovieTicketData {
        var ticket = MovieTicketData.sample

        if let value = dictionary["venueName"] { ticket.venueName = value }
        if let value = dictionary["hallNumber"] { ticket.hallNumber = value }
        if let value = dictionary["movieTitle"] { ticket.movieTitle = value }
        if let value = dictionary["ticketType"] { ticket.ticketType = value }
        if let value = dictionary["ticketPrice"] {
            ticket.ticketPrice = value.replacingOccurrences(of: "$", with: "")
        }
        if let value = dictionary["adDurationMinutes"], let minutes = Int(value) {
            ticket.adDurationMinutes = minutes
        }
        if let value = dictionary["movieDurationMinutes"], let minutes = Int(value) {
            ticket.movieDurationMinutes = minutes
        }
        if let iso = dictionary["showStartISO"], let date = isoFormatter.date(from: iso) {
            ticket.showStartTime = date
        }
        if let base = dictionary["barcodeBase"] {
            ticket.barcodeBase = padDigits(base, length: 8)
        }
        if let serial = dictionary["ticketSerial"] {
            ticket.ticketSerial = padDigits(serial, length: 3)
        } else if let barcode = dictionary["barcode"] {
            ticket.syncBarcodeFromFullCode(barcode)
        } else if let code = dictionary["ticketCode"] {
            ticket.syncFromTicketCode(code)
        }

        return ticket
    }

    static func isMovieTicketTemplate(_ template: ReceiptTemplate) -> Bool {
        if template.name.localizedCaseInsensitiveContains("orpheum") { return true }
        if template.name.localizedCaseInsensitiveContains("电影票") { return true }
        let keys = Set(template.allPlaceholderKeys())
        return keys.contains("movieTitle") || keys.contains("showDateTime") || keys.contains("venueName")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func padDigits(_ raw: String, length: Int) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.isEmpty { return String(repeating: "0", count: length) }
        if digits.count >= length { return String(digits.suffix(length)) }
        return String(repeating: "0", count: length - digits.count) + digits
    }
}
