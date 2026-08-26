import AppKit
import Foundation

/// Paper-point sizes for ESC/POS Font A blocks, matching what the printer actually emits.
enum MovieTicketPrintMetrics {
    /// Font A glyph cell at 1× magnification (ESC/POS standard).
    static let fontACellDots = CGSize(width: 12, height: 24)

    static func pointsPerDot(paperWidth: CGFloat, dotsPerLine: Int) -> CGFloat {
        paperWidth / CGFloat(max(1, dotsPerLine))
    }

    /// One printed text line height for the given height magnification.
    static func lineHeightPoints(
        heightScale: Int,
        paperWidth: CGFloat,
        dotsPerLine: Int
    ) -> CGFloat {
        fontACellDots.height
            * CGFloat(max(1, min(8, heightScale)))
            * pointsPerDot(paperWidth: paperWidth, dotsPerLine: dotsPerLine)
    }

    /// Editor `fontSize` buckets that map to GS ! width 1× / 2× / 3×.
    static func fontSize(forWidthScale widthScale: Int) -> CGFloat {
        let w = max(1, min(3, widthScale))
        return w <= 1 ? 11 : (w == 2 ? 14 : 20)
    }

    /// Printed ink width in paper points for `columns` characters at `widthScale`.
    static func inkWidthPoints(
        columns: Int,
        widthScale: Int,
        paperWidth: CGFloat,
        dotsPerLine: Int,
        columnsPerLine: Int
    ) -> CGFloat {
        let scale = CGFloat(max(1, min(8, widthScale)))
        let charDots = CGFloat(dotsPerLine) / CGFloat(max(1, columnsPerLine)) * scale
        return CGFloat(max(1, columns)) * charDots
            * pointsPerDot(paperWidth: paperWidth, dotsPerLine: dotsPerLine)
    }

    /// Infer 1×/2×/3× print width from a placeholder box width.
    static func widthScale(
        fromFrameWidth width: CGFloat,
        textColumns: Int,
        paperWidth: CGFloat,
        dotsPerLine: Int,
        columnsPerLine: Int
    ) -> Int {
        let cols = max(1, textColumns)
        let w1 = inkWidthPoints(
            columns: cols, widthScale: 1,
            paperWidth: paperWidth, dotsPerLine: dotsPerLine, columnsPerLine: columnsPerLine
        )
        let w2 = inkWidthPoints(
            columns: cols, widthScale: 2,
            paperWidth: paperWidth, dotsPerLine: dotsPerLine, columnsPerLine: columnsPerLine
        )
        let w3 = inkWidthPoints(
            columns: cols, widthScale: 3,
            paperWidth: paperWidth, dotsPerLine: dotsPerLine, columnsPerLine: columnsPerLine
        )
        if width < (w1 + w2) / 2 { return 1 }
        if width < (w2 + w3) / 2 { return 2 }
        return 3
    }

    /// Clamp template `characterSpacing` to the ESC SP range used by printers.
    static func clampedCharacterSpacing(_ value: Int) -> Int {
        max(0, min(32, value))
    }

    /// Total ink width in dots for Font A text including right-side spacing after each glyph.
    static func inkWidthDots(
        text: String,
        widthScale: Int,
        characterSpacing: Int
    ) -> CGFloat {
        let wScale = CGFloat(max(1, widthScale))
        let cellW = fontACellDots.width * wScale
        let gap = CGFloat(clampedCharacterSpacing(characterSpacing))
        var width: CGFloat = 0
        for ch in text {
            let cols = max(1, ReceiptTextLayout.displayWidth(String(ch)))
            width += CGFloat(cols) * cellW + gap
        }
        return width
    }

    /// Draw Font A–style text; `characterSpacing` matches ESC SP (absolute dots after each glyph).
    /// When `contextAlreadyScaled` is true, the CGContext already has width/height magnification —
    /// glyphs use 1× cell metrics and spacing is divided by widthScale so final dots stay absolute.
    static func drawSpacedFontAText(
        _ text: String,
        at origin: CGPoint,
        font: NSFont,
        color: NSColor,
        widthScale: Int,
        characterSpacing: Int,
        contextAlreadyScaled: Bool
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let wScale = max(1, widthScale)
        let cellW: CGFloat
        let gap: CGFloat
        if contextAlreadyScaled {
            cellW = fontACellDots.width
            gap = CGFloat(clampedCharacterSpacing(characterSpacing)) / CGFloat(wScale)
        } else {
            cellW = fontACellDots.width * CGFloat(wScale)
            gap = CGFloat(clampedCharacterSpacing(characterSpacing))
        }
        var x = origin.x
        for ch in text {
            let s = String(ch)
            (s as NSString).draw(at: CGPoint(x: x, y: origin.y), withAttributes: attrs)
            let cols = max(1, ReceiptTextLayout.displayWidth(s))
            x += CGFloat(cols) * cellW + gap
        }
    }

