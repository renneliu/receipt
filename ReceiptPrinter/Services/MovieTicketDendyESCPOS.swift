import AppKit
import Foundation

/// Native ESC/POS single-stub ticket matching Dendy Cinemas' centered QR layout.
///
/// Typography follows template element `fontSize` / box height via
/// `MovieTicketRitzESCPOS.printScale` (same 1×/2×/3× controls as the template editor).
/// Title magnification mirrors cinema/seat; cinema/seat is forced onto one line
/// (prefer 3×3 → 2×3 before squaring to 2×2 so type stays taller than plain 2×2).
/// Vertical gaps between title / cinema / session follow canvas `frame.y` (like IMAX).
/// Session line stays wide 2×1 with year: `MMMM d, yyyy, h:mm a`.
enum MovieTicketDendyESCPOS {
    private struct LineStyle {
        var widthScale: Int
        var heightScale: Int
        var bold: Bool
        var align: ESCPOSAlign
    }

    private struct Fields {
        var title: String
        var cinemaSeat: String
        var sessionLine: String
        var endsLine: String
        var qrPayload: String
        var codeLine: String
        var ticketType: String
        var ticketLine: String
        var qrSizeDots: Int
        var titleLines: [String]
        var titleWrapCols: Int
        var titleStyle: LineStyle
        var cinemaStyle: LineStyle
        var sessionStyle: LineStyle
        var endsStyle: LineStyle
        var codeStyle: LineStyle
        var typeStyle: LineStyle
        var ticketStyle: LineStyle
        /// Extra dots after title before cinema (from canvas Y gap).
        var gapAfterTitleDots: UInt8
        /// Extra dots after cinema before session.
        var gapAfterCinemaDots: UInt8
    }

    static func render(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        now: Date = Date()
    ) -> Data {
        _ = now
        let fields = resolvedFields(template: template, draft: draft, config: config)
        let builder = ESCPOSBuilder(config: config)
        builder.jobStartPadding(bytes: 96)
        builder.initialize()
        builder.selectFontA()
        builder.feed(lines: 1)
        emit(builder, fields: fields, config: config)
        builder.resetStyle()
        builder.selectFontA()
        let feed = template.resolvedFeedLinesBeforeCut(config: config)
        return builder.cut(feedLines: feed).build()
    }

