import Foundation
import CoreGraphics

/// Expands the line-item band and computes absolute frames for a multi-line ticket.
enum POSReceiptLayoutEngine {
    struct Band: Equatable {
        var minY: CGFloat
        var maxY: CGFloat
        var height: CGFloat { max(1, maxY - minY) }
    }

    /// Pitch between items — at least one compositor line (≥28pt default font).
    static func itemPitch(template: POSReceiptTemplate) -> CGFloat {
        let frames = lineFieldFrames(template: template)
        let h = frames.map(\.height).max() ?? 28
        // defaultFontSize is 28 → metrics.lineHeight ≈ 28; keep pitch ≥ that to avoid row collapse.
        let minLine = max(28, AttributedTextView.defaultFontSize)
        return max(minLine, h + 4)
    }

    /// Printer columns for one line of 项目名称 (legacy helper; wrap now uses frame width).
    static func nameMaxColumns(template: POSReceiptTemplate) -> Int {
        max(2, template.nameCharsPerLine * 2)
    }

    /// Point width of the name slot for the given column pitch (legacy formula).
    static func nameSlotWidth(template: POSReceiptTemplate, unitWidth: CGFloat) -> CGFloat {
        CGFloat(nameMaxColumns(template: template)) * unitWidth
    }

    /// Remaining paper width for 项目名称 after fixed 编号/数量/金额 slots
    /// (preferred widths — used as default max before stealing from side columns).
    static func availableNameSlotWidth(template: POSReceiptTemplate, paperWidth: CGFloat) -> CGFloat {
        var fixed: CGFloat = 0
        var slots = 1 // name
        if template.enableCode { fixed += 52; slots += 1 }
        if template.enableQuantity { fixed += 40; slots += 1 }
        if template.enableAmount { fixed += 56; slots += 1 }
        let gaps = CGFloat(max(0, slots - 1)) * 4
        return max(36, paperWidth - 24 - fixed - gaps)
    }

    /// Resolve row column widths: honor designed 项目名称 width by shrinking
    /// 金额 → 数量 → 编号 (down to mins) before clamping the name.
    static func resolvedLineFieldWidths(template: POSReceiptTemplate) -> [(kind: POSFieldKind, width: CGFloat)] {
        let paperW = template.paperSize.width
        let margin: CGFloat = 12
        let gap: CGFloat = 4

        func currentWidth(_ kind: POSFieldKind, preferred: CGFloat, minW: CGFloat) -> CGFloat {
            guard let el = template.elements.first(where: {
                $0.kind == .fieldPlaceholder && $0.fieldKind == kind
            }) else { return preferred }
            return max(minW, el.frame.width > 1 ? el.frame.width : preferred)
        }

        var codeW = template.enableCode ? currentWidth(.code, preferred: 52, minW: 28) : 0
        var qtyW = template.enableQuantity ? currentWidth(.quantity, preferred: 40, minW: 28) : 0
        var amtW = template.enableAmount ? currentWidth(.amount, preferred: 56, minW: 28) : 0
        let designedName = template.elements.first(where: {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .name
        })?.frame.width ?? availableNameSlotWidth(template: template, paperWidth: paperW)
        var nameW = max(36, designedName > 1 ? designedName : 118)

        var slotCount = 1
        if template.enableCode { slotCount += 1 }
        if template.enableQuantity { slotCount += 1 }
        if template.enableAmount { slotCount += 1 }
        let gaps = CGFloat(max(0, slotCount - 1)) * gap
        var deficit = (margin + codeW + nameW + qtyW + amtW + gaps + margin) - paperW

        func shrink(_ value: inout CGFloat, minW: CGFloat) {
            guard deficit > 0.5, value > minW else { return }
            let take = min(deficit, value - minW)
            value -= take
            deficit -= take
        }
        shrink(&amtW, minW: 28)
        shrink(&qtyW, minW: 28)
        shrink(&codeW, minW: 28)
        if deficit > 0.5 {
            nameW = max(36, nameW - deficit)
            deficit = 0
        }

        var out: [(POSFieldKind, CGFloat)] = []
        if template.enableCode { out.append((.code, codeW)) }
        out.append((.name, nameW))
        if template.enableQuantity { out.append((.quantity, qtyW)) }
        if template.enableAmount { out.append((.amount, amtW)) }
        return out
    }

