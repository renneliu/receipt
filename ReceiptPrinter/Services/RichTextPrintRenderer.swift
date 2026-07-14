import AppKit
import Foundation

/// Quick-print renderer.
///
/// Preview: attributed text → `layoutLines` → `renderImage` (on-screen bitmap).
/// Print:   same `layoutLines` → native ESC/POS text (GBK + FS & / FS .) — NOT whole-page GS v 0.
///
/// Runtime evidence on this POS-80: identical GS v 0 payloads were delivered byte-exact over USB
/// yet physically garbled; earlier GBK text mode printed readable Chinese. So body text uses
/// the printer's built-in fonts again. Preview remains a bitmap for WYSIWYG convenience only.
///
/// Default style: `AttributedTextView.defaultFontSize` (= 2×) → `TextSize.double`.
enum RichTextPrintRenderer {
    private static let minimumFeedsBeforeCut = 12

    enum DividerKind {
        case solid
        case dashed
    }

    enum LayoutLine {
        case text(string: String, size: TextSize, bold: Bool, underline: Bool, align: ESCPOSAlign)
        case divider(DividerKind)
        case blank
    }

    // MARK: - Public

    static func renderImage(attributedString: NSAttributedString, config: PrinterConfig, padding: CGFloat = 8) -> NSImage {
        let lines = layoutLines(from: attributedString, config: config)
        let width = CGFloat(config.dotsPerLine)
        let contentWidth = width - padding * 2
        let baseCell = contentWidth / CGFloat(max(config.columnsPerLine, 1))
        var heights: [CGFloat] = []
        for line in lines {
            heights.append(lineHeight(for: line, baseCell: baseCell))
        }
        let totalH = heights.reduce(padding * 2, +) + CGFloat(max(0, heights.count - 1)) * 2
        let pixelHeight = max(80, ceil(totalH))
        let size = NSSize(width: width, height: pixelHeight)

        return NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            var drawY = padding
            for (index, line) in lines.enumerated() {
                let h = heights[index]
                drawLine(
                    line,
                    at: drawY,
                    height: h,
                    contentWidth: contentWidth,
                    baseCell: baseCell,
                    paddingX: padding,
                    columns: config.columnsPerLine,
                    asciiAsDoubleWidth: false
                )
                drawY += h + 2
            }
            return true
        }
    }

    /// Native-text ESC/POS from the shared layout line list (the path that prints Chinese on this POS-80).
    static func renderESCPOS(attributedString: NSAttributedString, config: PrinterConfig) -> Data {
        let lines = layoutLines(from: attributedString, config: config)
        let builder = ESCPOSBuilder(config: config).initialize()
        for line in lines {
            emit(line, into: builder, config: config)
        }
        let feedBeforeCut = max(config.feedLinesBeforeCut, minimumFeedsBeforeCut)
        if config.cutPaper {
            builder.cut(feedLines: feedBeforeCut)
        }
        return builder.build()
    }

    /// Diagnostic capture: preview PNG for reference + the EXACT native-text payload that will be sent.
    static func buildArtifacts(
        attributedString: NSAttributedString,
        config: PrinterConfig,
        sourceText: String,
        attributedRTFD: Data?
    ) -> PrintArtifacts {
        let image = renderImage(attributedString: attributedString, config: config)
        let pngData = Self.pngData(from: image) ?? Data()
        let payload = renderESCPOS(attributedString: attributedString, config: config)

        return PrintArtifacts(
            sourceText: sourceText,
            attributedRTFD: attributedRTFD,
            pngData: pngData,
            rasterData: Data(),
            payload: payload,
            imagePixelWidth: Int(image.size.width),
            imagePixelHeight: Int(image.size.height),
            rasterWidthBytes: 0,
            rasterHeight: 0,
            headerXL: 0,
            headerXH: 0,
            headerYL: 0,
            headerYH: 0,
            expectedRasterBytes: 0,
            renderMode: .nativeText,
            usedNativeText: true,
            usedRaster: false,
            dpi: 203,
            printableWidthDots: config.dotsPerLine,
            printerModelHint: "POS-80 text/GBK"
        )
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func emit(_ line: LayoutLine, into builder: ESCPOSBuilder, config: PrinterConfig) {
        switch line {
        case .blank:
            builder.newline()
        case .divider(let kind):
            let cols = max(8, config.columnsPerLine)
            builder.resetStyle().align(.left)
            switch kind {
            case .solid:
                builder.appendRawTextLine(String(repeating: "-", count: cols)).newline()
            case .dashed:
                var s = ""
                for i in 0..<cols { s.append(i % 2 == 0 ? "-" : " ") }
                builder.appendRawTextLine(s).newline()
            }
        case .text(let string, let size, let bold, let underline, let align):
            builder.align(align)
                .bold(bold)
                .underline(underline)
                .applyTextSize(size)
                .appendRawTextLine(string)
                .newline()
            builder.resetStyle()
        }
    }

    // MARK: - Shared layout (single source of truth)

    static func layoutLines(from attributed: NSAttributedString, config: PrinterConfig) -> [LayoutLine] {
        var result: [LayoutLine] = []
        guard attributed.length > 0 else { return [.blank] }

        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? ReceiptDividerAttachment {
                let kind: DividerKind = attachment.style == .dashed ? .dashed : .solid
                result.append(.divider(kind))
                return
            }

            let chunk = (attributed.string as NSString).substring(with: range)
            if chunk.isEmpty { return }

            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isUnderline = (attrs[.underlineStyle] as? Int).map { $0 != 0 } ?? false
            let pointSize = font?.pointSize ?? AttributedTextView.defaultFontSize
            let requestedSize = textSize(forPointSize: pointSize)
            let align = Self.escposAlign(from: attrs[.paragraphStyle] as? NSParagraphStyle)

            let parts = chunk.components(separatedBy: "\n")
            for (index, part) in parts.enumerated() {
                let partClean = part.replacingOccurrences(of: "\u{FFFC}", with: "")
                if partClean.isEmpty {
                    if index < parts.count - 1 {
                        result.append(.blank)
                    }
                    continue
                }
                if let divider = legacyDividerKind(for: partClean) {
                    result.append(.divider(divider))
                } else {
                    // Bitmap pipeline: the requested size (default = double / 2×) is honored for
                    // ALL text incl. mixed CJK+EN. No per-content size downgrade — that broke the 2× default.
                    let size = requestedSize
                    let maxCols = effectiveColumns(for: size, config: config)
                    let wrapped = ReceiptTextLayout.wrap(partClean, maxColumns: maxCols)
                    for w in wrapped {
                        result.append(.text(
                            string: w,
                            size: size,
                            bold: isBold,
                            underline: isUnderline,
                            align: align
                        ))
                    }
                }
            }
        }
        return result.isEmpty ? [.blank] : result
    }

    static func escposAlign(from paragraph: NSParagraphStyle?) -> ESCPOSAlign {
        switch paragraph?.alignment {
        case .center: return .center
        case .right: return .right
        default: return .left
        }
    }

    static func textSize(forPointSize pointSize: CGFloat) -> TextSize {
        // Editor default 28pt → ESC/POS double (GS ! 0x11).
        if pointSize >= AttributedTextView.defaultFontSize { return .double }
        if pointSize >= AttributedTextView.defaultFontSize * 0.65 { return .tall }
        return .normal
    }

    static func effectiveColumns(for size: TextSize, config: PrinterConfig) -> Int {
        let base = max(8, config.columnsPerLine)
        switch size {
        case .double: return max(8, base / 2) // 48 → 24 cols → 12 CJK
        case .tall, .normal: return base
        }
    }

    private static func legacyDividerKind(for line: String) -> DividerKind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "-" }) { return .solid }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        if !compact.isEmpty, compact.allSatisfy({ $0 == "-" }), trimmed.contains(" ") {
            return .dashed
        }
        return nil
    }

    // MARK: - Preview drawing (column grid = printer)

    private static func lineHeight(for line: LayoutLine, baseCell: CGFloat) -> CGFloat {
        switch line {
        case .blank:
            return max(14, baseCell * 2.4)
        case .divider:
            return max(12, baseCell * 1.6)
        case .text(_, let size, _, _, _):
            let scale: CGFloat = size == .double ? 2 : (size == .tall ? 1.6 : 1)
            return max(18, baseCell * 2.4 * scale)
        }
    }

    private static func drawLine(
        _ line: LayoutLine,
        at y: CGFloat,
        height: CGFloat,
        contentWidth: CGFloat,
        baseCell: CGFloat,
        paddingX: CGFloat,
        columns: Int,
        asciiAsDoubleWidth: Bool
    ) {
        switch line {
        case .blank:
            return
        case .divider(let kind):
            // Match print: N hyphen columns at normal width spanning full content.
            let cols = max(8, columns)
            let unit = contentWidth / CGFloat(cols)
            let midY = y + height * 0.5
            let path = NSBezierPath()
            path.lineWidth = max(1.5, baseCell * 0.35)
            path.lineCapStyle = .butt
            switch kind {
            case .solid:
                path.move(to: NSPoint(x: paddingX, y: midY))
                path.line(to: NSPoint(x: paddingX + contentWidth, y: midY))
            case .dashed:
                // Visual match for "- - - ..." : unit dash + unit gap
                var x = paddingX
                while x < paddingX + contentWidth - 0.5 {
                    let dashEnd = min(x + unit, paddingX + contentWidth)
                    path.move(to: NSPoint(x: x, y: midY))
                    path.line(to: NSPoint(x: dashEnd, y: midY))
                    x += unit * 2
                }
            }
            NSColor.black.setStroke()
            path.stroke()
        case .text(let string, let size, let bold, let underline, let align):
            drawPrinterLine(
                string,
                size: size,
                bold: bold,
                underline: underline,
                align: align,
                at: y,
                height: height,
                contentWidth: contentWidth,
                paddingX: paddingX,
                columns: columns,
                asciiAsDoubleWidth: asciiAsDoubleWidth
            )
        }
    }

    /// Draw one already-wrapped printer line on a fixed column grid.
    /// Does NOT call NSString.draw(in:) over a wide rect (that would re-wrap).
    private static func drawPrinterLine(
        _ string: String,
        size: TextSize,
        bold: Bool,
        underline: Bool,
        align: ESCPOSAlign,
        at y: CGFloat,
        height: CGFloat,
        contentWidth: CGFloat,
        paddingX: CGFloat,
        columns: Int,
        asciiAsDoubleWidth: Bool
    ) {
        let maxCols = size == .double ? max(8, columns / 2) : max(8, columns)
        let unitW = contentWidth / CGFloat(maxCols)
        let resolvedSize: CGFloat
        switch size {
        case .double: resolvedSize = max(14, unitW * 1.7)
        case .tall: resolvedSize = max(12, unitW * 1.9)
        case .normal: resolvedSize = max(11, unitW * 1.7)
        }
        let weight: NSFont.Weight = bold ? .semibold : .regular
        let font = NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: weight)

        let usedCols = ReceiptTextLayout.displayWidth(string, asciiAsDoubleWidth: asciiAsDoubleWidth)
        let originOffset: CGFloat
        switch align {
        case .center:
            originOffset = unitW * CGFloat(max(0, maxCols - usedCols)) / 2
        case .right:
            originOffset = unitW * CGFloat(max(0, maxCols - usedCols))
        case .left:
            originOffset = 0
        }

        var x = paddingX + originOffset
        for ch in string {
            let cols = ReceiptTextLayout.displayWidth(String(ch), asciiAsDoubleWidth: asciiAsDoubleWidth)
            let cellW = unitW * CGFloat(cols)
            let rect = NSRect(x: x, y: y, width: cellW, height: height)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byClipping
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: para
            ]
            if underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            (String(ch) as NSString).draw(in: rect, withAttributes: attrs)
            x += cellW
            if x > paddingX + contentWidth + 0.5 { break }
        }
    }
}
