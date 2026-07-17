import AppKit
import Foundation

/// Native ESC/POS dual-stub ticket matching Ritz Cinemas thermal layout.
///
/// Locked baseline (user Figure 3 / diag 20260716-153752):
/// Font B, header GS ! 0x11, title GS ! 0x12, dash ×48,
/// top stub ends with serial text, bottom stub has Code128 + spaced HRI.
///
/// H35: prepend 96 NUL bytes so the POS-80's dropped first 64-byte USB packet is
/// harmless padding (top stub no longer loses `Ritz Cinemas`/`Cinema 1`).
/// H36: match Figure-2 proportions. Measured (photos normalized to same paper
/// width): mine filled 61% of the width, target 86% — the classic Font B (9-dot)
/// vs Font A (12-dot) ratio. Switch to Font A (48 cols) so text fills the paper
/// like the real ticket; retune font-dependent column constants (table width 48,
/// dash 44) and widen the barcode module (GS w 3) toward the target's wider code.
enum MovieTicketRitzESCPOS {
    /// Printed size/weight/alignment for one line, resolved from a template element.
    private struct FieldStyle {
        var widthScale: Int = 1
        var heightScale: Int = 1
        var bold: Bool = false
        var align: ESCPOSAlign = .left
    }

    private struct TicketStyles {
        var cinema = FieldStyle()
        var hall = FieldStyle()
        var title = FieldStyle()
        var start = FieldStyle()
        var end = FieldStyle()
        var seat = FieldStyle()
        var serial = FieldStyle()
    }

    /// Resolved ticket content + styles shared by ESC/POS emit and screen preview.
    private struct ResolvedTicket {
        var cinema: String
        var hall: String
        var title: String
        var startLine: String
        var endLine: String
        var seat: String
        var typePrice: String
        var serial: String
        var barcodePayload: String
        var styles: TicketStyles
        var titleClipCols: Int?
        var barcodeHeight: UInt8
        var dashStyle: FieldStyle
        var dashContent: String
    }

    private static func resolve(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        now: Date
    ) -> ResolvedTicket {
        let cinemaEl = template.elements.first {
            $0.kind == .textBox && $0.content.contains(where: { $0.isLetter })
        }
        let dashEl = template.elements.first {
            $0.kind == .textBox && !$0.content.isEmpty && $0.content.allSatisfy { $0 == "-" }
        }
        let styles = TicketStyles(
            cinema: fieldStyle(cinemaEl),
            hall: fieldStyle(firstField(template, .hall)),
            title: fieldStyle(firstField(template, .movieTitle)),
            start: fieldStyle(firstField(template, .startTime)),
            end: fieldStyle(firstField(template, .endTime)),
            seat: fieldStyle(firstField(template, .seatArea)),
            serial: fieldStyle(firstField(template, .serialNumber))
        )
        let dashStyle = fieldStyle(dashEl)
        let dashContent: String = {
            guard let c = dashEl?.content, !c.isEmpty else { return String(repeating: "-", count: 44) }
            return c
        }()
        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let hallEl = firstField(template, .hall)
        let hallText = hallEl?.resolvedHallText(from: draft)
            ?? draft.hall.trimmingCharacters(in: .whitespacesAndNewlines)
        return ResolvedTicket(
            cinema: cinemaName(from: template),
            hall: hallText,
            title: draft.movieTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            startLine: startDateTime(draft: draft, template: template),
            endLine: endDateTime(draft: draft, template: template),
            seat: seatText(draft: draft, template: template),
            typePrice: typeAndPrice(draft: draft),
            serial: serial,
            barcodePayload: barcodePayload(from: serial),
            styles: styles,
            titleClipCols: titleClipColumns(
                template: template, config: config, widthScale: styles.title.widthScale
            ),
            barcodeHeight: barcodeHeightDots(firstField(template, .barcode)),
            dashStyle: dashStyle,
            dashContent: dashContent
        )
    }

