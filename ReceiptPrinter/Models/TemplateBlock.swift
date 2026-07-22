import Foundation

enum BlockType: String, Codable, CaseIterable, Identifiable {
    case text, line, spacer, image, barcode, qr, table, row

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return L10n.ui("文本")
        case .line: return L10n.ui("分隔线")
        case .spacer: return L10n.ui("空白")
        case .image: return L10n.ui("图片")
        case .barcode: return L10n.ui("条码")
        case .qr: return L10n.ui("二维码")
        case .table: return L10n.ui("表格")
        case .row: return L10n.ui("左右行")
        }
    }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return L10n.ui("左对齐")
        case .center: return L10n.ui("居中")
        case .right: return L10n.ui("右对齐")
        }
    }
}

enum TextSize: String, Codable, CaseIterable, Identifiable {
    case normal, tall, taller, double, doubleTall
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return L10n.ui("标准")
        case .tall: return L10n.ui("加高")
        case .taller: return L10n.ui("加高×3")
        case .double: return L10n.ui("双倍大小")
        case .doubleTall: return L10n.ui("双宽×加高×3")
        }
    }
}

enum BarcodeType: String, Codable, CaseIterable, Identifiable {
    case code128, ean13
    var id: String { rawValue }
}

struct TemplateBlock: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: BlockType
    var content: String = ""
    var align: TextAlign = .left
    var size: TextSize = .normal
    var bold: Bool = false
    var underline: Bool = false
    var reverse: Bool = false
    var rightBold: Bool = false
    var rightSize: TextSize = .normal
    var spacerLines: Int = 1
    var barcodeType: BarcodeType = .code128
    var imagePath: String?
    var tableColumns: [String] = []
    var dataSource: String?
    var rightContent: String = ""
    var rightHighlight: String = ""
    var barcodeHeight: UInt8 = 80
    var barcodeWidth: UInt8 = 2
    var barcodePrintHRI: Bool = true
    var confidence: Double?

    static func text(_ content: String, align: TextAlign = .left, size: TextSize = .normal, bold: Bool = false) -> TemplateBlock {
        TemplateBlock(type: .text, content: content, align: align, size: size, bold: bold)
    }

    static func line(char: String = "-") -> TemplateBlock {
        TemplateBlock(type: .line, content: char)
    }
    static func spacer(_ lines: Int = 1) -> TemplateBlock { TemplateBlock(type: .spacer, spacerLines: lines) }
    static func qr(_ content: String) -> TemplateBlock { TemplateBlock(type: .qr, content: content, align: .center) }
    static func barcode(
        _ content: String,
        type: BarcodeType = .code128,
        height: UInt8 = 80,
        width: UInt8 = 2,
        printHRI: Bool = true
    ) -> TemplateBlock {
        TemplateBlock(
            type: .barcode,
            content: content,
            align: .center,
            barcodeType: type,
            barcodeHeight: height,
            barcodeWidth: width,
            barcodePrintHRI: printHRI
        )
    }

    static func row(
        left: String,
        right: String = "",
        highlight: String = "",
        size: TextSize = .normal,
        bold: Bool = false
    ) -> TemplateBlock {
        TemplateBlock(
            type: .row,
            content: left,
            size: size,
            bold: bold,
            rightContent: right,
            rightHighlight: highlight
        )
    }
}
