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
        let scale = MovieTicketRitzESCPOS.printScale(
            fontSize: el.fontSize, boxHeight: el.frame.height
        )
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
}