    static func previewImage(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig,
        now: Date = Date()
    ) -> NSImage {
        _ = now
        let fields = resolvedFields(template: template, draft: draft, config: config)
        let widthDots = max(8, config.dotsPerLine)
        let width = CGFloat(widthDots)
        let cell = MovieTicketPrintMetrics.fontACellDots

        var measureY: CGFloat = cell.height
        measureY += cell.height * CGFloat(fields.titleStyle.heightScale) * CGFloat(fields.titleLines.count)
        measureY += CGFloat(fields.gapAfterTitleDots)
        measureY += cell.height * CGFloat(fields.cinemaStyle.heightScale)
        measureY += CGFloat(fields.gapAfterCinemaDots)
        measureY += cell.height * CGFloat(fields.sessionStyle.heightScale)
        measureY += cell.height * CGFloat(fields.endsStyle.heightScale)
        measureY += cell.height // gap before QR
        measureY += CGFloat(fields.qrSizeDots)
        measureY += cell.height // gap after QR
        measureY += cell.height * CGFloat(fields.codeStyle.heightScale)
        measureY += cell.height // gap
        measureY += cell.height * CGFloat(fields.typeStyle.heightScale)
        measureY += cell.height * CGFloat(fields.ticketStyle.heightScale)
        measureY += cell.height * 2
        let height = max(1 as CGFloat, ceil(measureY))

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            var y: CGFloat = cell.height
            for line in fields.titleLines {
                drawEscposLine(
                    line,
                    y: &y,
                    widthDots: widthDots,
                    style: fields.titleStyle
                )
            }
            y += CGFloat(fields.gapAfterTitleDots)
            drawEscposLine(
                fields.cinemaSeat,
                y: &y,
                widthDots: widthDots,
                style: fields.cinemaStyle
            )
            y += CGFloat(fields.gapAfterCinemaDots)
            drawEscposLine(
                fields.sessionLine,
                y: &y,
                widthDots: widthDots,
                style: fields.sessionStyle
            )
            drawEscposLine(
                fields.endsLine,
                y: &y,
                widthDots: widthDots,
                style: fields.endsStyle
            )
            y += cell.height
            let qrSide = CGFloat(fields.qrSizeDots)
            let qrX = (width - qrSide) / 2
            if let img = BarcodeGenerator.makeQRCode(fields.qrPayload, size: fields.qrSizeDots) {
                img.draw(
                    in: NSRect(x: qrX, y: y, width: qrSide, height: qrSide),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            y += qrSide + cell.height
            drawEscposLine(
                fields.codeLine,
                y: &y,
                widthDots: widthDots,
                style: fields.codeStyle
            )
            y += cell.height
            drawEscposLine(
                fields.ticketType,
                y: &y,
                widthDots: widthDots,
                style: fields.typeStyle
            )
            drawEscposLine(
                fields.ticketLine,
                y: &y,
                widthDots: widthDots,
                style: fields.ticketStyle
            )
            return true
        }
    }

    // MARK: - Resolve

    private static func resolvedFields(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig
    ) -> Fields {
        let titleEl = firstField(template, .movieTitle)
        let hallEl = firstField(template, .hall)
        let seatEl = firstField(template, .seatArea)
        let dateEl = firstField(template, .showDate)
        let endEl = firstField(template, .endTime)
        let serialEl = firstField(template, .serialNumber)
        let typeEl = firstField(template, .ticketType)
        let qrEl = firstField(template, .qrCode)
        let ticketBox = template.elements.first {
            $0.kind == .textBox && $0.content.localizedCaseInsensitiveContains("ticket")
        }

        let hall = hallEl?.resolvedHallText(from: draft)
            ?? {
                let n = MovieTicketElement.extractHallNumber(from: draft.hall)
                return n.isEmpty ? draft.hall : "Cinema \(n)"
            }()

        let seatRaw: String = {
            if draft.seatModeUnallocated {
                return template.unallocatedSeatLabel.isEmpty ? "GA" : template.unallocatedSeatLabel
            }
            return draft.seatArea.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let seat: String = {
            guard !seatRaw.isEmpty else { return "" }
            if seatRaw.localizedCaseInsensitiveContains("seat") { return seatRaw }
            return "Seat \(seatRaw)"
        }()

        let cinemaSeat: String = {
            switch (hall.isEmpty, seat.isEmpty) {
            case (false, false): return "\(hall) - \(seat)"
            case (false, true): return hall
            case (true, false): return seat
            case (true, true): return " "
            }
        }()

        // Session: wide 2×1 with year — "July 9, 2026, 6:00 pm".
        let day = formatLowerAmPm(draft.showDate, pattern: "MMMM d, yyyy")
        let start = formatLowerAmPm(draft.combinedStart, pattern: "h:mm a")
        let end = formatLowerAmPm(draft.showEndTime, pattern: "h:mm a")
        let sessionLine = "\(day), \(start)"
        let endsPrefix = endEl?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsLine: String = {
            let prefix = (endsPrefix?.isEmpty == false) ? endsPrefix! : "Ends at"
            if prefix.hasSuffix(" ") { return prefix + end }
            return "\(prefix) \(end)"
        }()

        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticketDigits = MovieTicketDraft.serialBase(from: serial).filter(\.isNumber)
        let booking = draft.bookingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeDigits: String = {
            let fromBooking = booking.filter(\.isNumber)
            if !fromBooking.isEmpty { return fromBooking }
            if !ticketDigits.isEmpty { return ticketDigits }
            let all = serial.filter(\.isNumber)
            return all.isEmpty ? "0" : all
        }()
        let codePrefix = serialEl?.content ?? "Code: #"
        let prefixCore = codePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeLine: String = {
            if prefixCore.isEmpty { return "Code: #\(codeDigits)" }
            if prefixCore.hasSuffix("#") { return prefixCore + codeDigits }
            return prefixCore + codeDigits
        }()

        let ticketType = draft.ticketType.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticketCore = ticketDigits.isEmpty ? codeDigits : ticketDigits
        let ticketLine: String = {
            let raw = ticketBox?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty { return "Ticket #\(ticketCore)" }
            var text = raw
            text = text.replacingOccurrences(of: "{serial}", with: ticketCore)
            text = text.replacingOccurrences(of: "{serialNumber}", with: ticketCore)
            if text.contains("{") {
                return "Ticket #\(ticketCore)"
            }
            return text
        }()
        let qrPayload = booking.isEmpty ? (serial.isEmpty ? codeDigits : serial) : booking

        let paperW = max(1, template.paperSize.width)
        let qrSize: Int = {
            if let qrEl {
                let side = min(qrEl.frame.width, qrEl.frame.height)
                let dots = Int((side * CGFloat(config.dotsPerLine) / paperW).rounded())
                return max(120, min(config.dotsPerLine - 16, dots))
            }
            return max(180, min(220, Int(Double(config.dotsPerLine) * 0.38)))
        }()

        let title = draft.printedMovieTitle

        // Cinema/seat drives shared size; shrink until the line fits, then clip if needed.
        var cinemaStyle = maxStyle(
            style(from: hallEl, fallbackW: 3, fallbackH: 3),
            style(from: seatEl, fallbackW: 3, fallbackH: 3)
        )
        cinemaStyle = styleFittingOneLine(
            cinemaSeat,
            preferred: cinemaStyle,
            columnsPerLine: config.columnsPerLine
        )
        let cinemaCols = max(1, config.columnsPerLine / max(1, cinemaStyle.widthScale))
        let cinemaLine = ReceiptTextLayout.clip(cinemaSeat, maxColumns: cinemaCols)

        // Title uses the same magnification as cinema/seat; bold follows title element (default on).
        var titleStyle = cinemaStyle
        titleStyle.bold = titleEl?.isBold ?? true
        let titleWrapCols = min(
            20,
            max(8, config.columnsPerLine / max(1, titleStyle.widthScale))
        )
        let titleLines = wrapWords(title.isEmpty ? " " : title, maxColumns: titleWrapCols)

        // Locked Dendy session typography (wide only) — not editable via 1×/2×/3× picker.
        let sessionStyle = LineStyle(widthScale: 2, heightScale: 1, bold: false, align: .center)

        let endsStyle = style(from: endEl, fallbackW: 1, fallbackH: 1)
        let codeStyle = style(from: serialEl, fallbackW: 2, fallbackH: 2)
        let typeStyle = style(from: typeEl, fallbackW: 1, fallbackH: 2, fallbackBold: true)
        let ticketStyle = style(from: ticketBox, fallbackW: 1, fallbackH: 1)

        // Canvas Y → inter-row gaps (same idea as IMAX: overlap ⇒ 0 extra feed).
        let titleLinePts = MovieTicketPrintMetrics.lineHeightPoints(
            heightScale: titleStyle.heightScale,
            paperWidth: paperW,
            dotsPerLine: config.dotsPerLine
        )
        let cinemaLinePts = MovieTicketPrintMetrics.lineHeightPoints(
            heightScale: cinemaStyle.heightScale,
            paperWidth: paperW,
            dotsPerLine: config.dotsPerLine
        )
        let titleTop = titleEl?.frame.y ?? 16
        let titleBoxH = titleEl?.frame.height ?? titleLinePts
        let titleAdvance = titleLinePts * CGFloat(max(1, titleLines.count))
        let cinemaTop: CGFloat = {
            let ys = [hallEl?.frame.y, seatEl?.frame.y].compactMap { $0 }
            return ys.min() ?? (titleTop + titleBoxH + 8)
        }()
        let sessionTop = dateEl?.frame.y ?? (cinemaTop + cinemaLinePts + 8)
        let gapAfterTitleDots = canvasGapDots(
            fromY: titleTop,
            boxHeight: titleBoxH,
            printedAdvance: titleAdvance,
            toY: cinemaTop,
            paperWidth: paperW,
            dotsPerLine: config.dotsPerLine
        )
        let gapAfterCinemaDots = canvasGapDots(
            fromY: cinemaTop,
            boxHeight: max(hallEl?.frame.height ?? cinemaLinePts, seatEl?.frame.height ?? cinemaLinePts),
            printedAdvance: cinemaLinePts,
            toY: sessionTop,
            paperWidth: paperW,
            dotsPerLine: config.dotsPerLine
        )

        return Fields(
            title: title,
            cinemaSeat: cinemaLine,
            sessionLine: sessionLine,
            endsLine: endsLine,
            qrPayload: qrPayload,
            codeLine: codeLine,
            ticketType: ticketType.isEmpty ? " " : ticketType,
            ticketLine: ticketLine,
            qrSizeDots: qrSize,
            titleLines: titleLines,
            titleWrapCols: titleWrapCols,
            titleStyle: titleStyle,
            cinemaStyle: cinemaStyle,
            sessionStyle: sessionStyle,
            endsStyle: endsStyle,
            codeStyle: codeStyle,
            typeStyle: typeStyle,
            ticketStyle: ticketStyle,
            gapAfterTitleDots: gapAfterTitleDots,
            gapAfterCinemaDots: gapAfterCinemaDots
        )
    }

    // MARK: - Emit

    private static func emit(_ builder: ESCPOSBuilder, fields: Fields, config: PrinterConfig) {
        _ = config
        apply(builder, fields.titleStyle)
        for line in fields.titleLines {
            builder.appendRawTextLine(line).newline()
        }

        if fields.gapAfterTitleDots > 0 {
            builder.applyMagnification(width: 1, height: 1)
            builder.feedDots(fields.gapAfterTitleDots)
        }

        apply(builder, fields.cinemaStyle)
        builder.appendRawTextLine(fields.cinemaSeat).newline()

        if fields.gapAfterCinemaDots > 0 {
            builder.applyMagnification(width: 1, height: 1)
            builder.feedDots(fields.gapAfterCinemaDots)
        } else {
            builder.applyMagnification(width: 1, height: 1)
            builder.feed(lines: 1)
        }

        apply(builder, fields.sessionStyle)
        builder.appendRawTextLine(fields.sessionLine).newline()

        apply(builder, fields.endsStyle)
        builder.appendRawTextLine(fields.endsLine).newline()
        builder.applyMagnification(width: 1, height: 1)
        builder.feed(lines: 1)

        builder.align(.center)
            .qrCodeImage(fields.qrPayload, maxWidth: fields.qrSizeDots)
        builder.feed(lines: 1)

        apply(builder, fields.codeStyle)
        builder.appendRawTextLine(fields.codeLine).newline()
        builder.applyMagnification(width: 1, height: 1)
        builder.feed(lines: 1)

        apply(builder, fields.typeStyle)
        builder.appendRawTextLine(fields.ticketType).newline()

        apply(builder, fields.ticketStyle)
        builder.appendRawTextLine(fields.ticketLine).newline()
    }

    private static func apply(_ builder: ESCPOSBuilder, _ style: LineStyle) {
        builder.align(style.align)
            .bold(style.bold)
            .applyMagnification(width: style.widthScale, height: style.heightScale)
    }

    // MARK: - Preview (Font A cell metrics ≈ printer)

    private static func drawEscposLine(
        _ text: String,
        y: inout CGFloat,
        widthDots: Int,
        style: LineStyle
    ) {
        let cell = MovieTicketPrintMetrics.fontACellDots
        let wScale = CGFloat(max(1, style.widthScale))
        let hScale = CGFloat(max(1, style.heightScale))
        let fontSize = cell.height * hScale * 0.72
        let font = style.bold
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let ns = text as NSString
        let natural = ns.size(withAttributes: attrs)
        let targetWidth = CGFloat(ReceiptTextLayout.displayWidth(text)) * cell.width * wScale
        let scaleX = natural.width > 0.5 ? targetWidth / natural.width : 1
        let drawWidth = natural.width * scaleX
        let x: CGFloat = {
            switch style.align {
            case .left: return 0
            case .right: return max(0, CGFloat(widthDots) - drawWidth)
            case .center: return max(0, (CGFloat(widthDots) - drawWidth) / 2)
            }
        }()

        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: x, yBy: y)
        t.scaleX(by: scaleX, yBy: 1)
        t.concat()
        ns.draw(at: .zero, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        y += cell.height * hScale
    }

    // MARK: - Helpers

    private static func firstField(
        _ template: MovieTicketTemplate, _ kind: MovieTicketFieldKind
    ) -> MovieTicketElement? {
        template.elements.first { $0.kind == .fieldPlaceholder && $0.fieldKind == kind }
    }

    private static func style(
        from el: MovieTicketElement?,
        fallbackW: Int,
        fallbackH: Int,
        fallbackBold: Bool = false
    ) -> LineStyle {
        guard let el else {
            return LineStyle(
                widthScale: fallbackW,
                heightScale: fallbackH,
                bold: fallbackBold,
                align: .center
            )
        }
        let scale = MovieTicketRitzESCPOS.printScale(fontSize: el.fontSize, boxHeight: el.frame.height)
        return LineStyle(
            widthScale: scale.width,
            heightScale: scale.height,
            bold: el.isBold,
            align: escAlign(el.alignment)
        )
    }

    private static func maxStyle(_ a: LineStyle, _ b: LineStyle) -> LineStyle {
        LineStyle(
            widthScale: max(a.widthScale, b.widthScale),
            heightScale: max(a.heightScale, b.heightScale),
            bold: a.bold || b.bold,
            align: a.align
        )
    }

    /// Fit `text` on one Font A line. Prefer reducing width while keeping height
    /// (3×3 → 2×3) before squaring down to 2×2 / 1×1.
    private static func styleFittingOneLine(
        _ text: String,
        preferred: LineStyle,
        columnsPerLine: Int
    ) -> LineStyle {
        var style = preferred
        let cols = max(1, columnsPerLine)
        func fits(_ s: LineStyle) -> Bool {
            let lineCols = max(1, cols / max(1, s.widthScale))
            return ReceiptTextLayout.displayWidth(text) <= lineCols
        }
        if fits(style) { return style }

        // Step 1: drop width by 1, keep height (e.g. 3×3 → 2×3).
        if style.widthScale > 1 {
            var stepped = style
            stepped.widthScale -= 1
            if stepped.heightScale < stepped.widthScale {
                stepped.heightScale = stepped.widthScale
            }
            if fits(stepped) { return stepped }
            style = stepped
        }

        // Step 2: square down until it fits.
        while style.widthScale > 1 {
            if fits(style) { break }
            style.widthScale -= 1
            style.heightScale = min(style.heightScale, style.widthScale)
            style.heightScale = max(1, style.heightScale)
        }
        return style
    }

    /// IMAX-style gap: cursor = fromY + min(boxH, printedAdvance); dots from (toY - cursor).
    private static func canvasGapDots(
        fromY: CGFloat,
        boxHeight: CGFloat,
        printedAdvance: CGFloat,
        toY: CGFloat,
        paperWidth: CGFloat,
        dotsPerLine: Int
    ) -> UInt8 {
        let cursor = fromY + min(max(0, boxHeight), max(0, printedAdvance))
        let gapPts = toY - cursor
        guard gapPts > 0.5 else { return 0 }
        let ppd = MovieTicketPrintMetrics.pointsPerDot(
            paperWidth: paperWidth, dotsPerLine: dotsPerLine
        )
        let dots = Int((gapPts / max(ppd, 0.01)).rounded())
        return UInt8(max(0, min(255, dots)))
    }

    private static func escAlign(_ alignment: Int) -> ESCPOSAlign {
        switch alignment {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }

    /// Word-aware wrap so titles break on spaces (Ann / Lee) instead of mid-word.
    private static func wrapWords(_ text: String, maxColumns: Int) -> [String] {
        guard maxColumns > 0 else { return [text] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty {
                lines.append("")
                continue
            }
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if ReceiptTextLayout.displayWidth(candidate) <= maxColumns {
                    current = candidate
                } else {
                    if !current.isEmpty { lines.append(current) }
                    if ReceiptTextLayout.displayWidth(word) <= maxColumns {
                        current = word
                    } else {
                        for chunk in ReceiptTextLayout.wrap(word, maxColumns: maxColumns) {
                            lines.append(chunk)
                        }
                        current = ""
                    }
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        return lines.isEmpty ? [""] : lines
    }

    private static func lowerAmPm(_ text: String) -> String {
        text
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }

    private static func formatLowerAmPm(_ date: Date, pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return lowerAmPm(f.string(from: date))
    }
}
