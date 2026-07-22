import AppKit
import Foundation

/// Native ESC/POS dual-stub ticket matching the classic Hayden Orpheum layout
/// (`OrpheumTicketRenderer` / 「电影票 (Orpheum)」).
enum MovieTicketOrpheumESCPOS {
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
        renderStub(builder, fields: fields, includeBarcode: false)
        builder.align(.center).text("--------------------------").newline()
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
        let rowH: CGFloat = 28
        let height: CGFloat = 520

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            var y: CGFloat = 12
            drawStubPreview(fields: fields, includeBarcode: false, widthDots: widthDots, y: &y, rowH: rowH)
            drawCentered("--------------------------", y: &y, widthDots: widthDots, size: 12, bold: false)
            y += 6
            drawStubPreview(fields: fields, includeBarcode: true, widthDots: widthDots, y: &y, rowH: rowH)
            return true
        }
    }

    // MARK: - Resolve

    private struct Fields {
        var venue: String
        var hallNumber: String
        var movie: String
        var when: String
        var ticketType: String
        var price: String
        var ticketCode: String
        var barcode: String
        var barcodeLabel: String
        var admit: String
        /// When true, emit title via `appendRawTextLine` (already clipped to one line).
        var titleForceSingleLine: Bool
    }

    private static func resolvedFields(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        config: PrinterConfig
    ) -> Fields {
        let venue = template.elements
            .first(where: { $0.kind == .textBox && $0.content.localizedCaseInsensitiveContains("orpheum") })?
            .content.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Orpheum"
        let hallEl = template.elements.first { $0.fieldKind == .hall }
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
            if digits.count >= 11 { return String(digits.suffix(11)) }
            if digits.isEmpty { return "00000000000" }
            return digits
        }()
        let labelCore: String = {
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

        let titleEl = template.elements.first {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .movieTitle
        }
        // Orpheum title prints at `.double` (width×2 height×2).
        let titleWidthScale = 2
        let rawTitle = draft.printedMovieTitle
        let clipCols = titleClipColumns(
            element: titleEl,
            config: config,
            widthScale: titleWidthScale,
            paperWidth: template.paperSize.width
        )
        let forceSingle = titleEl?.singleLineClip != false && clipCols != nil
        let movie: String = {
            guard forceSingle, let clipCols else { return rawTitle }
            return ReceiptTextLayout.clip(rawTitle, maxColumns: clipCols)
        }()

        _ = hallEl
        return Fields(
            venue: venue.isEmpty ? "Orpheum" : venue,
            hallNumber: n,
            movie: movie,
            when: when,
            ticketType: draft.ticketType.trimmingCharacters(in: .whitespacesAndNewlines),
            price: price,
            ticketCode: ticketCode,
            barcode: barcode,
            barcodeLabel: barcodeLabel,
            admit: admit,
            titleForceSingleLine: forceSingle
        )
    }

    /// Columns the movie title may occupy on one line (Font A × width scale).
    private static func titleClipColumns(
        element: MovieTicketElement?,
        config: PrinterConfig,
        widthScale: Int,
        paperWidth: CGFloat
    ) -> Int? {
        guard let element, element.singleLineClip != false else { return nil }
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
                highlight: fields.hallNumber,
                leftBold: true,
                leftSize: .double
            )

        let title = fields.movie.isEmpty ? " " : fields.movie
        builder.align(.center)
            .bold(true)
            .applyTextSize(.double)
        if fields.titleForceSingleLine {
            builder.appendRawTextLine(title).newline()
        } else {
            builder.text(title).newline()
        }
        builder.bold(false)
            .applyTextSize(.normal)

        builder.align(.left)
            .text(fields.when)
            .newline()

        let right = [fields.ticketType, fields.price].filter { !$0.isEmpty }.joined(separator: " ")
        builder.tableRowWithHighlight(
            left: fields.admit,
            rightPrefix: right,
            highlight: "",
            leftBold: false,
            leftSize: .normal
        )

        if includeBarcode {
            let code = fields.barcode.isEmpty ? "000000" : fields.barcode
            builder.barcode(type: .code128, content: code, height: 80, width: 2, printHRI: false)
            builder.align(.center).text(fields.barcodeLabel).newline()
        } else {
            builder.align(.center).text(fields.ticketCode).newline()
        }
    }

    // MARK: - Preview

    private static func drawStubPreview(
        fields: Fields,
        includeBarcode: Bool,
        widthDots: Int,
        y: inout CGFloat,
        rowH: CGFloat
    ) {
        drawHeaderRow(fields: fields, widthDots: widthDots, y: &y)
        drawCentered(fields.movie.isEmpty ? " " : fields.movie, y: &y, widthDots: widthDots, size: 22, bold: true)
        y += 4
        drawLeft(fields.when, y: &y, widthDots: widthDots, size: 13, bold: false)
        let right = [fields.ticketType, fields.price].filter { !$0.isEmpty }.joined(separator: " ")
        drawSplitRow(left: fields.admit, right: right, widthDots: widthDots, y: &y)
        if includeBarcode {
            let barH: CGFloat = 70
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
            drawCentered(fields.barcodeLabel, y: &y, widthDots: widthDots, size: 11, bold: false)
        } else {
            drawCentered(fields.ticketCode, y: &y, widthDots: widthDots, size: 12, bold: false)
        }
        y += rowH * 0.3
    }

    private static func drawHeaderRow(fields: Fields, widthDots: Int, y: inout CGFloat) {
        let font = NSFont(name: "Menlo-Bold", size: 22) ?? .monospacedSystemFont(ofSize: 22, weight: .bold)
        let small = NSFont(name: "Menlo-Regular", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
        let venue = fields.venue as NSString
        venue.draw(at: NSPoint(x: 8, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])

        let cinema = "Cinema " as NSString
        let hall = "  \(fields.hallNumber)  " as NSString
        let cinemaW = cinema.size(withAttributes: [.font: small]).width
        let hallW = hall.size(withAttributes: [.font: small]).width
        let rightX = CGFloat(widthDots) - cinemaW - hallW - 8
        cinema.draw(at: NSPoint(x: rightX, y: y + 6), withAttributes: [
            .font: small, .foregroundColor: NSColor.black
        ])
        let hallOrigin = NSPoint(x: rightX + cinemaW, y: y + 4)
        let hallSize = hall.size(withAttributes: [.font: small])
        NSColor.black.setFill()
        NSRect(x: hallOrigin.x, y: hallOrigin.y, width: hallSize.width, height: hallSize.height + 2).fill()
        hall.draw(at: hallOrigin, withAttributes: [.font: small, .foregroundColor: NSColor.white])
        y += 32
    }

    private static func drawCentered(
        _ text: String,
        y: inout CGFloat,
        widthDots: Int,
        size: CGFloat,
        bold: Bool
    ) {
        let font = NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let w = (text as NSString).size(withAttributes: attrs).width
        let x = max(0, (CGFloat(widthDots) - w) / 2)
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        y += size + 8
    }

    private static func drawLeft(
        _ text: String,
        y: inout CGFloat,
        widthDots: Int,
        size: CGFloat,
        bold: Bool
    ) {
        _ = widthDots
        let font = NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        (text as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: [
            .font: font, .foregroundColor: NSColor.black
        ])
        y += size + 8
    }

    private static func drawSplitRow(left: String, right: String, widthDots: Int, y: inout CGFloat) {
        let font = NSFont(name: "Menlo-Regular", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        (left as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: attrs)
        let rw = (right as NSString).size(withAttributes: attrs).width
        (right as NSString).draw(at: NSPoint(x: CGFloat(widthDots) - rw - 8, y: y), withAttributes: attrs)
        y += 22
    }
}
