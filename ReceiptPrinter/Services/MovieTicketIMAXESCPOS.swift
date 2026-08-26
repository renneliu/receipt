import AppKit
import Foundation

/// Native ESC/POS IMAX Sydney ticket.
///
/// Vertical order and gaps follow canvas `frame.y` / `frame.height` (editor positions).
/// Magnification / bold / align still come from each element's print scale.
enum MovieTicketIMAXESCPOS {

    private struct FieldStyle {
        var widthScale: Int = 1
        var heightScale: Int = 1
        var bold: Bool = false
        var align: ESCPOSAlign = .left
        var inverted: Bool = false
        var characterSpacing: Int = 0
    }

    private struct RowItem {
        var text: String
        var x: CGFloat
        var style: FieldStyle
        var label: String
    }

    /// Text or QR fragment inside a side-by-side strip (only same-Y text left of QR).
    private enum CompositeItem {
        case text(RowItem, canvasY: CGFloat)
        case qr(payload: String, sizeDots: Int, x: CGFloat, canvasY: CGFloat)
    }

    private enum BlockKind {
        case logo
        case barcode(payload: String, heightDots: UInt8, moduleWidth: UInt8)
        case qr(payload: String, sizeDots: Int)
        case text(String)
        /// Same-line type + price; `leftX` / `rightX` are canvas points → column placement.
        case typePrice(left: String, right: String, leftX: CGFloat, rightX: CGFloat)
        /// Canvas elements that share approximately the same Y (e.g. cinema name + hall).
        case inlineRow(items: [RowItem])
        /// Same-Y text(s) left of QR — one full-width GS v 0 strip (standard mode can't go up).
        case compositeRow(items: [CompositeItem])
    }

    private struct Block {
        var y: CGFloat
        var height: CGFloat
        var style: FieldStyle
        var kind: BlockKind
        var label: String
        /// Canvas X — used to place same-row items left→right.
        var x: CGFloat = 0
        /// Canvas width — used to decide if text sits fully left of a QR.
        var width: CGFloat = 0
        /// When true, emit via `appendRawTextLine` per line (box-constrained; no paper wrap).
        var boxConstrained: Bool = false
    }

    private static let barcodeModuleWidth: UInt8 = 3
    private static let defaultLogoWidthFraction: CGFloat = 0.80
    /// Serial field within this distance below a barcode is treated as HRI (skip duplicate).
    private static let serialUnderBarcodeSlop: CGFloat = 40
    /// Text blocks within this canvas Y distance are printed on one ESC/POS line.
    private static let sameRowYTolerance: CGFloat = 12

    static func render(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        logoImage: NSImage? = nil,
        now: Date = Date()
    ) -> Data {
        _ = now
        let blocks = buildBlocks(template: template, draft: draft, config: config)
        let paperW = max(1, template.paperSize.width)
        let lineDots = Int(MovieTicketPrintMetrics.fontACellDots.height)

        let builder = ESCPOSBuilder(config: config)
        builder.jobStartPadding(bytes: 96)
        builder.initialize()
        builder.selectFontA()
        builder.applyTextSize(.normal).bold(false).align(.left)

        // Cursor bottom in printer dots. Gaps use ESC J so canvas Y matches paper Y
        // (ESC d line feeds are too coarse and ignore absolute canvas positions).
        var cursorBottomDots: Int?
        for block in blocks {
            let yDots = canvasPointsToDots(block.y, paperWidth: paperW, dotsPerLine: config.dotsPerLine)
            let gap = (cursorBottomDots.map { yDots - $0 } ?? yDots)
            feedDotsGap(builder, max(0, gap))

            let printedDots: Int
            switch block.kind {
            case .logo:
                if let logo = logoImage {
                    let maxW = logoMaxWidth(template: template, config: config)
                    placeRaster(
                        builder: builder,
                        align: block.style.align,
                        xDots: canvasPointsToDots(block.x, paperWidth: paperW, dotsPerLine: config.dotsPerLine)
                    ) {
                        builder.imageBanded(
                            logo,
                            maxWidth: maxW,
                            bandHeight: 48,
                            scaleToWidth: true,
                            trailingFeed: false
                        )
                    }
                    let aspect = logo.size.height / max(logo.size.width, 1)
                    printedDots = max(1, Int((CGFloat(maxW) * aspect).rounded()))
                } else {
                    printedDots = canvasPointsToDots(block.height, paperWidth: paperW, dotsPerLine: config.dotsPerLine)
                }
            case .barcode(let payload, let heightDots, let moduleWidth):
                let code = payload.isEmpty ? "000000" : payload
                placeRaster(
                    builder: builder,
                    align: block.style.align,
                    xDots: canvasPointsToDots(block.x, paperWidth: paperW, dotsPerLine: config.dotsPerLine)
                ) {
                    builder.barcode(
                        type: .code128,
                        content: code,
                        height: heightDots,
                        width: moduleWidth,
                        printHRI: false
                    )
                }
                apply(builder, FieldStyle(widthScale: 1, heightScale: 1, bold: false, align: .center))
                builder.text(spacedHRI(code)).newline()
                printedDots = Int(heightDots) + lineDots
            case .qr(let payload, let sizeDots):
                let content = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = content.isEmpty ? "0" : content
                let xDots = canvasPointsToDots(block.x, paperWidth: paperW, dotsPerLine: config.dotsPerLine)
                let bakedX = qrInkXDots(
                    align: block.style.align,
                    sizeDots: sizeDots,
                    canvasXDots: xDots,
                    dotsPerLine: config.dotsPerLine
                )
                emitQRPadded(
                    builder: builder,
                    content: body,
                    sizeDots: sizeDots,
                    inkXDots: bakedX,
                    dotsPerLine: config.dotsPerLine
                )
                printedDots = sizeDots
            case .text(let text):
                if text.contains("EFTP") || text.contains("T/N:") {
                    builder.selectFontB(columns: 64)
                } else {
                    builder.selectFontA()
                }
                apply(builder, block.style)
                let emitText = paddedIfInverted(text, inverted: block.style.inverted)
                let lines: [String]
                if block.boxConstrained {
                    lines = emitText.components(separatedBy: "\n")
                } else {
                    lines = [emitText]
                }
                if block.style.inverted { builder.reversePrint(true) }
                for line in lines {
                    placeTextOrigin(
                        builder: builder,
                        style: block.style,
                        x: block.x,
                        paperWidth: paperW,
                        config: config
                    )
                    if block.boxConstrained {
                        builder.appendRawTextLine(line).newline()
                    } else {
                        builder.text(line).newline()
                    }
                }
                if block.style.inverted { builder.reversePrint(false) }
                builder.selectFontA()
                printedDots = lineDots * max(1, block.style.heightScale) * max(1, lines.count)
            case .typePrice(let left, let right, let leftX, let rightX):
                builder.selectFontA()
                apply(builder, block.style)
                builder.align(.left)
                let cols = max(
                    8,
                    config.columnsPerLine / max(1, block.style.widthScale)
                )
                let line = positionedPairLine(
                    left: left,
                    right: right,
                    leftX: leftX,
                    rightX: rightX,
                    paperWidth: paperW,
                    columns: cols
                )
                builder.text(line).newline()
                printedDots = lineDots * max(1, block.style.heightScale)
            case .inlineRow(let items):
                builder.selectFontA()
                emitInlineRow(
                    builder: builder,
                    items: items,
                    paperWidth: paperW,
                    config: config
                )
                let hScale = items.map(\.style.heightScale).max() ?? block.style.heightScale
                printedDots = lineDots * max(1, hScale)
            case .compositeRow(let items):
                let rowH = emitCompositeRow(
                    builder: builder,
                    items: items,
                    paperWidth: paperW,
                    config: config
                )
                printedDots = rowH
            }

            cursorBottomDots = yDots + max(1, printedDots)
        }
        builder.selectFontA()
        builder.resetLineSpacing()
        let feed = template.resolvedFeedLinesBeforeCut(config: config)
        return builder.cut(feedLines: feed).build()
    }

