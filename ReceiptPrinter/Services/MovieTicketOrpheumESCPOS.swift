import AppKit
import Foundation

/// Native ESC/POS dual-stub ticket matching the classic Hayden Orpheum layout
/// (`OrpheumTicketRenderer` / 「电影票 (Orpheum)」).
///
/// Typography follows template element `fontSize` / box height via
/// `MovieTicketRitzESCPOS.printScale` (same 1×/2×/3× controls as the template editor).
enum MovieTicketOrpheumESCPOS {
    private struct LineStyle {
        var widthScale: Int = 1
        var heightScale: Int = 1
        var bold: Bool = false
        var characterSpacing: Int = 0
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
        renderStub(builder, fields: fields, includeBarcode: false)
        builder.align(.center).applyMagnification(width: 1, height: 1).text("--------------------------").newline()
        renderStub(builder, fields: fields, includeBarcode: true)
        builder.resetStyle()
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

        var measureY: CGFloat = 12
        measureY += cell.height * CGFloat(max(
            fields.venueStyle.heightScale,
            fields.cinemaStyle.heightScale,
            fields.hallStyle.heightScale
        ))
        measureY += cell.height * CGFloat(fields.titleStyle.heightScale) + 4
        measureY += cell.height * CGFloat(fields.whenStyle.heightScale) + 4
        measureY += cell.height * CGFloat(max(fields.admitStyle.heightScale, fields.typeStyle.heightScale))
        measureY += includeBarcodeEstimate(fields: fields, widthDots: widthDots)
        measureY += 20 // dash
        measureY += cell.height * CGFloat(max(
            fields.venueStyle.heightScale,
            fields.cinemaStyle.heightScale,
            fields.hallStyle.heightScale
        ))
        measureY += cell.height * CGFloat(fields.titleStyle.heightScale) + 4
        measureY += cell.height * CGFloat(fields.whenStyle.heightScale) + 4
        measureY += cell.height * CGFloat(max(fields.admitStyle.heightScale, fields.typeStyle.heightScale))
        measureY += includeBarcodeEstimate(fields: fields, widthDots: widthDots, withBarcode: true)
        let height = max(1 as CGFloat, ceil(measureY))

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            var y: CGFloat = 12
            drawStubPreview(fields: fields, includeBarcode: false, widthDots: widthDots, y: &y)
            drawCentered(
                "--------------------------",
                y: &y,
                widthDots: widthDots,
                size: 11,
                bold: false,
                lineHeight: cell.height
            )
            y += 6
            drawStubPreview(fields: fields, includeBarcode: true, widthDots: widthDots, y: &y)
            return true
        }
    }

    private static func includeBarcodeEstimate(
        fields: Fields,
        widthDots: Int,
        withBarcode: Bool = false
    ) -> CGFloat {
        _ = widthDots
        if withBarcode {
            return CGFloat(fields.barcodeHeight) + 4
                + MovieTicketPrintMetrics.fontACellDots.height * CGFloat(fields.serialStyle.heightScale)
        }
        return MovieTicketPrintMetrics.fontACellDots.height * CGFloat(fields.serialStyle.heightScale)
    }

    // MARK: - Resolve

    private struct Fields {
        var venue: String
        var hallNumber: String
        /// Reverse-print payload including pad spaces; width tracks hall placeholder 「宽」.
        var hallHighlightText: String
        var movie: String
        var when: String
        var ticketType: String
        var price: String
        var ticketCode: String
        var barcode: String
        var barcodeLabel: String
        var admit: String
        var titleForceSingleLine: Bool
        var barcodeHeight: UInt8
        var venueStyle: LineStyle
        var cinemaStyle: LineStyle
        var hallStyle: LineStyle
        var titleStyle: LineStyle
        var whenStyle: LineStyle
        var admitStyle: LineStyle
        var typeStyle: LineStyle
        var serialStyle: LineStyle
    }

    private static func resolvedFields(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig
    ) -> Fields {
        let venueEl = template.elements.first {
            $0.kind == .textBox && $0.content.localizedCaseInsensitiveContains("orpheum")
        }
        let cinemaEl = template.elements.first {
            $0.kind == .textBox
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Cinema") == .orderedSame
        }
        let hallEl = template.elements.first { $0.fieldKind == .hall }
        let titleEl = template.elements.first {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .movieTitle
        }
        let whenEl = template.elements.first { $0.fieldKind == .timeRange }
        let seatEl = template.elements.first { $0.fieldKind == .seatArea }
        let typeEl = template.elements.first { $0.fieldKind == .ticketType }
        let priceEl = template.elements.first { $0.fieldKind == .ticketPrice }
        let serialEl = template.elements.first { $0.fieldKind == .serialNumber }
        let barcodeEl = template.elements.first { $0.fieldKind == .barcode }

        let venue = venueEl?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Orpheum"
        let hallRaw = draft.hall.trimmingCharacters(in: .whitespacesAndNewlines)
        let hallNumber = MovieTicketElement.extractHallNumber(from: hallRaw)
        let n = hallNumber.isEmpty ? hallRaw : hallNumber

        let startFmt = DateFormatter()
        startFmt.locale = Locale(identifier: "en_US_POSIX")
        startFmt.dateFormat = "EEE MMM d, yyyy hh:mm a"
        let endFmt = DateFormatter()
        endFmt.locale = Locale(identifier: "en_US_POSIX")
        endFmt.dateFormat = "h:mm a"
        let when = "\(startFmt.string(from: draft.combinedStart)) Until \(endFmt.string(from: draft.showEndTime))"

        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = serial.filter(\.isNumber)
        let barcode: String = {
            if let barcodeEl, (barcodeEl.codeContentSource ?? .serialNumber) == .custom {
                let raw = barcodeEl.resolvedCodePayload(from: draft)
                let customDigits = raw.filter { $0.isNumber || $0.isLetter }
                return customDigits.isEmpty ? (raw.isEmpty ? "00000000000" : raw) : String(customDigits)
            }
            if digits.count >= 11 { return String(digits.suffix(11)) }
            if digits.isEmpty { return "00000000000" }
            return digits
        }()
        let labelCore: String = {
            if let barcodeEl, (barcodeEl.codeContentSource ?? .serialNumber) == .custom {
                let raw = barcodeEl.resolvedCodePayload(from: draft)
                return raw.isEmpty ? barcode : raw
            }
            if digits.count >= 11 {
                let base = String(digits.dropLast(3).suffix(8))
                let ser = String(digits.suffix(3))
                return "\(base)/\(ser)"
            }
            return serial.isEmpty ? barcode : serial
        }()
        let spaced = labelCore.map { String($0) }.joined(separator: " ")
        let barcodeLabel = "* \(spaced) *"
        let ticketCode = serial.isEmpty ? "DEBI \(barcode)" : serial

        let price: String = {
            let t = draft.ticketPrice.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("$") { return t }
            if let v = Double(t.filter { $0.isNumber || $0 == "." }) {
                return String(format: "$%.2f", v)
            }
            return t.isEmpty ? "" : "$\(t)"
        }()

        let admit: String = {
            if draft.seatModeUnallocated {
                return template.unallocatedSeatLabel.isEmpty ? "ADMIT" : template.unallocatedSeatLabel
            }
            let seat = draft.seatArea.trimmingCharacters(in: .whitespacesAndNewlines)
            return seat.isEmpty ? "ADMIT" : seat
        }()

        let venueStyle = style(from: venueEl, fallbackW: 2, fallbackH: 2, fallbackBold: true)
        // Cinema label and hall number keep independent print scales.
        let cinemaStyle = style(from: cinemaEl, fallbackW: 1, fallbackH: 1, fallbackBold: false)
        let hallStyle = style(from: hallEl, fallbackW: 2, fallbackH: 2, fallbackBold: true)
        let hallHighlightText = MovieTicketPrintMetrics.invertedHallHighlightText(
            number: n,
            frameWidth: hallEl?.frame.width,
            widthScale: hallStyle.widthScale,
            paperWidth: template.paperSize.width,
            dotsPerLine: config.dotsPerLine,
            columnsPerLine: config.columnsPerLine
        )
        let titleStyle = style(from: titleEl, fallbackW: 2, fallbackH: 2, fallbackBold: true)
        let whenStyle = style(from: whenEl, fallbackW: 1, fallbackH: 1, fallbackBold: false)
        let admitStyle = style(from: seatEl, fallbackW: 1, fallbackH: 1, fallbackBold: false)
        let typeStyle = maxStyle(
            style(from: typeEl, fallbackW: 1, fallbackH: 1, fallbackBold: false),
            style(from: priceEl, fallbackW: 1, fallbackH: 1, fallbackBold: false)
        )
        let serialStyle = style(from: serialEl, fallbackW: 1, fallbackH: 1, fallbackBold: false)

        let rawTitle = draft.printedMovieTitle
        let movie: String = {
            guard let titleEl else { return rawTitle }
            let lines = MovieTicketPrintMetrics.fitTextToElementBox(
                rawTitle.isEmpty ? " " : rawTitle,
                frame: titleEl.frame,
                paperWidth: template.paperSize.width,
                config: config,
                widthScale: titleStyle.widthScale,
                heightScale: titleStyle.heightScale,
                singleLineClip: titleEl.singleLineClip == true
            )
            return lines.joined(separator: "\n")
        }()
        let forceSingle = titleEl?.singleLineClip == true

        let barcodeHeight: UInt8 = {
            let h = barcodeEl?.frame.height ?? 72
            let dots = Int((h * (110.0 / 72.0)).rounded())
            return UInt8(max(24, min(255, dots)))
        }()

        return Fields(
            venue: venue.isEmpty ? "Orpheum" : venue,
            hallNumber: n,
            hallHighlightText: hallHighlightText,
            movie: movie,
            when: when,
            ticketType: draft.ticketType.trimmingCharacters(in: .whitespacesAndNewlines),
            price: price,
            ticketCode: ticketCode,
            barcode: barcode,
            barcodeLabel: barcodeLabel,
            admit: admit,
            titleForceSingleLine: forceSingle,
            barcodeHeight: barcodeHeight,
            venueStyle: venueStyle,
            cinemaStyle: cinemaStyle,
            hallStyle: hallStyle,
            titleStyle: titleStyle,
            whenStyle: whenStyle,
            admitStyle: admitStyle,
            typeStyle: typeStyle,
            serialStyle: serialStyle
        )
    }

    private static func style(
        from el: MovieTicketElement?,
        fallbackW: Int,
        fallbackH: Int,
        fallbackBold: Bool
    ) -> LineStyle {
        guard let el else {
            return LineStyle(widthScale: fallbackW, heightScale: fallbackH, bold: fallbackBold)
        }
        let scale = MovieTicketRitzESCPOS.printScale(for: el)
        return LineStyle(
            widthScale: scale.width,
            heightScale: scale.height,
            bold: el.isBold,
            characterSpacing: MovieTicketPrintMetrics.clampedCharacterSpacing(el.characterSpacing)
        )
    }

    private static func maxStyle(_ a: LineStyle, _ b: LineStyle) -> LineStyle {
        LineStyle(
            widthScale: max(a.widthScale, b.widthScale),
            heightScale: max(a.heightScale, b.heightScale),
            bold: a.bold || b.bold,
            characterSpacing: max(a.characterSpacing, b.characterSpacing)
        )
    }

    private static func apply(_ builder: ESCPOSBuilder, _ style: LineStyle) {
        builder.bold(style.bold)
            .characterSpacing(UInt8(MovieTicketPrintMetrics.clampedCharacterSpacing(style.characterSpacing)))
            .applyMagnification(width: style.widthScale, height: style.heightScale)
    }

    /// Columns the movie title may occupy on one line (Font A × width scale).
    private static func titleClipColumns(
        element: MovieTicketElement?,
        config: PrinterConfig,
        widthScale: Int,
        paperWidth: CGFloat
    ) -> Int? {
        guard let element, element.singleLineClip == true else { return nil }
        let scale = CGFloat(max(1, widthScale))
        let paperW = max(1, paperWidth)
        let charDots = CGFloat(config.dotsPerLine) / CGFloat(max(1, config.columnsPerLine)) * scale
        let boxDots = element.frame.width * CGFloat(config.dotsPerLine) / paperW
        let cols = Int((boxDots / max(1, charDots)).rounded(.down))
        return max(1, min(cols, config.columnsPerLine / Int(scale)))
    }

    // MARK: - ESC/POS

    private static func renderStub(_ builder: ESCPOSBuilder, fields: Fields, includeBarcode: Bool) {
        builder.align(.left)
            .tableRowWithHighlight(
                left: fields.venue,
                rightPrefix: "Cinema ",
                highlight: fields.hallHighlightText,
                leftBold: fields.venueStyle.bold,
                leftWidth: fields.venueStyle.widthScale,
                leftHeight: fields.venueStyle.heightScale,
                rightBold: fields.cinemaStyle.bold,
                rightWidth: fields.cinemaStyle.widthScale,
                rightHeight: fields.cinemaStyle.heightScale,
                highlightBold: fields.hallStyle.bold,
                highlightWidth: fields.hallStyle.widthScale,
                highlightHeight: fields.hallStyle.heightScale,
                preferSingleLine: true,
                padHighlight: false
            )

        let title = fields.movie.isEmpty ? " " : fields.movie
        builder.align(.center)
        apply(builder, fields.titleStyle)
        if fields.titleForceSingleLine {
            builder.appendRawTextLine(title).newline()
        } else {
            // Box-constrained wrap: lines are pre-fitted in resolve (joined with \n).
            for line in title.components(separatedBy: "\n") {
                builder.appendRawTextLine(line).newline()
            }
        }
        builder.bold(false)
            .characterSpacing(0)
            .applyMagnification(width: 1, height: 1)

        builder.align(.left)
        apply(builder, fields.whenStyle)
        builder.text(fields.when)
            .newline()
            .bold(false)
            .characterSpacing(0)
            .applyMagnification(width: 1, height: 1)

        let right = [fields.ticketType, fields.price].filter { !$0.isEmpty }.joined(separator: " ")
        builder.tableRowWithHighlight(
            left: fields.admit,
            rightPrefix: right,
            highlight: "",
            leftBold: fields.admitStyle.bold,
            leftWidth: fields.admitStyle.widthScale,
            leftHeight: fields.admitStyle.heightScale,
            rightBold: fields.typeStyle.bold,
            rightWidth: fields.typeStyle.widthScale,
            rightHeight: fields.typeStyle.heightScale
        )

        if includeBarcode {
            let code = fields.barcode.isEmpty ? "000000" : fields.barcode
            builder.barcode(
                type: .code128,
                content: code,
                height: fields.barcodeHeight,
                width: 2,
                printHRI: false
            )
            builder.align(.center)
            apply(builder, fields.serialStyle)
            builder.text(fields.barcodeLabel)
                .newline()
                .bold(false)
                .characterSpacing(0)
                .applyMagnification(width: 1, height: 1)
        } else {
            builder.align(.center)
            apply(builder, fields.serialStyle)
            builder.text(fields.ticketCode)
                .newline()
                .bold(false)
                .characterSpacing(0)
                .applyMagnification(width: 1, height: 1)
        }
    }

    // MARK: - Preview

    /// Measure/draw Font A text with independent GS ! width & height (like Ritz preview).
    @discardableResult
    private static func drawScaledText(
        _ text: String,
        at origin: NSPoint,
        widthScale: Int,
        heightScale: Int,
        bold: Bool,
        color: NSColor = .black,
        characterSpacing: Int = 0,
        draw: Bool = true
    ) -> CGSize {
        let wScale = max(1, widthScale)
        let hScale = max(1, heightScale)
        let fontSize: CGFloat = 11
        let font = NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        let inkW = MovieTicketPrintMetrics.inkWidthDots(
            text: text,
            widthScale: wScale,
            characterSpacing: characterSpacing
        )
        // Preview font is ~11pt ≈ Font A cell; scale height via context.
        let naturalH = (text as NSString).size(withAttributes: [.font: font]).height
        let ink = CGSize(width: inkW, height: naturalH * CGFloat(hScale))
        guard draw else { return ink }
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: CGFloat(wScale), y: CGFloat(hScale))
            MovieTicketPrintMetrics.drawSpacedFontAText(
                text,
                at: .zero,
                font: font,
                color: color,
                widthScale: wScale,
                characterSpacing: characterSpacing,
                contextAlreadyScaled: true
            )
            ctx.restoreGState()
        } else {
            MovieTicketPrintMetrics.drawSpacedFontAText(
                text,
                at: origin,
                font: font,
                color: color,
                widthScale: wScale,
                characterSpacing: characterSpacing,
                contextAlreadyScaled: false
            )
        }
        return ink
    }

    private static func drawStubPreview(
        fields: Fields,
        includeBarcode: Bool,
        widthDots: Int,
        y: inout CGFloat
    ) {
        drawHeaderRow(fields: fields, widthDots: widthDots, y: &y)

        let titleText = fields.movie.isEmpty ? " " : fields.movie
        let titleAdvance = MovieTicketPrintMetrics.fontACellDots.height
            * CGFloat(fields.titleStyle.heightScale)
        let titleInk = drawScaledText(
            titleText,
            at: .zero,
            widthScale: fields.titleStyle.widthScale,
            heightScale: fields.titleStyle.heightScale,
            bold: fields.titleStyle.bold,
            characterSpacing: fields.titleStyle.characterSpacing,
            draw: false
        )
        _ = drawScaledText(
            titleText,
            at: NSPoint(x: max(0, (CGFloat(widthDots) - titleInk.width) / 2), y: y),
            widthScale: fields.titleStyle.widthScale,
            heightScale: fields.titleStyle.heightScale,
            bold: fields.titleStyle.bold,
            characterSpacing: fields.titleStyle.characterSpacing
        )
        y += max(titleAdvance, titleInk.height) + 4

        let whenAdvance = MovieTicketPrintMetrics.fontACellDots.height
            * CGFloat(fields.whenStyle.heightScale)
        let whenInk = drawScaledText(
            fields.when,
            at: NSPoint(x: 8, y: y),
            widthScale: fields.whenStyle.widthScale,
            heightScale: fields.whenStyle.heightScale,
            bold: fields.whenStyle.bold,
            characterSpacing: fields.whenStyle.characterSpacing
        )
        y += max(whenAdvance, whenInk.height) + 4

        let right = [fields.ticketType, fields.price].filter { !$0.isEmpty }.joined(separator: " ")
        let rowH = MovieTicketPrintMetrics.fontACellDots.height
            * CGFloat(max(fields.admitStyle.heightScale, fields.typeStyle.heightScale))
        _ = drawScaledText(
            fields.admit,
            at: NSPoint(x: 8, y: y),
            widthScale: fields.admitStyle.widthScale,
            heightScale: fields.admitStyle.heightScale,
            bold: fields.admitStyle.bold,
            characterSpacing: fields.admitStyle.characterSpacing
        )
        let rightInk = drawScaledText(
            right,
            at: .zero,
            widthScale: fields.typeStyle.widthScale,
            heightScale: fields.typeStyle.heightScale,
            bold: fields.typeStyle.bold,
            characterSpacing: fields.typeStyle.characterSpacing,
            draw: false
        )
        _ = drawScaledText(
            right,
            at: NSPoint(x: CGFloat(widthDots) - rightInk.width - 8, y: y),
            widthScale: fields.typeStyle.widthScale,
            heightScale: fields.typeStyle.heightScale,
            bold: fields.typeStyle.bold,
            characterSpacing: fields.typeStyle.characterSpacing
        )
        y += rowH + 6

        if includeBarcode {
            let barH = CGFloat(fields.barcodeHeight)
            let barW = CGFloat(widthDots) * 0.88
            let barX = (CGFloat(widthDots) - barW) / 2
            if let img = MovieTicketPrintComposer.makeCode128Barcode(
                content: fields.barcode, size: CGSize(width: barW, height: barH)
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
            y += barH + 4
            let serialAdvance = MovieTicketPrintMetrics.fontACellDots.height
                * CGFloat(fields.serialStyle.heightScale)
            let serialInk = drawScaledText(
                fields.barcodeLabel,
                at: .zero,
                widthScale: fields.serialStyle.widthScale,
                heightScale: fields.serialStyle.heightScale,
                bold: fields.serialStyle.bold,
                characterSpacing: fields.serialStyle.characterSpacing,
                draw: false
            )
            _ = drawScaledText(
                fields.barcodeLabel,
                at: NSPoint(x: max(0, (CGFloat(widthDots) - serialInk.width) / 2), y: y),
                widthScale: fields.serialStyle.widthScale,
                heightScale: fields.serialStyle.heightScale,
                bold: fields.serialStyle.bold,
                characterSpacing: fields.serialStyle.characterSpacing
            )
            y += max(serialAdvance, serialInk.height)
        } else {
            let serialAdvance = MovieTicketPrintMetrics.fontACellDots.height
                * CGFloat(fields.serialStyle.heightScale)
            let serialInk = drawScaledText(
                fields.ticketCode,
                at: .zero,
                widthScale: fields.serialStyle.widthScale,
                heightScale: fields.serialStyle.heightScale,
                bold: fields.serialStyle.bold,
                characterSpacing: fields.serialStyle.characterSpacing,
                draw: false
            )
            _ = drawScaledText(
                fields.ticketCode,
                at: NSPoint(x: max(0, (CGFloat(widthDots) - serialInk.width) / 2), y: y),
                widthScale: fields.serialStyle.widthScale,
                heightScale: fields.serialStyle.heightScale,
                bold: fields.serialStyle.bold,
                characterSpacing: fields.serialStyle.characterSpacing
            )
            y += max(serialAdvance, serialInk.height)
        }
    }

    private static func drawHeaderRow(fields: Fields, widthDots: Int, y: inout CGFloat) {
        let rowH = MovieTicketPrintMetrics.fontACellDots.height
            * CGFloat(max(
                fields.venueStyle.heightScale,
                fields.cinemaStyle.heightScale,
                fields.hallStyle.heightScale
            ))

        _ = drawScaledText(
            fields.venue,
            at: NSPoint(x: 8, y: y),
            widthScale: fields.venueStyle.widthScale,
            heightScale: fields.venueStyle.heightScale,
            bold: fields.venueStyle.bold
        )

        let cinema = "Cinema "
        let hall = fields.hallHighlightText
        let cinemaInk = drawScaledText(
            cinema,
            at: .zero,
            widthScale: fields.cinemaStyle.widthScale,
            heightScale: fields.cinemaStyle.heightScale,
            bold: fields.cinemaStyle.bold,
            draw: false
        )
        let hallInk = drawScaledText(
            hall,
            at: .zero,
            widthScale: fields.hallStyle.widthScale,
            heightScale: fields.hallStyle.heightScale,
            bold: fields.hallStyle.bold,
            draw: false
        )
        let rightX = CGFloat(widthDots) - cinemaInk.width - hallInk.width - 8
        let cinemaY = y + max(0, (rowH - cinemaInk.height) / 2)
        let hallY = y + max(0, (rowH - hallInk.height) / 2)

        _ = drawScaledText(
            cinema,
            at: NSPoint(x: rightX, y: cinemaY),
            widthScale: fields.cinemaStyle.widthScale,
            heightScale: fields.cinemaStyle.heightScale,
            bold: fields.cinemaStyle.bold
        )

        let hallOrigin = NSPoint(x: rightX + cinemaInk.width, y: hallY)
        NSColor.black.setFill()
        NSRect(
            x: hallOrigin.x,
            y: hallOrigin.y,
            width: hallInk.width,
            height: max(hallInk.height, 2) + 2
        ).fill()
        _ = drawScaledText(
            hall,
            at: hallOrigin,
            widthScale: fields.hallStyle.widthScale,
            heightScale: fields.hallStyle.heightScale,
            bold: fields.hallStyle.bold,
            color: .white
        )
        y += rowH + 4
    }

    private static func drawCentered(
        _ text: String,
        y: inout CGFloat,
        widthDots: Int,
        size: CGFloat,
        bold: Bool,
        lineHeight: CGFloat
    ) {
        let font = NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let w = (text as NSString).size(withAttributes: attrs).width
        let x = max(0, (CGFloat(widthDots) - w) / 2)
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        y += max(lineHeight, size + 4)
    }
}
