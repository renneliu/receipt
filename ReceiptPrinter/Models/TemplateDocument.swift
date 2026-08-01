import Foundation

enum TemplateCategory: String, Codable, CaseIterable, Identifiable {
    case movieTicket = "Movie Ticket"
    case receipt = "Receipt"
    case label = "Label"
    case custom = "Custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .movieTicket: return L10n.ui("电影票")
        case .receipt: return L10n.ui("小票")
        case .label: return L10n.ui("标签")
        case .custom: return L10n.ui("自定义")
        }
    }
}

enum PlaceholderBindingSource: String, Codable {
    case manual
    /// Legacy value kept for decoding older templates; Gmail binding is no longer used.
    case gmail
    case calculated
    case movie
    case datetime
}

struct PlaceholderDefinition: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var source: PlaceholderBindingSource = .manual
    var defaultValue: String = ""
}

struct TemplateElement: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: TemplateElementKind
    var frame: ElementFrame
    var zIndex: Int = 0
    var content: String = ""
    var bindingKey: String?
}

enum TemplateElementKind: String, Codable {
    case text, image, line, barcode, qr
}

struct ElementFrame: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 200
    var height: CGFloat = 24
}

struct TemplateDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var category: TemplateCategory = .custom
    var paperWidthMM: Int = 80
    var canvasHeight: CGFloat = 800
    var elements: [TemplateElement] = []
    var bindings: [PlaceholderDefinition] = []
    var defaultData: [String: String] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    mutating func touch() {
        updatedAt = Date()
    }
}

enum TemplateDocumentMigration {
    /// Adapts legacy block-flow template into a document with stacked elements.
    static func fromReceiptTemplate(_ template: ReceiptTemplate) -> TemplateDocument {
        var y: CGFloat = 8
        var elements: [TemplateElement] = []
        for (index, block) in template.blocks.enumerated() {
            let height: CGFloat = switch block.type {
            case .text, .row: 28
            case .line: 12
            case .spacer: CGFloat(block.spacerLines * 12)
            case .barcode: CGFloat(block.barcodeHeight) + 8
            case .qr, .image: 120
            case .table: 60
            }
            elements.append(TemplateElement(
                kind: elementKind(for: block.type),
                frame: ElementFrame(x: 4, y: y, width: 560, height: height),
                zIndex: index,
                content: block.content,
                bindingKey: block.dataSource
            ))
            y += height + 6
        }
        var category: TemplateCategory = .receipt
        if MovieTicketData.isMovieTicketTemplate(template) {
            category = .movieTicket
        }
        return TemplateDocument(
            id: template.id,
            name: template.name,
            category: category,
            paperWidthMM: template.paperWidth,
            elements: elements,
            defaultData: template.defaultData,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt
        )
    }

    /// Best-effort reverse migration for persistence as ReceiptTemplate.
    static func toReceiptTemplate(_ document: TemplateDocument) -> ReceiptTemplate {
        let sorted = document.elements.sorted { $0.zIndex < $1.zIndex }
        let blocks: [TemplateBlock] = sorted.map { element in
            var block = TemplateBlock(type: blockType(for: element.kind), content: element.content)
            block.dataSource = element.bindingKey
            return block
        }
        return ReceiptTemplate(
            id: document.id,
            name: document.name,
            paperWidth: document.paperWidthMM,
            blocks: blocks.isEmpty ? [TemplateBlock(type: .text, content: "")] : blocks,
            defaultData: document.defaultData,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        )
    }

    private static func elementKind(for type: BlockType) -> TemplateElementKind {
        switch type {
        case .text, .row, .table, .spacer: .text
        case .line: .line
        case .barcode: .barcode
        case .qr: .qr
        case .image: .image
        }
    }

    private static func blockType(for kind: TemplateElementKind) -> BlockType {
        switch kind {
        case .text: .text
        case .line: .line
        case .barcode: .barcode
        case .qr: .qr
        case .image: .image
        }
    }
}