    static func previewImage(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        logoImage: NSImage? = nil,
        now: Date = Date()
    ) -> NSImage {
        _ = now
        let blocks = buildBlocks(template: template, draft: draft, config: config)
        let widthDots = max(8, config.dotsPerLine)
        let width = CGFloat(widthDots)
        let paperW = max(1, template.paperSize.width)
        let scale = width / paperW

        let contentBottom = blocks.map { ($0.y + $0.height) * scale }.max() ?? 200
        let height = max(200, contentBottom + 40)

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            for block in blocks {
                let y = block.y * scale
                switch block.kind {
                case .logo:
                    if let logo = logoImage {
                        let maxW = CGFloat(logoMaxWidth(template: template, config: config))
                        let aspect = logo.size.height / max(logo.size.width, 1)
                        let drawW = maxW
                        let drawH = drawW * aspect
                        let x = previewX(
                            align: block.style.align,
                            contentWidth: drawW,
                            canvasX: block.x * scale,
                            paperWidthDots: width
                        )
                        logo.draw(
                            in: NSRect(x: x, y: y, width: drawW, height: drawH),
                            from: NSRect(origin: .zero, size: logo.size),
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.none]
                        )
                    }
                case .barcode(let payload, let heightDots, _):
                    let code = payload.isEmpty ? "000000" : payload
                    let barH = CGFloat(heightDots)
                    let barW = width * 0.88
                    let barX = previewX(
                        align: block.style.align,
                        contentWidth: barW,
                        canvasX: block.x * scale,
                        paperWidthDots: width
                    )
                    if let img = MovieTicketPrintComposer.makeCode128Barcode(
                        content: code, size: CGSize(width: barW, height: barH)
                    ) {
                        img.draw(
                            in: NSRect(x: barX, y: y, width: barW, height: barH),
                            from: NSRect(origin: .zero, size: img.size),
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.none]
                        )
                    }
                    var hriY = y + barH + 4
                    drawText(
                        spacedHRI(code),
                        style: FieldStyle(align: .center),
                        widthDots: widthDots,
                        y: &hriY
                    )
                case .qr(let payload, let sizeDots):
                    let content = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = content.isEmpty ? "0" : content
                    let qrSide = CGFloat(sizeDots)
                    let qrX = previewX(
                        align: block.style.align,
                        contentWidth: qrSide,
                        canvasX: block.x * scale,
                        paperWidthDots: width
                    )
                    if let img = BarcodeGenerator.makeQRCode(body, size: sizeDots) {
                        img.draw(
                            in: NSRect(x: qrX, y: y, width: qrSide, height: qrSide),
                            from: NSRect(origin: .zero, size: img.size),
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.none]
                        )
                    }
                case .text(let text):
                    var ty = y
                    let absX: CGFloat? = block.style.align == .left ? block.x * scale : nil
                    let boxW = max(1, block.width * scale)
                    let boxH = max(1, block.height * scale)
                    let clipRect = NSRect(x: absX ?? 0, y: y, width: boxW, height: boxH)
                    if block.boxConstrained, let ctx = NSGraphicsContext.current?.cgContext {
                        ctx.saveGState()
                        ctx.clip(to: clipRect)
                    }
                    let lines = text.components(separatedBy: "\n")
                    for line in lines {
                        drawText(
                            paddedIfInverted(line, inverted: block.style.inverted),
                            style: block.style,
                            widthDots: widthDots,
                            y: &ty,
                            absoluteX: absX
                        )
                    }
                    if block.boxConstrained {
                        NSGraphicsContext.current?.cgContext.restoreGState()
                    }
                case .typePrice(let left, let right, let leftX, let rightX):
                    var ty = y
                    let cols = max(8, config.columnsPerLine / max(1, block.style.widthScale))
                    let line = positionedPairLine(
                        left: left,
                        right: right,
                        leftX: leftX,
                        rightX: rightX,
                        paperWidth: paperW,
                        columns: cols
                    )
                    drawText(line, style: FieldStyle(align: .left), widthDots: widthDots, y: &ty, absoluteX: 0)
                case .inlineRow(let items):
                    var ty = y
                    drawInlineRow(
                        items: items,
                        paperWidth: paperW,
                        widthDots: widthDots,
                        config: config,
                        y: &ty
                    )
                case .compositeRow(let items):
                    drawCompositeRow(
                        items: items,
                        paperWidth: paperW,
                        widthDots: widthDots,
                        config: config,
                        y: y
                    )
                }
            }
            return true
        }
    }

    // MARK: - Canvas → blocks

    private static func buildBlocks(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig
    ) -> [Block] {
        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = barcodePayload(from: serial)
        let barcodeEl = firstField(template, .barcode)
        let typeEl = firstField(template, .ticketType)
        let priceEl = firstField(template, .ticketPrice)

        var skipIds = Set<UUID>()
        // Merge type + price onto one line only when their canvas Y is close.
        if let typeEl, let priceEl,
           abs(typeEl.frame.y - priceEl.frame.y) <= sameRowYTolerance {
            skipIds.insert(priceEl.id)
        }
        // Skip serial under barcode (HRI is emitted with barcode).
        if let barcodeEl, let serialEl = firstField(template, .serialNumber) {
            let under = serialEl.frame.y >= barcodeEl.frame.y
                && serialEl.frame.y <= barcodeEl.frame.y + barcodeEl.frame.height + serialUnderBarcodeSlop
            if under { skipIds.insert(serialEl.id) }
        }

        var blocks: [Block] = []
        for el in template.elements where !skipIds.contains(el.id) {
            switch el.kind {
            case .logo:
                blocks.append(Block(
                    y: el.frame.y,
                    height: el.frame.height,
                    style: FieldStyle(align: escAlign(el.alignment)),
                    kind: .logo,
                    label: "logo",
                    x: el.frame.x,
                    width: el.frame.width
                ))
            case .textBox, .currentDate, .currentTime:
                let text = expandStaticText(el, draft: draft, now: Date())
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(makeBoxTextBlock(
                    text: text,
                    element: el,
                    template: template,
                    config: config,
                    label: "text:\(String(text.prefix(12)))",
                    defaultW: 1,
                    defaultH: 1,
                    defaultBold: el.isBold,
                    defaultAlign: escAlign(el.alignment)
                ))
            case .fieldPlaceholder:
                guard let kind = el.fieldKind else { continue }
                switch kind {
                case .barcode:
                    let raw = el.resolvedCodePayload(from: draft)
                    let code = (el.codeContentSource ?? .serialNumber) == .custom
                        ? (raw.isEmpty ? "0" : raw)
                        : barcodePayload(from: raw.isEmpty ? "0" : raw)
                    let dots = barcodeHeightDots(el)
                    blocks.append(Block(
                        y: el.frame.y,
                        height: el.frame.height + 16,
                        style: FieldStyle(align: escAlign(el.alignment)),
                        kind: .barcode(
                            payload: code,
                            heightDots: dots,
                            moduleWidth: barcodeModuleWidth
                        ),
                        label: "barcode",
                        x: el.frame.x,
                        width: el.frame.width
                    ))
                case .qrCode:
                    let sizeDots = qrSizeDots(el, paperWidth: template.paperSize.width, config: config)
                    let payload = {
                        let raw = el.resolvedCodePayload(from: draft)
                        return raw.isEmpty ? "0" : raw
                    }()
                    blocks.append(Block(
                        y: el.frame.y,
                        height: max(el.frame.height, CGFloat(sizeDots) * MovieTicketPrintMetrics.pointsPerDot(
                            paperWidth: template.paperSize.width,
                            dotsPerLine: config.dotsPerLine
                        )),
                        style: FieldStyle(align: escAlign(el.alignment)),
                        kind: .qr(payload: payload, sizeDots: sizeDots),
                        label: "qr",
                        x: el.frame.x,
                        width: el.frame.width
                    ))
                case .ticketType:
                    let left = draft.ticketType.trimmingCharacters(in: .whitespacesAndNewlines)
                    let right = draft.formattedPrice
                    if let priceEl, abs(el.frame.y - priceEl.frame.y) <= sameRowYTolerance {
                        blocks.append(Block(
                            y: el.frame.y,
                            height: max(el.frame.height, priceEl.frame.height),
                            style: fieldStyle(el, defaultW: 1, defaultH: 1, defaultBold: false, defaultAlign: .left),
                            kind: .typePrice(
                                left: left,
                                right: right,
                                leftX: el.frame.x,
                                rightX: priceEl.frame.x
                            ),
                            label: "typePrice",
                            x: el.frame.x,
                            width: el.frame.width
                        ))
                    } else {
                        blocks.append(makeBoxTextBlock(
                            text: left.isEmpty ? " " : left,
                            element: el,
                            template: template,
                            config: config,
                            label: "ticketType",
                            defaultW: 1,
                            defaultH: 1,
                            defaultBold: el.isBold,
                            defaultAlign: escAlign(el.alignment)
                        ))
                    }
                case .ticketPrice:
                    // Skipped when type exists (merged into typePrice); alone → own line.
                    let value = draft.formattedPrice
                    blocks.append(makeBoxTextBlock(
                        text: value.isEmpty ? " " : value,
                        element: el,
                        template: template,
                        config: config,
                        label: "ticketPrice",
                        defaultW: 1,
                        defaultH: 1,
                        defaultBold: el.isBold,
                        defaultAlign: escAlign(el.alignment)
                    ))
                default:
                    var value = MovieTicketLayoutEngine_resolved(
                        kind: kind, element: el, draft: draft, template: template
                    )
                    if kind == .seatArea {
                        value = seatLine(value, template: template, draft: draft)
                    }
                    if kind == .serialNumber {
                        value = spacedHRI(barcodePayload(from: value.isEmpty ? payload : value))
                    }
                    if kind == .timeRange || kind == .startTime {
                        // Keep Thur spelling for IMAX-style ranges.
                        if kind == .timeRange {
                            value = formatTimeRange(el, draft: draft)
                        }
                    }
                    let defaults = defaultStyle(for: kind)
                    let style = fieldStyle(
                        el,
                        defaultW: defaults.w,
                        defaultH: defaults.h,
                        defaultBold: defaults.bold,
                        defaultAlign: defaults.align
                    )
                    blocks.append(makeBoxTextBlock(
                        text: value.isEmpty ? " " : value,
                        element: el,
                        template: template,
                        config: config,
                        label: kind.rawValue,
                        style: style
                    ))
                }
            }
        }

        let sorted = blocks.sorted {
            if abs($0.y - $1.y) <= sameRowYTolerance {
                if abs($0.y - $1.y) > 0.5 { return $0.y < $1.y }
                return $0.x < $1.x
            }
            return $0.y < $1.y
        }
        let merged = mergeSameRowBlocks(sorted)
        return merged
    }

    /// QR-centric: text/typePrice that intersects the QR frame and sits left/right of it
    /// joins one strip. Full-width lines above/below are excluded even if frames graze.
    private static func mergeSameRowBlocks(_ blocks: [Block]) -> [Block] {
        var consumed = Set<Int>()
        var compositeAt = [Int: Block]() // insertion index → composite
        /// Horizontal slop: text may slightly overhang toward the QR and still count as beside.
        let besideXSlop: CGFloat = 24

        for (qi, qr) in blocks.enumerated() {
            guard case .qr(let payload, let sizeDots) = qr.kind else { continue }
            guard !consumed.contains(qi) else { continue }

            let qrTop = qr.y
            let qrBottom = qr.y + max(qr.height, 1)
            let qrRight = qr.x + max(qr.width, 1)

            var companionIndices: [Int] = []
            for (i, b) in blocks.enumerated() where i != qi && !consumed.contains(i) {
                switch b.kind {
                case .text, .typePrice:
                    break
                default:
                    continue
                }
                let bTop = b.y
                let bBottom = b.y + max(b.height, 1)
                // Any text that intersects the QR frame and sits left/right of it joins the strip.
                // (Separate "next row" under the QR won't intersect if it starts at/after qrBottom.)
                let intersects = bTop < qrBottom && bBottom > qrTop
                let leftOf = b.x + b.width <= qr.x + besideXSlop
                let rightOf = b.x >= qrRight - besideXSlop
                let beside = leftOf || rightOf
                if intersects && beside {
                    companionIndices.append(i)
                }
            }

            guard !companionIndices.isEmpty else {
                continue
            }

            var items: [CompositeItem] = []
            for i in companionIndices.sorted(by: { (blocks[$0].y, blocks[$0].x) < (blocks[$1].y, blocks[$1].x) }) {
                let b = blocks[i]
                switch b.kind {
                case .text(let t):
                    items.append(.text(
                        RowItem(text: t, x: b.x, style: b.style, label: b.label),
                        canvasY: b.y
                    ))
                case .typePrice(let left, let right, let leftX, let rightX):
                    items.append(.text(
                        RowItem(text: left, x: leftX, style: b.style, label: "ticketType"),
                        canvasY: b.y
                    ))
                    items.append(.text(
                        RowItem(text: right, x: rightX, style: b.style, label: "ticketPrice"),
                        canvasY: b.y
                    ))
                default:
                    break
                }
            }
            items.append(.qr(payload: payload, sizeDots: sizeDots, x: qr.x, canvasY: qr.y))

            let companions = companionIndices.map { blocks[$0] }
            let minY = ([qr.y] + companions.map(\.y)).min() ?? qr.y
            let maxBottom = ([qr.y + qr.height] + companions.map { $0.y + $0.height }).max() ?? (qr.y + qr.height)
            let minX = ([qr.x] + companions.map(\.x)).min() ?? qr.x
            let maxR = ([qr.x + qr.width] + companions.map { $0.x + $0.width }).max() ?? (qr.x + qr.width)
            let insertAt = min(qi, companionIndices.min() ?? qi)

            compositeAt[insertAt] = Block(
                y: minY,
                height: max(1, maxBottom - minY),
                style: FieldStyle(align: .left),
                kind: .compositeRow(items: items),
                label: items.map { item -> String in
                    switch item {
                    case .text(let r, _): return r.label
                    case .qr: return "qr"
                    }
                }.joined(separator: "+"),
                x: minX,
                width: max(0, maxR - minX)
            )
            consumed.insert(qi)
            companionIndices.forEach { consumed.insert($0) }
        }

        var ordered: [Block] = []
        for (i, b) in blocks.enumerated() {
            if let composite = compositeAt[i] {
                ordered.append(composite)
            } else if !consumed.contains(i) {
                ordered.append(b)
            }
        }
        return mergeTextOnlyBand(ordered)
    }

    /// Text-only same-Y → inlineRow; non-text blocks (incl. compositeRow) pass through.
    private static func mergeTextOnlyBand(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            guard case .text(let text0) = block.kind else {
                result.append(block)
                i += 1
                continue
            }
            var group: [(Block, String)] = [(block, text0)]
            var j = i + 1
            while j < blocks.count {
                let next = blocks[j]
                guard case .text(let tj) = next.kind,
                      abs(next.y - block.y) <= sameRowYTolerance
                else { break }
                group.append((next, tj))
                j += 1
            }
            if group.count == 1 {
                result.append(block)
            } else {
                let items = group
                    .sorted { $0.0.x < $1.0.x }
                    .map { RowItem(text: $0.1, x: $0.0.x, style: $0.0.style, label: $0.0.label) }
                let tallest = items.map(\.style.heightScale).max() ?? block.style.heightScale
                var rowStyle = block.style
                rowStyle.heightScale = tallest
                rowStyle.widthScale = items.map(\.style.widthScale).max() ?? block.style.widthScale
                rowStyle.align = .left
                let minX = items.first?.x ?? block.x
                let maxR = group.map { $0.0.x + $0.0.width }.max() ?? (block.x + block.width)
                result.append(Block(
                    y: group.map(\.0.y).min() ?? block.y,
                    height: group.map(\.0.height).max() ?? block.height,
                    style: rowStyle,
                    kind: .inlineRow(items: items),
                    label: items.map(\.label).joined(separator: "+"),
                    x: minX,
                    width: max(0, maxR - minX)
                ))
            }
            i = j
        }
        return result
    }

    private static func defaultStyle(for kind: MovieTicketFieldKind) -> (w: Int, h: Int, bold: Bool, align: ESCPOSAlign) {
        switch kind {
        case .hall: return (2, 2, true, .left)
        case .movieTitle: return (2, 2, true, .left)
        case .timeRange, .startTime, .endTime: return (1, 2, true, .left)
        case .seatArea: return (3, 3, true, .left)
        default: return (1, 1, false, .left)
        }
    }

    private static func seatLine(_ raw: String, template: MovieTicketTemplate, draft: MovieTicketDraft) -> String {
        if draft.seatModeUnallocated { return template.unallocatedSeatLabel }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return template.unallocatedSeatLabel }
        if t.uppercased().hasPrefix("SEAT") { return t }
        return "SEAT \(t)"
    }

    private static func formatTimeRange(_ el: MovieTicketElement, draft: MovieTicketDraft) -> String {
        let a = formatIMAXStart(draft.combinedStart, fallback: el.rangeStartFormat)
        let b = el.rangeEndFormat.format(draft.showEndTime)
        return "\(a)\(el.rangeConnector)\(b)"
    }

    private static func expandStaticText(
        _ el: MovieTicketElement,
        draft: MovieTicketDraft,
        now: Date
    ) -> String {
        switch el.kind {
        case .currentDate:
            return el.dateFormat.format(now)
        case .currentTime:
            return el.timeFormat.format(now)
        default:
            break
        }
        var text = el.content
        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "ddMMyyyy HHmm"
        let stamp = df.string(from: draft.combinedStart)
        text = text.replacingOccurrences(of: "{serial}", with: serial)
        text = text.replacingOccurrences(of: "{datetime}", with: stamp)
        text = text.replacingOccurrences(of: "{date}", with: stamp)
        // Stock meta template used spaces inside braces.
        text = text.replacingOccurrences(of: "{ serial }", with: serial)
        text = text.replacingOccurrences(of: "{ datetime }", with: stamp)
        if text.contains("T/N:") && text.contains("{") {
            // Fallback full meta line if braces remain.
            return "EFTP | T/N: \(serial.isEmpty ? "000000/001" : serial) | d:\(stamp) | u:9613"
        }
        return text
    }

    /// Local resolve without making LayoutEngine internals public.
    private static func MovieTicketLayoutEngine_resolved(
        kind: MovieTicketFieldKind,
        element: MovieTicketElement,
        draft: MovieTicketDraft,
        template: MovieTicketTemplate
    ) -> String {
        switch kind {
        case .movieTitle: return draft.printedMovieTitle
        case .startTime: return element.timeFormat.format(draft.combinedStart)
        case .endTime:
            let body = element.timeFormat.format(draft.showEndTime)
            return element.content.isEmpty ? body : element.content + body
        case .timeRange:
            return formatTimeRange(element, draft: draft)
        case .showDate:
            return element.dateFormat.format(draft.showDate)
        case .seatArea:
            if draft.seatModeUnallocated { return template.unallocatedSeatLabel }
            return draft.seatArea
        case .ticketPrice: return draft.formattedPrice
        case .ticketType: return draft.ticketType
        case .serialNumber: return draft.serialNumber
        case .hall: return element.resolvedHallText(from: draft)
        case .qrCode, .barcode: return draft.serialNumber
        }
    }

    private static func logoMaxWidth(template: MovieTicketTemplate, config: PrinterConfig) -> Int {
        let paperW = max(1, template.paperSize.width)
        let frac: CGFloat
        if let logoEl = template.elements.first(where: { $0.kind == .logo }) {
            frac = min(0.98, max(0.45, logoEl.frame.width / paperW))
        } else {
            frac = defaultLogoWidthFraction
        }
        return max(8, (Int(CGFloat(config.dotsPerLine) * frac) / 8) * 8)
    }

    private static func barcodeHeightDots(_ el: MovieTicketElement?) -> UInt8 {
        let h = el?.frame.height ?? 56
        let dots = Int((h * (110.0 / 72.0)).rounded())
        return UInt8(max(48, min(160, dots)))
    }

    /// QR side length in printer dots from canvas square side (points).
    static func qrPrintSizeDots(
        sidePoints: CGFloat,
        paperWidth: CGFloat,
        dotsPerLine: Int
    ) -> Int {
        let paperW = max(1, paperWidth)
        let dots = Int((sidePoints * CGFloat(dotsPerLine) / paperW).rounded())
        // Floor was 96 which made small canvas boxes ignore size changes.
        // Snap to 8-dot multiple so GS v 0 widthBytes stay valid.
        let clamped = max(48, min(max(8, dotsPerLine - 16), dots))
        return max(48, (clamped / 8) * 8)
    }

    /// Same X formula as preview: left = canvas X; center/right = paper edges.
    private static func qrInkXDots(
        align: ESCPOSAlign,
        sizeDots: Int,
        canvasXDots: Int,
        dotsPerLine: Int
    ) -> Int {
        let side = max(8, sizeDots)
        let paper = max(side, dotsPerLine)
        switch align {
        case .center:
            return max(0, (paper - side) / 2)
        case .right:
            return max(0, paper - side)
        case .left:
            return max(0, min(canvasXDots, paper - side))
        }
    }

    /// Bake horizontal position into a full-width white strip.
    /// POS-80 GS v 0 ignores ESC a / ESC $ for bitmaps; padding is the reliable path.
    private static func emitQRPadded(
        builder: ESCPOSBuilder,
        content: String,
        sizeDots: Int,
        inkXDots: Int,
        dotsPerLine: Int
    ) {
        let side = max(8, (sizeDots / 8) * 8)
        let paperW = max(8, (dotsPerLine / 8) * 8)
        let x = max(0, min(inkXDots, paperW - side))
        guard let qr = BarcodeGenerator.makeQRCode(content, size: side) else { return }
        let strip = makePrinterDotImage(widthDots: paperW, heightDots: side) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(paperW), height: CGFloat(side)).fill()
            qr.draw(
                in: NSRect(x: CGFloat(x), y: 0, width: CGFloat(side), height: CGFloat(side)),
                from: NSRect(origin: .zero, size: qr.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
        builder.align(.left)
        builder.image(strip, maxWidth: paperW, scaleToWidth: false, trailingFeed: false)
    }

    /// Bake same-Y left text + QR into one full-width strip (relative canvas Y inside the band).
    @discardableResult
    private static func emitCompositeRow(
        builder: ESCPOSBuilder,
        items: [CompositeItem],
        paperWidth: CGFloat,
        config: PrinterConfig
    ) -> Int {
        let paperDots = max(8, (config.dotsPerLine / 8) * 8)
        let lineDots = Int(MovieTicketPrintMetrics.fontACellDots.height)
        let bandMinY: CGFloat = items.map { item -> CGFloat in
            switch item {
            case .text(_, let y), .qr(_, _, _, let y): return y
            }
        }.min() ?? 0

        var heightDots = lineDots
        for item in items {
            switch item {
            case .text(let row, let canvasY):
                let top = canvasPointsToDots(
                    canvasY - bandMinY, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                )
                let th = lineDots * max(1, row.style.heightScale)
                heightDots = max(heightDots, top + th)
            case .qr(_, let sizeDots, _, let canvasY):
                let top = canvasPointsToDots(
                    canvasY - bandMinY, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                )
                let side = max(8, (sizeDots / 8) * 8)
                heightDots = max(heightDots, top + side)
            }
        }

        // 1× pixel buffer: Retina NSImage(size:) is often 2×, then scaleToWidth shrinks glyphs.
        let strip = makePrinterDotImage(widthDots: paperDots, heightDots: heightDots) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(paperDots), height: CGFloat(heightDots)).fill()
            for item in items {
                switch item {
                case .text(let row, let canvasY):
                    let text = paddedIfInverted(row.text, inverted: row.style.inverted)
                    var ty = CGFloat(canvasPointsToDots(
                        canvasY - bandMinY, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                    ))
                    let absX = canvasPointsToDots(
                        row.x, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                    )
                    // Font A cell is 24 dots tall at 1× — not preview's ~17pt approximation.
                    drawText(
                        text,
                        style: row.style,
                        widthDots: paperDots,
                        y: &ty,
                        baseSize: MovieTicketPrintMetrics.fontACellDots.height,
                        absoluteX: CGFloat(absX)
                    )
                case .qr(let payload, let sizeDots, let x, let canvasY):
                    let body = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = body.isEmpty ? "0" : body
                    let side = max(8, (sizeDots / 8) * 8)
                    let xDots = canvasPointsToDots(
                        x, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                    )
                    let inkX = max(0, min(xDots, paperDots - side))
                    let top = canvasPointsToDots(
                        canvasY - bandMinY, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                    )
                    if let qr = BarcodeGenerator.makeQRCode(content, size: side) {
                        qr.draw(
                            in: NSRect(
                                x: CGFloat(inkX), y: CGFloat(top),
                                width: CGFloat(side), height: CGFloat(side)
                            ),
                            from: NSRect(origin: .zero, size: qr.size),
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.none]
                        )
                    }
                }
            }
        }

        builder.align(.left)
        // Already exact printer dots — do not scaleToWidth (avoids Retina downscale).
        builder.image(strip, maxWidth: paperDots, scaleToWidth: false, trailingFeed: false)
        return heightDots
    }

    /// NSImage whose bitmap is exactly `widthDots`×`heightDots` pixels (1 pt = 1 printer dot).
    private static func makePrinterDotImage(
        widthDots: Int,
        heightDots: Int,
        draw: @escaping (NSRect) -> Void
    ) -> NSImage {
        let w = max(1, widthDots)
        let h = max(1, heightDots)
        let size = NSSize(width: w, height: h)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size, flipped: true) { rect in
                draw(rect)
                return true
            }
        }
        // Point size == pixel size → no Retina 2× backing.
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        // lockFocusFlipped keeps AppKit text upright (manual CTM y-flip mirrors glyphs).
        image.lockFocusFlipped(true)
        defer { image.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)).fill()
        draw(NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return image
    }

    private static func drawCompositeRow(
        items: [CompositeItem],
        paperWidth: CGFloat,
        widthDots: Int,
        config: PrinterConfig,
        y: CGFloat
    ) {
        let bandMinY: CGFloat = items.map { item -> CGFloat in
            switch item {
            case .text(_, let cy), .qr(_, _, _, let cy): return cy
            }
        }.min() ?? 0
        for item in items {
            switch item {
            case .text(let row, let canvasY):
                let text = paddedIfInverted(row.text, inverted: row.style.inverted)
                var ty = y + CGFloat(canvasPointsToDots(
                    canvasY - bandMinY, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                ))
                let absX = CGFloat(canvasPointsToDots(
                    row.x, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                ))
                drawText(
                    text,
                    style: row.style,
                    widthDots: widthDots,
                    y: &ty,
                    absoluteX: absX
                )
            case .qr(let payload, let sizeDots, let x, let canvasY):
                let body = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = body.isEmpty ? "0" : body
                let side = CGFloat(max(8, (sizeDots / 8) * 8))
                let qrX = CGFloat(canvasPointsToDots(
                    x, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                ))
                let top = y + CGFloat(canvasPointsToDots(
                    canvasY - bandMinY, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine
                ))
                if let img = BarcodeGenerator.makeQRCode(content, size: Int(side)) {
                    img.draw(
                        in: NSRect(x: qrX, y: top, width: side, height: side),
                        from: NSRect(origin: .zero, size: img.size),
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.none]
                    )
                }
            }
        }
    }

    /// QR side length in printer dots from the canvas box (larger side → square).
    private static func qrSizeDots(
        _ el: MovieTicketElement,
        paperWidth: CGFloat,
        config: PrinterConfig
    ) -> Int {
        let side = max(el.frame.width, el.frame.height)
        return qrPrintSizeDots(
            sidePoints: side,
            paperWidth: paperWidth,
            dotsPerLine: config.dotsPerLine
        )
    }

    private static func canvasPointsToDots(
        _ points: CGFloat,
        paperWidth: CGFloat,
        dotsPerLine: Int
    ) -> Int {
        Int((points * CGFloat(dotsPerLine) / max(1, paperWidth)).rounded())
    }

    private static func feedDotsGap(_ builder: ESCPOSBuilder, _ dots: Int) {
        var remaining = max(0, dots)
        while remaining > 0 {
            let chunk = min(255, remaining)
            builder.feedDots(UInt8(chunk))
            remaining -= chunk
        }
    }

    /// Place a raster/barcode/QR at canvas X (left) or paper center/right.
    private static func placeRaster(
        builder: ESCPOSBuilder,
        align: ESCPOSAlign,
        xDots: Int,
        emit: () -> Void
    ) {
        switch align {
        case .center:
            builder.align(.center)
            emit()
        case .right:
            builder.align(.right)
            emit()
        case .left:
            builder.align(.left)
            builder.setAbsoluteHorizontalPosition(dots: max(0, xDots))
            emit()
        }
    }

    /// Left-aligned text uses canvas X via ESC $; center/right use ESC a.
    private static func placeTextOrigin(
        builder: ESCPOSBuilder,
        style: FieldStyle,
        x: CGFloat,
        paperWidth: CGFloat,
        config: PrinterConfig
    ) {
        guard style.align == .left else { return }
        let xDots = canvasPointsToDots(x, paperWidth: paperWidth, dotsPerLine: config.dotsPerLine)
        if xDots > 0 {
            builder.align(.left)
            builder.setAbsoluteHorizontalPosition(dots: xDots)
        }
    }

    private static func previewX(
        align: ESCPOSAlign,
        contentWidth: CGFloat,
        canvasX: CGFloat,
        paperWidthDots: CGFloat
    ) -> CGFloat {
        switch align {
        case .center:
            return max(0, (paperWidthDots - contentWidth) / 2)
        case .right:
            return max(0, paperWidthDots - contentWidth)
        case .left:
            return max(0, min(canvasX, paperWidthDots - contentWidth))
        }
    }

    /// Prefer booking code for scan payloads; fall back to serial (same as Dendy).
    private static func qrPayload(from draft: MovieTicketDraft) -> String {
        let booking = draft.bookingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !booking.isEmpty { return booking }
        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serial.isEmpty { return serial }
        return "0"
    }

    private static func formatIMAXStart(_ date: Date, fallback: MovieTicketTimeFormat) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fallback.rawValue
        var s = f.string(from: date)
        if s.hasPrefix("Thu ") {
            s = "Thur" + s.dropFirst(3)
        }
        return s
    }

    private static func firstField(
        _ template: MovieTicketTemplate, _ kind: MovieTicketFieldKind
    ) -> MovieTicketElement? {
        template.elements.first { $0.kind == .fieldPlaceholder && $0.fieldKind == kind }
    }

    /// Columns the movie title may occupy on one line when single-line clip is on.
    /// Derived from the title box width at its printed character size (Font A × width scale).
    private static func titleClipColumns(
        element: MovieTicketElement,
        config: PrinterConfig,
        widthScale: Int,
        paperWidth: CGFloat
    ) -> Int? {
        MovieTicketPrintMetrics.boxColumns(
            frameWidth: element.frame.width,
            paperWidth: paperWidth,
            config: config,
            widthScale: widthScale
        )
    }

    private static func makeBoxTextBlock(
        text: String,
        element: MovieTicketElement,
        template: MovieTicketTemplate,
        config: PrinterConfig,
        label: String,
        defaultW: Int = 1,
        defaultH: Int = 1,
        defaultBold: Bool = false,
        defaultAlign: ESCPOSAlign = .left,
        style: FieldStyle? = nil
    ) -> Block {
        let resolved = style ?? fieldStyle(
            element,
            defaultW: defaultW,
            defaultH: defaultH,
            defaultBold: defaultBold,
            defaultAlign: defaultAlign
        )
        let fitted = MovieTicketPrintMetrics.fitTextToElementBox(
            text,
            frame: element.frame,
            paperWidth: template.paperSize.width,
            config: config,
            widthScale: resolved.widthScale,
            heightScale: resolved.heightScale,
            singleLineClip: element.singleLineClip == true
        )
        return Block(
            y: element.frame.y,
            height: element.frame.height,
            style: resolved,
            kind: .text(fitted.joined(separator: "\n")),
            label: label,
            x: element.frame.x,
            width: element.frame.width,
            boxConstrained: true
        )
    }

    private static func fieldStyle(
        _ el: MovieTicketElement?,
        defaultW: Int,
        defaultH: Int,
        defaultBold: Bool,
        defaultAlign: ESCPOSAlign
    ) -> FieldStyle {
        guard let el else {
            return FieldStyle(
                widthScale: defaultW,
                heightScale: defaultH,
                bold: defaultBold,
                align: defaultAlign,
                inverted: false,
                characterSpacing: 0
            )
        }
        let scale = MovieTicketRitzESCPOS.printScale(for: el)
        return FieldStyle(
            widthScale: scale.width,
            heightScale: scale.height,
            bold: el.isBold,
            align: escAlign(el.alignment),
            inverted: el.isInverted,
            characterSpacing: MovieTicketPrintMetrics.clampedCharacterSpacing(el.characterSpacing)
        )
    }

    private static func escAlign(_ alignment: Int) -> ESCPOSAlign {
        switch alignment {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }

    private static func barcodePayload(from serial: String) -> String {
        let filtered = serial.filter { $0.isNumber || $0 == "/" }
        return filtered.isEmpty ? String(serial.filter(\.isNumber)) : String(filtered)
    }

    private static func spacedHRI(_ code: String) -> String {
        let chars = Array(code)
        guard !chars.isEmpty else { return "" }
        return "* " + chars.map(String.init).joined(separator: " ") + " *"
    }

    private static func apply(_ builder: ESCPOSBuilder, _ style: FieldStyle) {
        builder.align(style.align)
            .bold(style.bold)
            .characterSpacing(UInt8(MovieTicketPrintMetrics.clampedCharacterSpacing(style.characterSpacing)))
            .applyMagnification(width: style.widthScale, height: style.heightScale)
    }

    private static func paddedIfInverted(_ text: String, inverted: Bool) -> String {
        guard inverted else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? " " : trimmed
        return " \(body) "
    }

    private static func emitInlineRow(
        builder: ESCPOSBuilder,
        items: [RowItem],
        paperWidth: CGFloat,
        config: PrinterConfig
    ) {
        let sorted = items.sorted { $0.x < $1.x }
        // Position in 1× paper columns so each fragment can keep its own GS ! scale.
        let cols = max(8, config.columnsPerLine)
        builder.align(.left)
        var col = 0
        for item in sorted {
            let text = paddedIfInverted(item.text, inverted: item.style.inverted)
            let iw = max(1, item.style.widthScale)
            let ih = max(1, item.style.heightScale)
            let target = columnIndex(x: item.x, paperWidth: paperWidth, columns: cols)
            let pad = max(0, target - col)
            if pad > 0 {
                builder.applyMagnification(width: 1, height: 1)
                builder.appendRawTextLine(String(repeating: " ", count: pad))
                col += pad
            }
            builder.bold(item.style.bold)
                .characterSpacing(UInt8(MovieTicketPrintMetrics.clampedCharacterSpacing(item.style.characterSpacing)))
                .applyMagnification(width: iw, height: ih)
            if item.style.inverted { builder.reversePrint(true) }
            builder.appendRawTextLine(text)
            if item.style.inverted { builder.reversePrint(false) }
            builder.characterSpacing(0)
            // Magnified glyphs consume `iw`× columns of the 1× paper grid.
            col += ReceiptTextLayout.displayWidth(text) * iw
        }
        builder.newline()
        builder.resetStyle()
        builder.selectFontA()
    }

    // MARK: - Preview drawing

    private static func drawText(
        _ text: String,
        style: FieldStyle,
        widthDots: Int,
        y: inout CGFloat,
        baseSize: CGFloat = 17,
        absoluteX: CGFloat? = nil
    ) {
        let wScale = max(1, style.widthScale)
        let hScale = max(1, style.heightScale)
        let cellH = MovieTicketPrintMetrics.fontACellDots.height * CGFloat(hScale)
        let font = NSFont(name: style.bold ? "Menlo-Bold" : "Menlo-Regular", size: baseSize)
            ?? .monospacedSystemFont(ofSize: baseSize, weight: style.bold ? .bold : .regular)
        let inkW = MovieTicketPrintMetrics.inkWidthDots(
            text: text,
            widthScale: wScale,
            characterSpacing: style.characterSpacing
        )
        var x: CGFloat
        if let absoluteX {
            x = absoluteX
        } else {
            switch style.align {
            case .center: x = max(0, (CGFloat(widthDots) - inkW) / 2)
            case .right: x = max(0, CGFloat(widthDots) - inkW)
            case .left: x = 0
            }
        }
        let fg = style.inverted ? NSColor.white : NSColor.black
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.scaleBy(x: CGFloat(wScale), y: CGFloat(hScale))
            if style.inverted {
                let pad: CGFloat = 2
                let localInk = inkW / CGFloat(wScale)
                let bg = NSRect(
                    x: -pad,
                    y: -pad,
                    width: localInk + pad * 2,
                    height: MovieTicketPrintMetrics.fontACellDots.height + pad * 2
                )
                NSColor.black.setFill()
                bg.fill()
            }
            MovieTicketPrintMetrics.drawSpacedFontAText(
                text,
                at: .zero,
                font: font,
                color: fg,
                widthScale: wScale,
                characterSpacing: style.characterSpacing,
                contextAlreadyScaled: true
            )
            ctx.restoreGState()
        }
        y += cellH
    }

    private static func drawInlineRow(
        items: [RowItem],
        paperWidth: CGFloat,
        widthDots: Int,
        config: PrinterConfig,
        y: inout CGFloat
    ) {
        let sorted = items.sorted { $0.x < $1.x }
        // Map canvas X with full 1× column grid; each fragment keeps its own scale.
        let cols = max(8, config.columnsPerLine)
        let charDots = CGFloat(widthDots) / CGFloat(cols)
        var maxBottom = y
        for item in sorted {
            let text = paddedIfInverted(item.text, inverted: item.style.inverted)
            let col = columnIndex(x: item.x, paperWidth: paperWidth, columns: cols)
            var ty = y
            drawText(
                text,
                style: item.style,
                widthDots: widthDots,
                y: &ty,
                absoluteX: CGFloat(col) * charDots
            )
            maxBottom = max(maxBottom, ty)
        }
        y = maxBottom
    }

    /// Map canvas X (paper points) to a 0-based character column.
    private static func columnIndex(x: CGFloat, paperWidth: CGFloat, columns: Int) -> Int {
        let cols = max(1, columns)
        let raw = Int((x / max(paperWidth, 1) * CGFloat(cols)).rounded(.down))
        return max(0, min(cols - 1, raw))
    }

    /// One ESC/POS line: place `left` at `leftX`, `right` at `rightX` (canvas points).
    private static func positionedPairLine(
        left: String,
        right: String,
        leftX: CGFloat,
        rightX: CGFloat,
        paperWidth: CGFloat,
        columns: Int
    ) -> String {
        let cols = max(8, columns)
        let leftCol = columnIndex(x: leftX, paperWidth: paperWidth, columns: cols)
        var rightCol = columnIndex(x: rightX, paperWidth: paperWidth, columns: cols)

        let rightW = ReceiptTextLayout.displayWidth(right)
        // Keep price fully on the line.
        if rightCol + rightW > cols {
            rightCol = max(0, cols - rightW)
        }

        let leftMax = max(1, rightCol - leftCol - 1)
        let leftPart = ReceiptTextLayout.clip(left, maxColumns: leftMax)
        let leftW = ReceiptTextLayout.displayWidth(leftPart)

        // If boxes overlap in columns, push price just after type.
        if rightCol < leftCol + leftW {
            rightCol = min(cols - rightW, leftCol + leftW + 1)
        }

        var line = String(repeating: " ", count: leftCol) + leftPart
        let cur = ReceiptTextLayout.displayWidth(line)
        let pad = max(0, rightCol - cur)
        line += String(repeating: " ", count: pad) + right
        return line
    }
}