    static func render(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        now: Date = Date()
    ) -> Data {
        let ticket = resolve(template: template, draft: draft, config: config, now: now)

        let builder = ESCPOSBuilder(config: config)
        builder.jobStartPadding(bytes: 96)
        builder.initialize()
        builder.selectFontA()
        builder.applyTextSize(.normal).bold(false).align(.left)
        builder.feed(lines: 4)

        renderStub(
            builder,
            cinema: ticket.cinema,
            hall: ticket.hall,
            title: ticket.title,
            startLine: ticket.startLine,
            endLine: ticket.endLine,
            seat: ticket.seat,
            typePrice: ticket.typePrice,
            serial: ticket.serial,
            barcodePayload: ticket.barcodePayload,
            includeBarcode: false,
            titleClipCols: ticket.titleClipCols,
            styles: ticket.styles,
            barcodeHeight: ticket.barcodeHeight
        )

        builder
            .align(ticket.dashStyle.align)
            .bold(ticket.dashStyle.bold)
            .applyMagnification(width: ticket.dashStyle.widthScale, height: ticket.dashStyle.heightScale)
            .text(ticket.dashContent)
            .newline()

        renderStub(
            builder,
            cinema: ticket.cinema,
            hall: ticket.hall,
            title: ticket.title,
            startLine: ticket.startLine,
            endLine: ticket.endLine,
            seat: ticket.seat,
            typePrice: ticket.typePrice,
            serial: ticket.serial,
            barcodePayload: ticket.barcodePayload,
            includeBarcode: true,
            titleClipCols: ticket.titleClipCols,
            styles: ticket.styles,
            barcodeHeight: ticket.barcodeHeight
        )

        builder.selectFontA()
        builder.resetLineSpacing()
        let feed = template.resolvedFeedLinesBeforeCut(config: config)
        return builder.cut(feedLines: feed).build()
    }