    /// Typical column count used when sizing a hall invert badge.
    static func estimatedTextColumns(for el: MovieTicketElement) -> Int {
        if el.fieldKind == .hall {
            // Prefer live frame width so editor 「宽」 matches printed black badge.
            let paperW: CGFloat = 302
            let dots = 576
            let cols = 48
            let scale = el.fontSize <= 11 ? 1 : (el.fontSize <= 16 ? 2 : 3)
            let colW = inkWidthPoints(
                columns: 1,
                widthScale: scale,
                paperWidth: paperW,
                dotsPerLine: dots,
                columnsPerLine: cols
            )
            return max(1, Int((el.frame.width / max(colW, 0.1)).rounded()))
        }
        let trimmed = el.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return max(2, ReceiptTextLayout.displayWidth(trimmed))
        }
        return 8
    }

    /// Build reverse-print hall text whose ink width tracks the placeholder frame.
    /// Narrower 「宽」 → fewer pad spaces → narrower black badge (not only GS ! scale).
    static func invertedHallHighlightText(
        number: String,
        frameWidth: CGFloat?,
        widthScale: Int,
        paperWidth: CGFloat,
        dotsPerLine: Int,
        columnsPerLine: Int
    ) -> String {
        let core = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return "" }
        let coreCols = max(1, ReceiptTextLayout.displayWidth(core))
        guard let frameWidth, frameWidth > 1 else {
            return " \(core) "
        }
        let colW = inkWidthPoints(
            columns: 1,
            widthScale: widthScale,
            paperWidth: paperWidth,
            dotsPerLine: dotsPerLine,
            columnsPerLine: columnsPerLine
        )
        let targetCols = max(coreCols, Int((frameWidth / max(colW, 0.1)).rounded()))
        let pad = max(0, targetCols - coreCols)
        let left = pad / 2
        let right = pad - left
        return String(repeating: " ", count: left) + core + String(repeating: " ", count: right)
    }

    /// Code128 bar height in paper points (same mapping as `MovieTicketRitzESCPOS`).
    static func barcodeHeightPoints(
        elementBoxHeight: CGFloat,
        paperWidth: CGFloat,
        dotsPerLine: Int
    ) -> CGFloat {
        let dots = Int((elementBoxHeight * (110.0 / 72.0)).rounded())
        let clamped = max(24, min(255, dots))
        return CGFloat(clamped) * pointsPerDot(paperWidth: paperWidth, dotsPerLine: dotsPerLine)
    }

    /// Placeholder block height that matches the printed element for this template element.
    static func placeholderHeight(
        for el: MovieTicketElement,
        paperWidth: CGFloat,
        config: PrinterConfig
    ) -> CGFloat {
        if el.fieldKind == .barcode {
            // Keep the editor box height as the source of truth. Remapping through
            // barcodeHeightPoints (pt → ESC/POS dots → pt) is non-idempotent on
            // 80mm paper (~0.8×) and was capping usable heights around ~40 after sync.
            return max(24, el.frame.height)
        }
        if el.fieldKind == .qrCode {
            // QR uses the box's shorter side in compose; keep stored height as the block size.
            return max(40, el.frame.height)
        }
        if el.kind == .logo {
            return max(24, el.frame.height)
        }
        let scale = MovieTicketRitzESCPOS.printScale(for: el)
        return lineHeightPoints(
            heightScale: scale.height,
            paperWidth: paperWidth,
            dotsPerLine: config.dotsPerLine
        )
    }

    /// Snap every non-logo element's frame height to its printed block height.
    static func syncTemplateHeights(
        _ template: inout MovieTicketTemplate,
        config: PrinterConfig
    ) {
        let paperW = template.paperSize.width
        for i in template.elements.indices {
            let el = template.elements[i]
            if el.kind == .logo { continue }
            let h = placeholderHeight(for: el, paperWidth: paperW, config: config)
            template.elements[i].frame.height = h
        }
    }

    // MARK: - Element box = printable region

    /// How many Font A columns fit in the element box width at the given print width scale.
    static func boxColumns(
        frameWidth: CGFloat,
        paperWidth: CGFloat,
        config: PrinterConfig,
        widthScale: Int
    ) -> Int {
        let scale = CGFloat(max(1, widthScale))
        let paperW = max(1, paperWidth)
        let charDots = CGFloat(config.dotsPerLine) / CGFloat(max(1, config.columnsPerLine)) * scale
        let boxDots = frameWidth * CGFloat(config.dotsPerLine) / paperW
        let cols = Int((boxDots / max(1, charDots)).rounded(.down))
        return max(1, min(cols, config.columnsPerLine / max(1, Int(scale))))
    }

    /// How many printed text lines fit in the element box height at the given height scale.
    static func boxMaxLines(
        frameHeight: CGFloat,
        paperWidth: CGFloat,
        config: PrinterConfig,
        heightScale: Int
    ) -> Int {
        let lineH = lineHeightPoints(
            heightScale: heightScale,
            paperWidth: paperWidth,
            dotsPerLine: config.dotsPerLine
        )
        return max(1, Int((frameHeight / max(1, lineH)).rounded(.down)))
    }

    /// Fit text into an element box: single-line clip, or wrap within width and clip by height.
    /// Always emit via `appendRawTextLine` (do not re-wrap to full paper width).
    static func fitTextToElementBox(
        _ text: String,
        frame: SequencePlaceholderFrame,
        paperWidth: CGFloat,
        config: PrinterConfig,
        widthScale: Int,
        heightScale: Int,
        singleLineClip: Bool
    ) -> [String] {
        let cols = boxColumns(
            frameWidth: frame.width,
            paperWidth: paperWidth,
            config: config,
            widthScale: widthScale
        )
        if singleLineClip {
            let clipped = ReceiptTextLayout.clip(text, maxColumns: cols)
            return [clipped.isEmpty ? " " : clipped]
        }
        let maxLines = boxMaxLines(
            frameHeight: frame.height,
            paperWidth: paperWidth,
            config: config,
            heightScale: heightScale
        )
        let wrapped = ReceiptTextLayout.wrap(text, maxColumns: cols)
        let lines = Array(wrapped.prefix(maxLines))
        return lines.isEmpty ? [" "] : lines.map { $0.isEmpty ? " " : $0 }
    }
}