    static func rowY(template: POSReceiptTemplate) -> CGFloat {
        if let name = template.elements.first(where: {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .name
        }) {
            return name.frame.y
        }
        return lineFieldFrames(template: template).map(\.y).min() ?? 80
    }

    /// First item must sit below logos / date / time / static text so clearFrames & paint don't wipe it.
    static func printRowY(template: POSReceiptTemplate) -> CGFloat {
        var y = rowY(template: template)
        let pitch = itemPitch(template: template)
        for el in template.elements {
            switch el.kind {
            case .logo, .date, .time, .autoNumber, .textBox, .divider:
                break
            case .fieldPlaceholder:
                if el.fieldKind?.isLineField == true { continue }
                // summary / other placeholders below stay put
                if el.frame.y >= y + pitch { continue }
            }
            let bottom = el.frame.y + el.frame.height
            let overlapsFirstRow = el.frame.y < y + pitch && bottom > y
            if overlapsFirstRow {
                y = max(y, bottom + 4)
            }
        }
        return y
    }

    static func lineBand(template: POSReceiptTemplate) -> Band? {
        let frames = lineFieldFrames(template: template)
        guard !frames.isEmpty else { return nil }
        let y = printRowY(template: template)
        let pitch = itemPitch(template: template)
        return Band(minY: y, maxY: y + pitch)
    }

    private static func lineFieldFrames(template: POSReceiptTemplate) -> [SequencePlaceholderFrame] {
        let lineKinds = enabledLineKinds(template: template)
        return template.elements.compactMap { el -> SequencePlaceholderFrame? in
            guard el.kind == .fieldPlaceholder,
                  let kind = el.fieldKind,
                  lineKinds.contains(kind) else { return nil }
            return el.frame
        }
    }

    private static func enabledLineKinds(template: POSReceiptTemplate) -> Set<POSFieldKind> {
        var s: Set<POSFieldKind> = [.name]
        if template.enableCode { s.insert(.code) }
        if template.enableQuantity { s.insert(.quantity) }
        if template.enableAmount { s.insert(.amount) }
        return s
    }

    struct PlacedText: Equatable {
        var text: String
        var frame: SequencePlaceholderFrame
        var fontSize: CGFloat
        var isBold: Bool
        var alignment: Int
        /// When true, drawn as a sized text overlay (WYSIWYG font) instead of char-grid paint.
        var asOverlay: Bool = false
        /// Horizontal rule drawn as a vector stroke (solid/dashed); avoids hyphen gaps at large font.
        var asRule: Bool = false
        var ruleDashed: Bool = false
    }

    struct PlacedLogo: Equatable {
        var elementId: UUID
        var frame: SequencePlaceholderFrame
    }

    struct PlacedBarcode: Equatable {
        var text: String
        var frame: SequencePlaceholderFrame
    }

    struct ExpandedLayout: Equatable {
        var texts: [PlacedText]
        var logos: [PlacedLogo]
        var barcodeTexts: [PlacedBarcode]
        var canvasHeight: CGFloat
    }

