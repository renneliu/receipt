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
    }

    private enum BlockKind {
        case logo
        case barcode(payload: String, heightDots: UInt8, moduleWidth: UInt8)
        case text(String)
        /// Same-line type + price; `leftX` / `rightX` are canvas points → column placement.
        case typePrice(left: String, right: String, leftX: CGFloat, rightX: CGFloat)
    }

    private struct Block {
        var y: CGFloat
        var height: CGFloat
        var style: FieldStyle
        var kind: BlockKind
        var label: String
    }

    private static let barcodeModuleWidth: UInt8 = 3
    private static let defaultLogoWidthFraction: CGFloat = 0.80
    /// Serial field within this distance below a barcode is treated as HRI (skip duplicate).
    private static let serialUnderBarcodeSlop: CGFloat = 40

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
                builder.text(text).newline()
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
                    drawText(text, style: block.style, widthDots: widthDots, y: &ty)
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
                    label: "logo"
                ))
            case .textBox, .currentDate, .currentTime:
                let text = expandStaticText(el, draft: draft, now: Date())
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(Block(
                    y: el.frame.y,
                    height: el.frame.height,
                    style: fieldStyle(el, defaultW: 1, defaultH: 1, defaultBold: el.isBold, defaultAlign: escAlign(el.alignment)),
                    kind: .text(text),
                    label: "text:\(String(text.prefix(12)))"
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
                        label: "barcode"
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
                            label: "typePrice"
                        ))
                    } else {
                        blocks.append(Block(
                            y: el.frame.y,
                            height: el.frame.height,
                            style: fieldStyle(el, defaultW: 1, defaultH: 1, defaultBold: el.isBold, defaultAlign: escAlign(el.alignment)),
                            kind: .text(left.isEmpty ? " " : left),
                            label: "ticketType"
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
                        label: "ticketPrice"
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
                    blocks.append(Block(
                        y: el.frame.y,
                        height: el.frame.height,
                        style: fieldStyle(
                            el,
                            defaultW: defaults.w,
                            defaultH: defaults.h,
                            defaultBold: defaults.bold,
                            defaultAlign: defaults.align
                        ),
                        kind: .text(value.isEmpty ? " " : value),
                        label: kind.rawValue
                    ))
                }
            }
        }

        return blocks.sorted {
            if abs($0.y - $1.y) < 0.5 { return $0.label < $1.label }
            return $0.y < $1.y
        }
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
        case .seatArea:
            if draft.seatModeUnallocated { return template.unallocatedSeatLabel }
            return draft.seatArea
        case .ticketPrice: return draft.formattedPrice
        case .ticketType: return draft.ticketType
        case .serialNumber: return draft.serialNumber
        case .hall: return draft.hall
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
                align: defaultAlign
            )
        }
        let scale = MovieTicketRitzESCPOS.printScale(fontSize: el.fontSize, boxHeight: el.frame.height)
        return FieldStyle(
            widthScale: scale.width,
            heightScale: scale.height,
            bold: el.isBold,
            align: escAlign(el.alignment)
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

    // MARK: - Preview drawing

    private static func drawText(
        _ text: String,
        style: FieldStyle,
        widthDots: Int,
        y: inout CGFloat,
        baseSize: CGFloat = 17
    ) {
        let wScale = max(1, style.widthScale)
        let hScale = max(1, style.heightScale)
        let cellH = MovieTicketPrintMetrics.fontACellDots.height * CGFloat(hScale)
        let font = NSFont(name: style.bold ? "Menlo-Bold" : "Menlo-Regular", size: baseSize)
            ?? .monospacedSystemFont(ofSize: baseSize, weight: style.bold ? .bold : .regular)
        let colWidth = max(1, ReceiptTextLayout.displayWidth(text))
        let inkW = CGFloat(colWidth) * MovieTicketPrintMetrics.fontACellDots.width * CGFloat(wScale)
        var x: CGFloat = 0
        switch style.align {
        case .center: x = max(0, (CGFloat(widthDots) - inkW) / 2)
        case .right: x = max(0, CGFloat(widthDots) - inkW)
        case .left: x = 8
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.scaleBy(x: CGFloat(wScale), y: CGFloat(hScale))
            (text as NSString).draw(at: .zero, withAttributes: attrs)
            ctx.restoreGState()
        }
        y += cellH
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
