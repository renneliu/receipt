import Foundation
import CoreGraphics

// MARK: - Line item & settings

struct POSLineItem: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var code: String = ""
    var name: String = ""
    var quantity: String = ""
    var amount: String = ""
}

struct POSReceiptSettings: Codable, Equatable {
    var activeTemplateId: UUID?
    /// `"main"` or `"template"`
    var lastPane: String = "main"

    private static let defaultsKey = "ReceiptPrinter.POSReceiptSettings"

    static func load() -> POSReceiptSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(POSReceiptSettings.self, from: data) else {
            return POSReceiptSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Field kinds

enum POSFieldKind: String, Codable, CaseIterable, Identifiable {
    case code
    case name
    case quantity
    case amount
    case quantitySubtotal
    case amountSubtotal
    case surcharge
    case amountTotal
    /// Count of line items on the ticket (printable summary).
    case itemCount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .code: return L10n.ui("编号")
        case .name: return L10n.ui("项目名称")
        case .quantity: return L10n.ui("数量")
        case .amount: return L10n.ui("金额")
        case .quantitySubtotal: return L10n.ui("数量小计")
        case .amountSubtotal: return L10n.ui("金额小计")
        case .surcharge: return L10n.ui("附加费")
        case .amountTotal: return L10n.ui("金额合计")
        case .itemCount: return L10n.ui("总计")
        }
    }

    /// Row fields that define the repeating band.
    var isLineField: Bool {
        switch self {
        case .code, .name, .quantity, .amount: return true
        default: return false
        }
    }

    var isSummaryField: Bool {
        switch self {
        case .quantitySubtotal, .amountSubtotal, .surcharge, .amountTotal, .itemCount: return true
        default: return false
        }
    }
}

enum POSDateFormatStyle: String, Codable, CaseIterable, Identifiable {
    case ymdDash = "yyyy-MM-dd"
    case ymdCN = "yyyy年M月d日"
    case mdYSlash = "MM/dd/yyyy"
    case dMyDot = "dd.MM.yyyy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ymdDash: return "2026-07-15"
        case .ymdCN: return L10n.ui("2026年7月15日")
        case .mdYSlash: return "07/15/2026"
        case .dMyDot: return "15.07.2026"
        }
    }

    func format(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        switch self {
        case .ymdDash: f.dateFormat = "yyyy-MM-dd"
        case .ymdCN: f.dateFormat = "yyyy年M月d日"
        case .mdYSlash: f.dateFormat = "MM/dd/yyyy"
        case .dMyDot: f.dateFormat = "dd.MM.yyyy"
        }
        return f.string(from: date)
    }
}

enum POSElementKind: String, Codable {
    case textBox
    case fieldPlaceholder
    case date
    case time
    case autoNumber
    case logo
    /// Horizontal rule across the ticket (solid or dashed via `isDashed`).
    case divider
}

/// Whether a non-line element sits above the item list (header) or below it (footer).
/// When line items expand, only footer elements are pushed down.
enum POSTicketSection: String, Codable, CaseIterable, Identifiable {
    case header
    case footer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .header: return L10n.ui("头部")
        case .footer: return L10n.ui("尾部")
        }
    }
}