    static func expand(
        template: POSReceiptTemplate,
        items: [POSLineItem],
        surcharge: String,
        now: Date = Date(),
        ticketAutoNumber: String? = nil,
        config: PrinterConfig = .default80mm,
        /// When false, keep designer frames (no footer push from wrapped line items).
        /// Used by the template live canvas so chrome overlays match ink.
        expandFooterShift: Bool = true
    ) -> ExpandedLayout {
        let count = max(1, items.count)
        let band = lineBand(template: template)
        let pitch = itemPitch(template: template)
        let anchorY = printRowY(template: template)
        let fontSize = AttributedTextView.defaultFontSize
        let metrics = SequenceLayoutComposer.metrics(
            config: config,
            fontSize: fontSize,
            paperWidthPoints: template.paperSize.width
        )
        let packed = packedLineSlots(template: template, unitWidth: metrics.unitWidth)
        let nameElement = template.elements.first {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .name
        }
        let nameFontSize = nameElement?.fontSize ?? fontSize
        let nameWrapWidth = max(
            36,
            (expandFooterShift
                ? (packed.first(where: { $0.kind == .name })?.width ?? availableNameSlotWidth(template: template, paperWidth: template.paperSize.width))
                : (nameElement?.frame.width ?? availableNameSlotWidth(template: template, paperWidth: template.paperSize.width)))
        )

        // Per-item heights from width-based wrap (fill 项目名称框, then wrap).
        var itemLineCounts: [Int] = []
        var itemHeights: [CGFloat] = []
        for i in 0..<count {
            let item = items.indices.contains(i) ? items[i] : POSLineItem()
            let wrapped = ReceiptTextLayout.wrapFittingWidth(
                item.name,
                maxWidth: nameWrapWidth,
                fontSize: nameFontSize,
                preserveEnglishWords: true
            )
            let lines = max(1, wrapped.count)
            itemLineCounts.append(lines)
            let contentH = CGFloat(lines) * max(metrics.lineHeight, nameFontSize + 2)
            itemHeights.append(lines == 1 ? pitch : max(pitch, contentH + 4))
        }
        let itemsSpan = itemHeights.reduce(0, +)
        let singleBandH = band?.height ?? pitch
        let computedShift = max(0, itemsSpan - singleBandH)
        let totalShift = expandFooterShift ? computedShift : 0

        var texts: [PlacedText] = []
        var logos: [PlacedLogo] = []
        var barcodes: [PlacedBarcode] = []

        let qtySub = POSReceiptTotals.formatQuantity(POSReceiptTotals.quantitySubtotal(items: items))
        let amtSub = POSReceiptTotals.formatAmount(POSReceiptTotals.amountSubtotal(items: items))
        let surchargeValue = surcharge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? template.defaultSurcharge
            : surcharge
        let amtTotal = POSReceiptTotals.formatAmount(
            POSReceiptTotals.amountTotal(items: items, surcharge: surchargeValue)
        )

        for el in template.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
            switch el.kind {
            case .logo:
                let frame = anchoredFrame(el, totalShift: totalShift)
                logos.append(PlacedLogo(elementId: el.id, frame: frame))

            case .textBox:
                // Do NOT repeat text boxes inside the item band — they wipe 编号/项目 on every row.
                let frame = anchoredFrame(el, totalShift: totalShift)
                texts.append(PlacedText(
                    text: el.content,
                    frame: frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    asOverlay: true
                ))

            case .divider:
                let frame = anchoredFrame(el, totalShift: totalShift)
                let cols = max(1, Int(floor(frame.width / metrics.unitWidth)))
                let lineText = ReceiptTextLayout.dividerLine(columns: cols, dashed: el.isDashed)
                texts.append(PlacedText(
                    text: lineText,
                    frame: frame,
                    fontSize: el.fontSize,
                    isBold: false,
                    alignment: 0,
                    asOverlay: true,
                    asRule: true,
                    ruleDashed: el.isDashed
                ))

            case .date:
                let frame = anchoredFrame(el, totalShift: totalShift)
                texts.append(PlacedText(
                    text: el.dateFormat.format(now),
                    frame: frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    asOverlay: true
                ))

            case .time:
                let frame = anchoredFrame(el, totalShift: totalShift)
                let f = DateFormatter()
                f.locale = Locale(identifier: "zh_CN")
                f.dateFormat = "HH:mm:ss"
                texts.append(PlacedText(
                    text: f.string(from: now),
                    frame: frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    asOverlay: true
                ))

            case .autoNumber:
                let frame = anchoredFrame(el, totalShift: totalShift)
                let value = ticketAutoNumber ?? el.autoNumberStart
                if el.autoNumberAsBarcode {
                    barcodes.append(PlacedBarcode(text: value, frame: frame))
                } else {
                    texts.append(PlacedText(
                        text: value,
                        frame: frame,
                        fontSize: el.fontSize,
                        isBold: el.isBold,
                        alignment: el.alignment,
                        asOverlay: true
                    ))
                }

            case .fieldPlaceholder:
                guard let kind = el.fieldKind else { continue }
                if kind.isLineField {
                    continue // handled in packed pass below
                } else {
                    let frame = anchoredFrame(el, totalShift: totalShift)
                    texts.append(PlacedText(
                        text: value(for: kind, item: POSLineItem(), qtySub: qtySub, amtSub: amtSub, surcharge: surchargeValue, amtTotal: amtTotal),
                        frame: frame,
                        fontSize: el.fontSize,
                        isBold: el.isBold,
                        alignment: el.alignment,
                        asOverlay: true
                    ))
                }
            }
        }

