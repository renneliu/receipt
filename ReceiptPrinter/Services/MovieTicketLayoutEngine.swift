import Foundation
import CoreGraphics

enum MovieTicketLayoutEngine {
    struct PlacedText: Equatable {
        var text: String
        var frame: SequencePlaceholderFrame
        var fontSize: CGFloat
        var isBold: Bool
        var alignment: Int
        var isInverted: Bool
        var asOverlay: Bool = true
        /// Thermal double-height stretch for movie titles.
        var verticalScale: CGFloat = 1
    }

    struct PlacedBarcode: Equatable {
        var text: String
        var frame: SequencePlaceholderFrame
        var asQR: Bool
    }

    struct PlacedLogo: Equatable {
        var elementId: UUID
        var frame: SequencePlaceholderFrame
    }

    struct Layout: Equatable {
        var canvasHeight: CGFloat
        var texts: [PlacedText]
        var barcodes: [PlacedBarcode]
        var logos: [PlacedLogo]
    }

    static func expand(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        now: Date = Date()
    ) -> Layout {
        var texts: [PlacedText] = []
        var barcodes: [PlacedBarcode] = []
        var logos: [PlacedLogo] = []

        for el in template.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
            switch el.kind {
            case .logo:
                logos.append(PlacedLogo(elementId: el.id, frame: el.frame))
            case .textBox:
                texts.append(PlacedText(
                    text: el.content,
                    frame: el.frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    isInverted: el.isInverted,
                    verticalScale: 2
                ))
            case .currentDate:
                texts.append(PlacedText(
                    text: el.dateFormat.format(now),
                    frame: el.frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    isInverted: el.isInverted
                ))
            case .currentTime:
                texts.append(PlacedText(
                    text: el.timeFormat.format(now),
                    frame: el.frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    isInverted: el.isInverted
                ))
            case .fieldPlaceholder:
                guard let kind = el.fieldKind else { continue }
                switch kind {
                case .qrCode:
                    let content = draft.serialNumber.trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty {
                        barcodes.append(PlacedBarcode(text: content, frame: el.frame, asQR: true))
                    }
                case .barcode:
                    let content = draft.serialNumber.trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty {
                        barcodes.append(PlacedBarcode(text: content, frame: el.frame, asQR: false))
                    }
                default:
                    let value = resolvedValue(kind: kind, element: el, draft: draft, template: template)
                    let vScale: CGFloat
                    switch kind {
                    case .movieTitle: vScale = 2 // GS ! tall
                    case .hall: vScale = 2
                    default: vScale = 1
                    }
                    texts.append(PlacedText(
                        text: value,
                        frame: el.frame,
                        fontSize: el.fontSize,
                        isBold: el.isBold,
                        alignment: el.alignment,
                        isInverted: el.isInverted,
                        verticalScale: vScale
                    ))
                }
            }
        }

        let bottoms = texts.map { $0.frame.y + $0.frame.height }
            + barcodes.map { $0.frame.y + $0.frame.height }
            + logos.map { $0.frame.y + $0.frame.height }
        let inkBottom = bottoms.max() ?? 0
        let height = max(template.canvasHeight, inkBottom + 24)
        return Layout(canvasHeight: height, texts: texts, barcodes: barcodes, logos: logos)
    }

    private static func resolvedValue(
        kind: MovieTicketFieldKind,
        element: MovieTicketElement,
        draft: MovieTicketDraft,
        template: MovieTicketTemplate
    ) -> String {
        switch kind {
        case .movieTitle:
            return draft.printedMovieTitle
        case .startTime:
            return element.timeFormat.format(draft.combinedStart)
        case .endTime:
            let body = element.timeFormat.format(draft.showEndTime)
            if element.content.isEmpty { return body }
            return element.content + body
        case .timeRange:
            let a = element.rangeStartFormat.format(draft.combinedStart)
            let b = element.rangeEndFormat.format(draft.showEndTime)
            return "\(a)\(element.rangeConnector)\(b)"
        case .showDate:
            return element.dateFormat.format(draft.showDate)
        case .seatArea:
            if draft.seatModeUnallocated {
                return template.unallocatedSeatLabel
            }
            return draft.seatArea
        case .ticketPrice:
            return draft.formattedPrice
        case .ticketType:
            return draft.ticketType
        case .serialNumber:
            return draft.serialNumber
        case .hall:
            return element.resolvedHallText(from: draft)
        case .qrCode, .barcode:
            return draft.serialNumber
        }
    }
}