struct POSReceiptElement: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: POSElementKind
    var frame: SequencePlaceholderFrame
    var zIndex: Int = 0
    /// User-facing name in the element list (empty → derived title).
    var displayName: String = ""
    /// Static text for `.textBox`.
    var content: String = ""
    var fontSize: CGFloat = AttributedTextView.defaultFontSize
    var isBold: Bool = false
    var alignment: Int = 0 // 0 left, 1 center, 2 right
    /// For `.fieldPlaceholder`.
    var fieldKind: POSFieldKind?
    /// For `.date`.
    var dateFormat: POSDateFormatStyle = .ymdDash
    /// For `.autoNumber`.
    var autoNumberStart: String = "01"
    var autoNumberAsBarcode: Bool = false
    /// For `.logo` — relative filename under template folder.
    var imageFilename: String?
    var logoScalePercent: Double = 100
    var logoBaseWidth: CGFloat = 120
    var logoBaseHeight: CGFloat = 60
    /// For `.divider` — `true` = dashed (`- - -`), `false` = solid (`-----`).
    var isDashed: Bool = false
    /// When true, canvas drag / numeric X/Y cannot move this element.
    var isLocked: Bool = false
    /// Header stays fixed when items grow; footer shifts down with the item list.
    /// Ignored for 编号/项目名称/数量/金额 (repeating line fields).
    var ticketSection: POSTicketSection = .header

    /// Line fields are middle band — no header/footer control.
    var allowsTicketSection: Bool {
        if kind == .fieldPlaceholder, let fieldKind, fieldKind.isLineField {
            return false
        }
        return true
    }

    /// Sensible default when creating or migrating an element.
    static func defaultTicketSection(
        kind: POSElementKind,
        fieldKind: POSFieldKind?,
        frame: SequencePlaceholderFrame,
        nameRowY: CGFloat
    ) -> POSTicketSection {
        if let fieldKind {
            if fieldKind.isLineField { return .header }
            if fieldKind.isSummaryField { return .footer }
        }
        let cy = frame.y + frame.height / 2
        return cy > nameRowY + 20 ? .footer : .header
    }
}

struct POSExcelColumnMap: Codable, Equatable, Sendable {
    var codeHeader: String?
    var nameHeader: String?
    var quantityHeader: String?
    var amountHeader: String?
}

struct POSReceiptTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var enableCode: Bool = true
    var enableQuantity: Bool = false
    var enableAmount: Bool = false
    /// 项目名称每行汉字数；超出自动换行（打印列宽按 CJK=2 折算）。
    var nameCharsPerLine: Int = 8

    var elements: [POSReceiptElement] = []
    var canvasHeight: CGFloat = 480
    var backgroundImageFilename: String?
    var backgroundScalePercent: Double = 100

    var defaultSurcharge: String = "0"
    var gridEnabled: Bool = true
    var gridSize: CGFloat = 20

    var excelBookmarkData: Data?
    var excelDisplayName: String?
    var excelColumnMap: POSExcelColumnMap = POSExcelColumnMap()
    var excelCachedHeaders: [String] = []

    mutating func touch() { updatedAt = Date() }

    static func makeBlank(name: String = "新POS模板") -> POSReceiptTemplate {
        var t = POSReceiptTemplate(name: name)
        let rowY: CGFloat = 80
        t.enableCode = true
        t.elements = [
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: rowY, width: 56, height: 28),
                fieldKind: .code
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 72, y: rowY, width: 176, height: 28),
                fieldKind: .name
            )
        ]
        return t
    }

    func hasElement(field kind: POSFieldKind) -> Bool {
        elements.contains { $0.kind == .fieldPlaceholder && $0.fieldKind == kind }
    }

    var paperSize: CGSize {
        CGSize(width: 302, height: max(200, canvasHeight))
    }
}

// MARK: - Totals

enum POSReceiptTotals {
    static func parseNumber(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Double(trimmed) ?? 0
    }

    static func quantitySubtotal(items: [POSLineItem]) -> Double {
        items.reduce(0) { $0 + parseNumber($1.quantity) }
    }

    static func amountSubtotal(items: [POSLineItem]) -> Double {
        items.reduce(0) { $0 + parseNumber($1.amount) }
    }

    static func amountTotal(items: [POSLineItem], surcharge: String) -> Double {
        amountSubtotal(items: items) + parseNumber(surcharge)
    }

    static func itemCount(items: [POSLineItem]) -> Int {
        items.count
    }

    static func formatQuantity(_ value: Double) -> String {
        if value == floor(value) { return String(Int(value)) }
        return String(format: "%.2f", value)
    }

    static func formatAmount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