        // Pack 编号|项目|数量|金额; name height grows with wrapped lines.
        // Designer live canvas locks footers and uses element frames for WYSIWYG chrome↔ink.
        // Print keeps printRowY so item rows clear logos / header overlays.
        var y = expandFooterShift ? anchorY : rowY(template: template)
        for i in 0..<count {
            let item = items.indices.contains(i) ? items[i] : POSLineItem()
            let rowH = itemHeights[i]
            let nameH = CGFloat(itemLineCounts[i]) * metrics.lineHeight
            for slot in packed {
                guard let el = template.elements.first(where: {
                    $0.kind == .fieldPlaceholder && $0.fieldKind == slot.kind
                }) else { continue }
                let height: CGFloat
                if slot.kind == .name {
                    height = max(el.frame.height, nameH)
                } else {
                    height = max(el.frame.height, pitch - 4)
                }
                // Prefer designer X/Y when not expanding (live canvas); pack columns when printing.
                let frame: SequencePlaceholderFrame
                if expandFooterShift {
                    frame = SequencePlaceholderFrame(x: slot.x, y: y, width: slot.width, height: height)
                } else {
                    frame = SequencePlaceholderFrame(
                        x: el.frame.x,
                        y: el.frame.y,
                        width: el.frame.width > 1 ? el.frame.width : slot.width,
                        height: height
                    )
                }
                let rawText = value(
                    for: slot.kind,
                    item: item,
                    qtySub: qtySub,
                    amtSub: amtSub,
                    surcharge: surchargeValue,
                    amtTotal: amtTotal
                )
                let placedText: String
                if slot.kind == .name {
                    let wrapW = max(36, frame.width)
                    let wrapped = ReceiptTextLayout.wrapFittingWidth(
                        rawText,
                        maxWidth: wrapW,
                        fontSize: el.fontSize,
                        preserveEnglishWords: true
                    )
                    placedText = wrapped.joined(separator: "\n")
                } else {
                    placedText = rawText
                }
                texts.append(PlacedText(
                    text: placedText,
                    frame: frame,
                    fontSize: el.fontSize,
                    isBold: el.isBold,
                    alignment: el.alignment,
                    asOverlay: true
                ))
            }
            y += rowH
        }

        let baseH = template.canvasHeight
        let canvasHeight: CGFloat
        if expandFooterShift {
            // Print: trim to ink bottom so blank editor canvas does not push the cutter down.
            let bottoms =
                texts.map { $0.frame.y + $0.frame.height }
                + logos.map { $0.frame.y + $0.frame.height }
                + barcodes.map { $0.frame.y + $0.frame.height }
                + [y]
            canvasHeight = max(bottoms.max() ?? y, y) + 24
        } else {
            canvasHeight = max(baseH, y + 80, baseH + totalShift)
        }
        return ExpandedLayout(
            texts: texts,
            logos: logos,
            barcodeTexts: barcodes,
            canvasHeight: canvasHeight
        )
    }

    private struct LineSlot {
        var kind: POSFieldKind
        var x: CGFloat
        var width: CGFloat
    }

    /// Non-overlapping columns; name may steal width from 金额/数量/编号.
    private static func packedLineSlots(
        template: POSReceiptTemplate,
        unitWidth: CGFloat = 11
    ) -> [LineSlot] {
        _ = unitWidth
        var cursor: CGFloat = 12
        var result: [LineSlot] = []
        for (kind, width) in resolvedLineFieldWidths(template: template) {
            guard template.elements.contains(where: {
                $0.kind == .fieldPlaceholder && $0.fieldKind == kind
            }) else { continue }
            result.append(LineSlot(kind: kind, x: cursor, width: width))
            cursor += width + 4
        }
        return result
    }

    private static func value(
        for kind: POSFieldKind,
        item: POSLineItem,
        qtySub: String,
        amtSub: String,
        surcharge: String,
        amtTotal: String
    ) -> String {
        switch kind {
        case .code: return item.code
        case .name: return item.name
        case .quantity: return item.quantity
        case .amount: return item.amount
        case .quantitySubtotal: return qtySub
        case .amountSubtotal: return amtSub
        case .surcharge: return POSReceiptTotals.formatAmount(POSReceiptTotals.parseNumber(surcharge))
        case .amountTotal: return amtTotal
        }
    }

    /// Footer elements move down with expanding line items; header stays put.
    private static func anchoredFrame(
        _ el: POSReceiptElement,
        totalShift: CGFloat
    ) -> SequencePlaceholderFrame {
        guard totalShift > 0,
              el.allowsTicketSection,
              el.ticketSection == .footer else { return el.frame }
        var f = el.frame
        f.y += totalShift
        return f
    }
}
