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
            return barcodeHeightPoints(
                elementBoxHeight: el.frame.height,
                paperWidth: paperWidth,
                dotsPerLine: config.dotsPerLine
            )
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