    /// Screen preview that follows the same Font A + GS ! sequence as `render` (not the canvas Courier layout).
    /// Uses a flipped `NSImage` drawing block — never assigns `NSGraphicsContext.current` (that traps during SwiftUI layout).
    static func previewImage(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        now: Date = Date()
    ) -> NSImage {
        let ticket = resolve(template: template, draft: draft, config: config, now: now)
        let widthDots = max(8, config.dotsPerLine)
        let width = CGFloat(widthDots)
        let advance1x = MovieTicketPrintMetrics.fontACellDots.height

        // Measure first (no drawing / no graphics context).
        var measureY: CGFloat = advance1x * 4
        measureStubPreview(ticket: ticket, includeBarcode: false, config: config, y: &measureY)
        measureY += lineAdvance(style: ticket.dashStyle)
        measureStubPreview(ticket: ticket, includeBarcode: true, config: config, y: &measureY)
        measureY += advance1x * 2
        let height = max(1 as CGFloat, ceil(measureY))

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            var y: CGFloat = advance1x * 4
            drawStubPreview(
                ticket: ticket,
                includeBarcode: false,
                config: config,
                widthDots: widthDots,
                y: &y
            )
            drawTextLine(
                ticket.dashContent,
                style: ticket.dashStyle,
                widthDots: widthDots,
                y: &y
            )
            drawStubPreview(
                ticket: ticket,
                includeBarcode: true,
                config: config,
                widthDots: widthDots,
                y: &y
            )
            return true
        }
    }

    private static func lineAdvance(style: FieldStyle) -> CGFloat {
        MovieTicketPrintMetrics.fontACellDots.height * CGFloat(max(1, style.heightScale))
    }

    private static func measureStubPreview(
        ticket: ResolvedTicket,
        includeBarcode: Bool,
        config: PrinterConfig,
        y: inout CGFloat
    ) {
        y += lineAdvance(style: ticket.styles.cinema)
        y += lineAdvance(style: ticket.styles.hall)
        y += lineAdvance(style: ticket.styles.title)
        y += lineAdvance(style: ticket.styles.start)
        y += lineAdvance(style: ticket.styles.end)
        y += lineAdvance(style: ticket.styles.seat)
        if includeBarcode {
            y += CGFloat(ticket.barcodeHeight) + 4
            y += lineAdvance(style: ticket.styles.serial)
        } else {
            y += lineAdvance(style: ticket.styles.serial)
        }
        _ = config
    }

    private static func drawStubPreview(
        ticket: ResolvedTicket,
        includeBarcode: Bool,
        config: PrinterConfig,
        widthDots: Int,
        y: inout CGFloat
    ) {
        let cols = config.columnsPerLine
        drawTextLine(
            ticket.cinema.isEmpty ? "Ritz Cinemas" : ticket.cinema,
            style: ticket.styles.cinema,
            widthDots: widthDots,
            y: &y
        )
        drawTextLine(
            ticket.hall.isEmpty ? " " : ticket.hall,
            style: ticket.styles.hall,
            widthDots: widthDots,
            y: &y
        )
        let titleText = ticket.title.isEmpty ? " " : ticket.title
        let titleDrawn: String = {
            if let c = ticket.titleClipCols {
                return ReceiptTextLayout.clip(titleText, maxColumns: c)
            }
            return titleText
        }()
        drawTextLine(titleDrawn, style: ticket.styles.title, widthDots: widthDots, y: &y)
        drawTextLine(ticket.startLine, style: ticket.styles.start, widthDots: widthDots, y: &y)
        drawTextLine(ticket.endLine, style: ticket.styles.end, widthDots: widthDots, y: &y)

        // Match ESCPOSBuilder.tableRow: when width ≥2×, effective columns = base/2.
        let seatStyle = ticket.styles.seat
        let tableCols = max(8, seatStyle.widthScale >= 2 ? cols / 2 : cols)
        let left = ticket.seat.isEmpty ? "ADMIT" : ticket.seat
        let right = ticket.typePrice
        let rightWidth = ReceiptTextLayout.displayWidth(right)
        let leftMax = max(2, tableCols - rightWidth - 1)
        let leftPart = ReceiptTextLayout.clip(left, maxColumns: leftMax)
        let leftW = ReceiptTextLayout.displayWidth(leftPart)
        let padding = max(1, tableCols - leftW - rightWidth)
        let row = leftPart + String(repeating: " ", count: padding) + right
        drawTextLine(row, style: seatStyle, widthDots: widthDots, y: &y)

        if includeBarcode {
            let code = ticket.barcodePayload.isEmpty ? "000000" : ticket.barcodePayload
            let barH = CGFloat(ticket.barcodeHeight)
            let barW = CGFloat(widthDots) * 0.92
            let barX = (CGFloat(widthDots) - barW) / 2
            if let img = MovieTicketPrintComposer.makeCode128Barcode(
                content: code,
                size: CGSize(width: barW, height: barH)
            ) {
                img.draw(
                    in: NSRect(x: barX, y: y, width: barW, height: barH),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            y += barH + 4
            var serialStyle = ticket.styles.serial
            serialStyle.bold = false
            drawTextLine(spacedHRI(code), style: serialStyle, widthDots: widthDots, y: &y)
        } else {
            var serialStyle = ticket.styles.serial
            serialStyle.bold = false
            drawTextLine(
                ticket.serial.isEmpty ? " " : ticket.serial,
                style: serialStyle,
                widthDots: widthDots,
                y: &y
            )
        }
    }

    /// Draw one ESC/POS Font A line using GS ! style magnification (cell 12×24 dots × scales).
    /// Assumes a top-down (flipped) graphics context.
    private static func drawTextLine(
        _ text: String,
        style: FieldStyle,
        widthDots: Int,
        y: inout CGFloat
    ) {
        let wScale = max(1, style.widthScale)
        let hScale = max(1, style.heightScale)
        let cellH = MovieTicketPrintMetrics.fontACellDots.height * CGFloat(hScale)
        let baseSize: CGFloat = 17 // ~24-dot Font A body at 1×
        let font = NSFont(name: style.bold ? "Menlo-Bold" : "Menlo-Regular", size: baseSize)
            ?? .monospacedSystemFont(ofSize: baseSize, weight: style.bold ? .bold : .regular)

        let colWidth = max(1, ReceiptTextLayout.displayWidth(text))
        let inkW = CGFloat(colWidth) * MovieTicketPrintMetrics.fontACellDots.width * CGFloat(wScale)
        var x: CGFloat = 0
        switch style.align {
        case .center: x = max(0, (CGFloat(widthDots) - inkW) / 2)
        case .right: x = max(0, CGFloat(widthDots) - inkW)
        case .left: x = 0
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
        } else {
            (text as NSString).draw(
                in: NSRect(x: x, y: y, width: inkW, height: cellH),
                withAttributes: attrs
            )
        }
        y += cellH
    }

    private static func renderStub(
        _ builder: ESCPOSBuilder,
        cinema: String,
        hall: String,
        title: String,
        startLine: String,
        endLine: String,
        seat: String,
        typePrice: String,
        serial: String,
        barcodePayload: String,
        includeBarcode: Bool,
        titleClipCols: Int?,
        styles: TicketStyles,
        barcodeHeight: UInt8
    ) {
        apply(builder, styles.cinema)
        builder.text(cinema.isEmpty ? "Ritz Cinemas" : cinema).newline()

        apply(builder, styles.hall)
        builder.text(hall.isEmpty ? " " : hall).newline()

        apply(builder, styles.title)
        let titleText = title.isEmpty ? " " : title
        if let cols = titleClipCols {
            // Single line: clip to the box width, no wrap to a second line.
            builder.appendRawTextLine(ReceiptTextLayout.clip(titleText, maxColumns: cols)).newline()
        } else {
            builder.text(titleText).newline()
        }

        apply(builder, styles.start)
        builder.text(startLine).newline()

        apply(builder, styles.end)
        builder.text(endLine).newline()

        apply(builder, styles.seat)
        builder.tableRow(left: seat.isEmpty ? "ADMIT" : seat, right: typePrice)

        if includeBarcode {
            let code = barcodePayload.isEmpty ? "000000" : barcodePayload
            builder.barcode(type: .code128, content: code, height: barcodeHeight, width: 3, printHRI: false)
            apply(builder, styles.serial)
            builder.bold(false).text(spacedHRI(code)).newline()
        } else {
            apply(builder, styles.serial)
            builder.bold(false).text(serial.isEmpty ? " " : serial).newline()
        }

        builder.resetStyle()
    }

    private static func apply(_ builder: ESCPOSBuilder, _ style: FieldStyle) {
        builder.align(style.align)
            .bold(style.bold)
            .applyMagnification(width: style.widthScale, height: style.heightScale)
    }

    // MARK: - Style resolution

    private static func firstField(
        _ template: MovieTicketTemplate, _ kind: MovieTicketFieldKind
    ) -> MovieTicketElement? {
        template.elements.first { $0.kind == .fieldPlaceholder && $0.fieldKind == kind }
    }

    /// Printed magnification (width, height) the built-in font will use for an element.
    /// The built-in font only scales in whole steps, so this is always 1…3 per axis.
    /// - width comes from the font size (×1/×2/×3),
    /// - height follows the box height but is clamped to `[width, width+1]` so text is
    ///   never distorted (e.g. never a thin-tall ×1 wide / ×3 tall), while still letting
    ///   a deliberately tall box give the movie title its ×2 wide / ×3 tall stretch.
    static func printScale(fontSize: CGFloat, boxHeight: CGFloat) -> (width: Int, height: Int) {
        let w: Int = fontSize <= 11 ? 1 : (fontSize <= 16 ? 2 : 3)
        let boxHS = max(1, min(3, Int((boxHeight / 12).rounded())))
        let h = max(w, min(min(3, boxHS), w + 1))
        return (w, h)
    }

    private static func escAlign(_ alignment: Int) -> ESCPOSAlign {
        switch alignment {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }

    private static func fieldStyle(_ el: MovieTicketElement?) -> FieldStyle {
        guard let el else { return FieldStyle() }
        let scale = printScale(fontSize: el.fontSize, boxHeight: el.frame.height)
        return FieldStyle(
            widthScale: scale.width,
            heightScale: scale.height,
            bold: el.isBold,
            align: escAlign(el.alignment)
        )
    }

    /// Barcode element box height → Code128 dot height (default box 72 pt → 110 dots).
    private static func barcodeHeightDots(_ el: MovieTicketElement?) -> UInt8 {
        let h = el?.frame.height ?? 72
        let dots = Int((h * (110.0 / 72.0)).rounded())
        return UInt8(max(24, min(255, dots)))
    }

    /// Columns the movie title may occupy on one line when "single line / clip
    /// overflow" is enabled on its element; nil = wrap (legacy). Derived from the
    /// title box width at its printed character size (Font A × the title width scale).
    private static func titleClipColumns(
        template: MovieTicketTemplate, config: PrinterConfig, widthScale: Int
    ) -> Int? {
        // Title defaults to single-line clip; only an explicit `false` re-enables wrap.
        guard let el = template.elements.first(where: {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .movieTitle
        }), el.singleLineClip != false else { return nil }
        let scale = CGFloat(max(1, widthScale))
        let paperW = max(1, template.paperSize.width)
        let charDots = CGFloat(config.dotsPerLine) / CGFloat(max(1, config.columnsPerLine)) * scale
        let boxDots = el.frame.width * CGFloat(config.dotsPerLine) / paperW
        let cols = Int((boxDots / max(1, charDots)).rounded(.down))
        return max(1, min(cols, config.columnsPerLine / Int(scale)))
    }

    private static func cinemaName(from template: MovieTicketTemplate) -> String {
        let boxes = template.elements.filter { $0.kind == .textBox }
        if let box = boxes.first(where: { el in
            let t = el.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t.contains(where: \.isLetter)
        }) {
            return box.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Ritz Cinemas"
    }

    private static func seatText(draft: MovieTicketDraft, template: MovieTicketTemplate) -> String {
        if draft.seatModeUnallocated {
            return template.unallocatedSeatLabel
        }
        return draft.seatArea.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func typeAndPrice(draft: MovieTicketDraft) -> String {
        let type = draft.ticketType.trimmingCharacters(in: .whitespacesAndNewlines)
        let price = draft.formattedPrice
        if type.isEmpty { return price }
        if price.isEmpty { return type }
        return "\(type) \(price)"
    }

    private static func startDateTime(draft: MovieTicketDraft, template: MovieTicketTemplate) -> String {
        let el = template.elements.first {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .startTime
        }
        let fmt = el?.timeFormat ?? .eeeMMMdhmma
        return fmt.format(draft.combinedStart)
    }

    private static func endDateTime(draft: MovieTicketDraft, template: MovieTicketTemplate) -> String {
        let el = template.elements.first {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .endTime
        }
        let fmt = el?.timeFormat ?? .ddMMyyyyhmmssa
        let body = fmt.format(draft.showEndTime)
        let prefix = el?.content ?? "Session End Time: "
        return prefix.isEmpty ? body : prefix + body
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
}
