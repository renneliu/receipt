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

    /// Media layered under/over sequence ticket text (editor canvas coordinates for logo).
    struct SequencePageMedia {
        var background: NSImage? = nil
        var logo: NSImage? = nil
        var logoFrame: SequencePlaceholderFrame? = nil
        /// Editor paper size used for logo frame mapping (points).
        var canvasSize: CGSize = .zero
    }

    static func renderImage(attributedString: NSAttributedString, config: PrinterConfig, padding: CGFloat = 8) -> NSImage {
        renderSequencePageImage(
            attributedString: attributedString,
            config: config,
            media: SequencePageMedia(),
            padding: padding
        )
    }

    /// White → fitCenter background → text → logo. Used for sequence preview and print.
    static func renderSequencePageImage(
        attributedString: NSAttributedString,
        config: PrinterConfig,
        media: SequencePageMedia,
        padding: CGFloat = 8
    ) -> NSImage {
        let lines = layoutLines(from: attributedString, config: config)
        let width = CGFloat(config.dotsPerLine)
        let contentWidth = width - padding * 2
        let baseCell = contentWidth / CGFloat(max(config.columnsPerLine, 1))
        var heights: [CGFloat] = []
        for line in lines {
            heights.append(lineHeight(for: line, baseCell: baseCell))
        }
        let contentHeight = heights.reduce(padding * 2, +) + CGFloat(max(0, heights.count - 1)) * 2

        let canvas = media.canvasSize
        let scale: CGFloat
        if canvas.width > 1 {
            scale = width / canvas.width
        } else {
            scale = 1
        }
        var pixelHeight = max(80, ceil(contentHeight))
        if canvas.height > 1 {
            pixelHeight = max(pixelHeight, ceil(canvas.height * scale))
        }
        if let frame = media.logoFrame, media.logo != nil {
            pixelHeight = max(pixelHeight, ceil((frame.y + frame.height) * scale + padding))
        }
        let size = NSSize(width: width, height: pixelHeight)

        return NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()

            if let bg = media.background {
                let rect = fitCenterRect(imageSize: bg.size, in: NSRect(origin: .zero, size: size))
                bg.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
                )
            }

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

            if let logo = media.logo, let frame = media.logoFrame, canvas.width > 1 {
                let dest = NSRect(
                    x: frame.x * scale,
                    y: frame.y * scale,
                    width: frame.width * scale,
                    height: frame.height * scale
                )
                logo.draw(
                    in: dest,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
                )
            }
            return true
        }
    }

    /// Aspect-fit, centered (may letterbox).
    static func fitCenterRect(imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let sx = bounds.width / imageSize.width
        let sy = bounds.height / imageSize.height
        let s = min(sx, sy)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return NSRect(
            x: bounds.minX + (bounds.width - w) / 2,
            y: bounds.minY + (bounds.height - h) / 2,
            width: w,
            height: h
        )
    }

    /// Native-text ESC/POS from the shared layout line list (the path that prints Chinese on this POS-80).
    static func renderESCPOS(attributedString: NSAttributedString, config: PrinterConfig) -> Data {
        let lines = layoutLines(from: attributedString, config: config)
        let builder = ESCPOSBuilder(config: config).initialize()
        // Same-style soft wraps as one block. Encoding restored to proven FS ./FS & path
        // (successful diag 20260714-224905) with CJK-leading mixed-line exception.
        emitBatched(lines, into: builder, config: config)
        let feedBeforeCut = max(config.feedLinesBeforeCut, minimumFeedsBeforeCut)
        if config.cutPaper {
            builder.cut(feedLines: feedBeforeCut)
        }
        return builder.build()
    }

    /// Sequence tickets as per-page bit-images (`GS v 0` via `initializeForRaster`).
    /// Cuts after each page so every Excel row becomes its own ticket.
    /// Text + background + logo are composited in software first — never `FS &` then GS v 0.
    static func renderSequenceESCPOS(
        pages: [NSAttributedString],
        config: PrinterConfig,
        media: SequencePageMedia = SequencePageMedia()
    ) -> Data {
        let builder = ESCPOSBuilder(config: config).initializeForRaster()
        let feedBeforeCut = max(config.feedLinesBeforeCut, minimumFeedsBeforeCut)
        for (index, page) in pages.enumerated() {
            let image = renderSequencePageImage(
                attributedString: page,
                config: config,
                media: media
            )
            builder.image(image, maxWidth: config.dotsPerLine)
            if config.cutPaper {
                builder.cut(feedLines: feedBeforeCut, reassertChinese: false)
                if index < pages.count - 1 {
                    builder.initializeForRaster()
                }
            } else {
                builder.feed(lines: feedBeforeCut)
            }
        }
        return builder.build()
    }

    /// Raster artifacts for sequence / current print when media may include images.
    static func buildSequenceRasterArtifacts(
        attributedString: NSAttributedString,
        config: PrinterConfig,
        media: SequencePageMedia,
        sourceText: String,
        attributedRTFD: Data?
    ) -> PrintArtifacts {
        let image = renderSequencePageImage(
            attributedString: attributedString,
            config: config,
            media: media
        )
        let pngData = Self.pngData(from: image) ?? Data()
        let payload = renderSequenceESCPOS(pages: [attributedString], config: config, media: media)
        let firstRaster = BarcodeGenerator.rasterizeWithPNG(image, maxWidth: config.dotsPerLine)
        let raster = firstRaster?.raster
        let widthBytes = raster?.widthBytes ?? 0
        let height = raster?.height ?? 0
        let rasterData = raster?.data ?? Data()
        let expected = widthBytes * height

        return PrintArtifacts(
            sourceText: sourceText,
            attributedRTFD: attributedRTFD,
            pngData: firstRaster?.grayPNG ?? pngData,
            rasterData: rasterData,
            payload: payload,
            imagePixelWidth: Int(image.size.width),
            imagePixelHeight: Int(image.size.height),
            rasterWidthBytes: widthBytes,
            rasterHeight: height,
            headerXL: widthBytes & 0xFF,
            headerXH: (widthBytes >> 8) & 0xFF,
            headerYL: height & 0xFF,
            headerYH: (height >> 8) & 0xFF,
            expectedRasterBytes: expected,
            renderMode: .raster,
            usedNativeText: false,
            usedRaster: true,
            dpi: 203,
            printableWidthDots: config.dotsPerLine,
            printerModelHint: "POS-80 sequence raster"
        )
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

    private static func emitBatched(_ lines: [LayoutLine], into builder: ESCPOSBuilder, config: PrinterConfig) {
        var index = 0
        while index < lines.count {
            switch lines[index] {
            case .blank:
                builder.newline()
                index += 1
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
                index += 1
            case .text(_, let size, let bold, let underline, let align):
                var batch: [String] = []
                while index < lines.count {
                    if case .text(let s, let sSize, let sBold, let sUnderline, let sAlign) = lines[index],
                       sSize == size, sBold == bold, sUnderline == underline, sAlign == align {
                        batch.append(s)
                        index += 1
                    } else {
                        break
                    }
                }
                builder.align(align)
                    .bold(bold)
                    .underline(underline)
                    .applyTextSize(size)
                for s in batch {
                    builder.appendRawTextLine(s).newline()
                }
                builder.resetStyle()
            }
        }
    }

    // MARK: - Shared layout (single source of truth)

    /// Layout by paragraph (not by attributed-run).
    ///
    /// NSTextView often splits CJK vs Latin into different font attribute runs. Wrapping each run
    /// separately forced ASCII onto its own printed line (runtime evidence: source had no newline
    /// between `…哦为` and `UI`, but payload emitted `…哦为\\nUI\\n…`).
    static func layoutLines(from attributed: NSAttributedString, config: PrinterConfig) -> [LayoutLine] {
        var result: [LayoutLine] = []
        guard attributed.length > 0 else { return [.blank] }

        let ns = attributed.string as NSString
        var location = 0
        while location < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paraRange) }

            var dividerKind: DividerKind?
            attributed.enumerateAttribute(.attachment, in: paraRange, options: []) { value, _, stop in
                guard let attachment = value as? ReceiptDividerAttachment else { return }
                dividerKind = attachment.style == .dashed ? .dashed : .solid
                stop.pointee = true
            }
            if let kind = dividerKind {
                result.append(.divider(kind))
                continue
            }

            var contentRange = paraRange
            if contentRange.length > 0 {
                let last = ns.character(at: NSMaxRange(contentRange) - 1)
                if last == 10 { // \n
                    contentRange.length -= 1
                } else if last == 13 { // \r
                    contentRange.length -= 1
                }
            }

            if contentRange.length == 0 {
                result.append(.blank)
                continue
            }

            let paragraph = ns.substring(with: contentRange)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            if paragraph.isEmpty {
                result.append(.blank)
                continue
            }
            if let divider = legacyDividerKind(for: paragraph) {
                result.append(.divider(divider))
                continue
            }

            let attrs = attributed.attributes(at: contentRange.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isUnderline = (attrs[.underlineStyle] as? Int).map { $0 != 0 } ?? false
            let pointSize = font?.pointSize ?? AttributedTextView.defaultFontSize
            let size = textSize(forPointSize: pointSize)
            let align = Self.escposAlign(from: attrs[.paragraphStyle] as? NSParagraphStyle)
            let maxCols = effectiveColumns(for: size, config: config)
            // Halfwidth ASCII under continuous FS & (1 column). Do not use fullwidth —
            // that forced English onto its own wrap lines (runtime: jsdhfk… alone).
            let wrapped = ReceiptTextLayout.wrap(paragraph, maxColumns: maxCols, asciiAsDoubleWidth: false)
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
        // Editor default 28pt → TextSize.double → GS ! 0x11 (successful diag 20260714-224905).
        if pointSize >= AttributedTextView.defaultFontSize { return .double }
        if pointSize >= AttributedTextView.defaultFontSize * 0.65 { return .tall }
        return .normal
    }

    static func effectiveColumns(for size: TextSize, config: PrinterConfig) -> Int {
        let base = max(8, config.columnsPerLine)
        switch size {
        case .double: return max(8, base / 2) // width×2 → 24 cols
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
