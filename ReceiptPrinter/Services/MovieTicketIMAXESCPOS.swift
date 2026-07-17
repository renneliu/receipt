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
    }

    private struct RowItem {
        var text: String
        var x: CGFloat
        var style: FieldStyle
        var label: String
    }

    private enum BlockKind {
        case logo
        case barcode(payload: String, heightDots: UInt8, moduleWidth: UInt8)
        case text(String)
        /// Same-line type + price; `leftX` / `rightX` are canvas points → column placement.
        case typePrice(left: String, right: String, leftX: CGFloat, rightX: CGFloat)
        /// Canvas elements that share approximately the same Y (e.g. cinema name + hall).
        case inlineRow(items: [RowItem])
    }

    private struct Block {
        var y: CGFloat
        var height: CGFloat
        var style: FieldStyle
        var kind: BlockKind
        var label: String
        /// Canvas X — used to place same-row items left→right.
        var x: CGFloat = 0
        /// When true, emit via `appendRawTextLine` (no ESC/POS wrap).
        var forceSingleLine: Bool = false
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
        let linePts = MovieTicketPrintMetrics.lineHeightPoints(
            heightScale: 1, paperWidth: paperW, dotsPerLine: config.dotsPerLine
        )

        let builder = ESCPOSBuilder(config: config)
        builder.jobStartPadding(bytes: 96)
        builder.initialize()
        builder.selectFontA()
        builder.applyTextSize(.normal).bold(false).align(.center)
        builder.feed(lines: 1)

        // Cursor tracks canvas Y of the last ink bottom. Overlapping boxes (next.y < cursor)
        // produce zero feed so row spacing can be tightened on the canvas.
        var cursorY: CGFloat?
        for block in blocks {
            if let prev = cursorY {
                let gap = block.y - prev
                let feeds = max(0, Int((gap / max(linePts, 1)).rounded()))
                if feeds > 0 { builder.feed(lines: min(feeds, 20)) }
            }

            let advance: CGFloat
            switch block.kind {
            case .logo:
                if let logo = logoImage {
                    let maxW = logoMaxWidth(template: template, config: config)
                    builder.imageBanded(logo, maxWidth: maxW, bandHeight: 48, scaleToWidth: true)
                }
                advance = block.height
            case .barcode(let payload, let heightDots, let moduleWidth):
                let code = payload.isEmpty ? "000000" : payload
                builder.barcode(
                    type: .code128,
                    content: code,
                    height: heightDots,
                    width: moduleWidth,
                    printHRI: false
                )
                apply(builder, FieldStyle(widthScale: 1, heightScale: 1, bold: false, align: .center))
                builder.text(spacedHRI(code)).newline()
                let barPts = CGFloat(heightDots) * MovieTicketPrintMetrics.pointsPerDot(
                    paperWidth: paperW, dotsPerLine: config.dotsPerLine
                )
                advance = barPts + linePts
            case .text(let text):
                // Long meta line: Font B so it fits one row.
                if text.contains("EFTP") || text.contains("T/N:") {
                    builder.selectFontB(columns: 64)
                } else {
                    builder.selectFontA()
                }
                apply(builder, block.style)
                let emitText = paddedIfInverted(text, inverted: block.style.inverted)
                if block.style.inverted { builder.reversePrint(true) }
                if block.forceSingleLine {
                    // Already clipped to the element box; do not re-wrap.
                    builder.appendRawTextLine(emitText).newline()
                } else {
                    builder.text(emitText).newline()
                }
                if block.style.inverted { builder.reversePrint(false) }
                builder.selectFontA()
                advance = linePts * CGFloat(max(1, block.style.heightScale))
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
                advance = linePts * CGFloat(max(1, block.style.heightScale))
            case .inlineRow(let items):
                builder.selectFontA()
                emitInlineRow(
                    builder: builder,
                    items: items,
                    paperWidth: paperW,
                    config: config
                )
                let hScale = items.map(\.style.heightScale).max() ?? block.style.heightScale
                advance = linePts * CGFloat(max(1, hScale))
            }

            // Prefer canvas overlap: advance from block.y by printed height (not full box
            // height), so stacking boxes closer than their frames still packs on paper.
            cursorY = block.y + min(block.height, advance)
        }

        builder.resetStyle()
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
                        let x = (width - drawW) / 2
                        // Preview uses a flipped NSImage context; without respectFlipped
                        // the bitmap appears upside-down / mirrored relative to text.
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
                    let barX = (width - barW) / 2
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
                case .text(let text):
                    var ty = y
                    drawText(
                        paddedIfInverted(text, inverted: block.style.inverted),
                        style: block.style,
                        widthDots: widthDots,
                        y: &ty
                    )
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
                    drawText(line, style: FieldStyle(align: .left), widthDots: widthDots, y: &ty)
                case .inlineRow(let items):
                    var ty = y
                    drawInlineRow(
                        items: items,
                        paperWidth: paperW,
                        widthDots: widthDots,
                        config: config,
                        y: &ty
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
        // Always print type + price on one line; horizontal placement follows canvas X.
        if typeEl != nil, let priceEl {
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
                    style: FieldStyle(align: .center),
                    kind: .logo,
                    label: "logo",
                    x: el.frame.x
                ))
            case .textBox, .currentDate, .currentTime:
                let text = expandStaticText(el, draft: draft, now: Date())
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(Block(
                    y: el.frame.y,
                    height: el.frame.height,
                    style: fieldStyle(el, defaultW: 1, defaultH: 1, defaultBold: el.isBold, defaultAlign: escAlign(el.alignment)),
                    kind: .text(text),
                    label: "text:\(String(text.prefix(12)))",
                    x: el.frame.x
                ))
            case .fieldPlaceholder:
                guard let kind = el.fieldKind else { continue }
                switch kind {
                case .barcode:
                    let dots = barcodeHeightDots(el)
                    blocks.append(Block(
                        y: el.frame.y,
                        height: el.frame.height + 16,
                        style: FieldStyle(align: .center),
                        kind: .barcode(
                            payload: payload,
                            heightDots: dots,
                            moduleWidth: barcodeModuleWidth
                        ),
                        label: "barcode",
                        x: el.frame.x
                    ))
                case .qrCode:
                    continue
                case .ticketType:
                    let left = draft.ticketType.trimmingCharacters(in: .whitespacesAndNewlines)
                    let right = draft.formattedPrice
                    if let priceEl {
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
                            x: el.frame.x
                        ))
                    } else {
                        blocks.append(Block(
                            y: el.frame.y,
                            height: el.frame.height,
                            style: fieldStyle(el, defaultW: 1, defaultH: 1, defaultBold: el.isBold, defaultAlign: escAlign(el.alignment)),
                            kind: .text(left.isEmpty ? " " : left),
                            label: "ticketType",
                            x: el.frame.x
                        ))
                    }
                case .ticketPrice:
                    // Skipped when type exists (merged into typePrice); alone → own line.
                    let value = draft.formattedPrice
                    blocks.append(Block(
                        y: el.frame.y,
                        height: el.frame.height,
                        style: fieldStyle(el, defaultW: 1, defaultH: 1, defaultBold: el.isBold, defaultAlign: escAlign(el.alignment)),
                        kind: .text(value.isEmpty ? " " : value),
                        label: "ticketPrice",
                        x: el.frame.x
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
                    var forceSingleLine = false
                    if kind == .movieTitle, el.singleLineClip != false,
                       let clipCols = titleClipColumns(
                        element: el, config: config, widthScale: style.widthScale, paperWidth: template.paperSize.width
                       ) {
                        value = ReceiptTextLayout.clip(value, maxColumns: clipCols)
                        forceSingleLine = true
                    }
                    blocks.append(Block(
                        y: el.frame.y,
                        height: el.frame.height,
                        style: style,
                        kind: .text(value.isEmpty ? " " : value),
                        label: kind.rawValue,
                        x: el.frame.x,
                        forceSingleLine: forceSingleLine
                    ))
                }
            }
        }

        let sorted = blocks.sorted {
            if abs($0.y - $1.y) <= sameRowYTolerance { return $0.x < $1.x }
            return $0.y < $1.y
        }
        return mergeSameRowTextBlocks(sorted)
    }

    /// Collapse consecutive `.text` blocks that share approximately the same canvas Y.
    private static func mergeSameRowTextBlocks(_ blocks: [Block]) -> [Block] {
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
                result.append(Block(
                    y: group.map(\.0.y).min() ?? block.y,
                    height: group.map(\.0.height).max() ?? block.height,
                    style: rowStyle,
                    kind: .inlineRow(items: items),
                    label: items.map(\.label).joined(separator: "+"),
                    x: items.first?.x ?? block.x
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
        case .movieTitle: return draft.movieTitle
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
        let scale = CGFloat(max(1, widthScale))
        let paperW = max(1, paperWidth)
        let charDots = CGFloat(config.dotsPerLine) / CGFloat(max(1, config.columnsPerLine)) * scale
        let boxDots = element.frame.width * CGFloat(config.dotsPerLine) / paperW
        let cols = Int((boxDots / max(1, charDots)).rounded(.down))
        return max(1, min(cols, config.columnsPerLine / Int(scale)))
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
                inverted: false
            )
        }
        let scale = MovieTicketRitzESCPOS.printScale(fontSize: el.fontSize, boxHeight: el.frame.height)
        return FieldStyle(
            widthScale: scale.width,
            heightScale: scale.height,
            bold: el.isBold,
            align: escAlign(el.alignment),
            inverted: el.isInverted
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
        let wScale = max(1, sorted.map(\.style.widthScale).max() ?? 1)
        let hScale = max(1, sorted.map(\.style.heightScale).max() ?? 1)
        let cols = max(8, config.columnsPerLine / wScale)
        builder.align(.left)
            .applyMagnification(width: wScale, height: hScale)
        var col = 0
        for item in sorted {
            let text = paddedIfInverted(item.text, inverted: item.style.inverted)
            let target = columnIndex(x: item.x, paperWidth: paperWidth, columns: cols)
            let pad = max(0, target - col)
            if pad > 0 {
                builder.appendRawTextLine(String(repeating: " ", count: pad))
                col += pad
            }
            builder.bold(item.style.bold)
            if item.style.inverted { builder.reversePrint(true) }
            builder.appendRawTextLine(text)
            if item.style.inverted { builder.reversePrint(false) }
            col += ReceiptTextLayout.displayWidth(text)
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
        let colWidth = max(1, ReceiptTextLayout.displayWidth(text))
        let inkW = CGFloat(colWidth) * MovieTicketPrintMetrics.fontACellDots.width * CGFloat(wScale)
        var x: CGFloat
        if let absoluteX {
            x = absoluteX
        } else {
            switch style.align {
            case .center: x = max(0, (CGFloat(widthDots) - inkW) / 2)
            case .right: x = max(0, CGFloat(widthDots) - inkW)
            case .left: x = 8
            }
        }
        let fg = style.inverted ? NSColor.white : NSColor.black
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg
        ]
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.scaleBy(x: CGFloat(wScale), y: CGFloat(hScale))
            if style.inverted {
                let pad: CGFloat = 2
                let bg = NSRect(
                    x: -pad,
                    y: -pad,
                    width: CGFloat(colWidth) * MovieTicketPrintMetrics.fontACellDots.width + pad * 2,
                    height: MovieTicketPrintMetrics.fontACellDots.height + pad * 2
                )
                NSColor.black.setFill()
                bg.fill()
            }
            (text as NSString).draw(at: .zero, withAttributes: attrs)
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
        let wScale = max(1, sorted.map(\.style.widthScale).max() ?? 1)
        let cols = max(8, config.columnsPerLine / wScale)
        let charDots = CGFloat(widthDots) / CGFloat(cols)
        var maxBottom = y
        for item in sorted {
            let text = paddedIfInverted(item.text, inverted: item.style.inverted)
            let col = columnIndex(x: item.x, paperWidth: paperWidth, columns: cols)
            var ty = y
            var style = item.style
            style.widthScale = wScale
            style.heightScale = max(1, sorted.map(\.style.heightScale).max() ?? 1)
            drawText(text, style: style, widthDots: widthDots, y: &ty, absoluteX: CGFloat(col) * charDots)
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
