import AppKit
import Foundation

/// Native GBK + `GS !` ESC/POS for POS receipts (logos/barcodes as short `GS v 0` strips).
/// Emits placed texts in Y-order directly (not via the sequence character grid).
enum POSESCPOS {
    /// Base `ESC 3` line spacing for Font A on this POS-80 before template extra dots.
    private static let baseLineSpacingDots: Int = 30

    private struct EmitItem {
        var y: CGFloat
        var x: CGFloat
        var kind: Kind
        enum Kind {
            case text(String, fontSize: CGFloat, bold: Bool, align: Int, asRule: Bool, ruleDashed: Bool)
            case logo(RichTextPrintRenderer.SequenceLogoLayer)
        }
    }

    static func render(
        layout: POSReceiptLayoutEngine.ExpandedLayout,
        logoImages: [UUID: NSImage],
        barcodeImages: [(image: NSImage, frame: SequencePlaceholderFrame)],
        backgroundImage: NSImage?,
        backgroundScalePercent: Double,
        canvasSize: CGSize,
        config: PrinterConfig,
        lineSpacingExtraDots: Int,
        feedLinesBeforeCut: Int
    ) -> Data {
        var items: [EmitItem] = []

        for t in layout.texts {
            var text = t.text
            if let note = t.annotation, !note.isEmpty {
                text = text.isEmpty ? note : "\(text) \(note)"
            }
            // Honor layout hard-breaks only (already printer-column wrapped in LayoutEngine).
            // Do not re-wrap through the char grid.
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                items.append(EmitItem(
                    y: t.frame.y + CGFloat(i) * 0.01,
                    x: t.frame.x,
                    kind: .text(
                        line,
                        fontSize: t.fontSize,
                        bold: t.isBold,
                        align: t.alignment,
                        asRule: t.asRule && i == 0,
                        ruleDashed: t.ruleDashed
                    )
                ))
            }
        }

        var logoLayers: [RichTextPrintRenderer.SequenceLogoLayer] = []
        for placed in layout.logos {
            guard let img = logoImages[placed.elementId] else { continue }
            let layer = RichTextPrintRenderer.SequenceLogoLayer(image: img, frame: placed.frame)
            logoLayers.append(layer)
            items.append(EmitItem(y: placed.frame.y, x: placed.frame.x, kind: .logo(layer)))
        }
        for barcode in barcodeImages {
            let layer = RichTextPrintRenderer.SequenceLogoLayer(image: barcode.image, frame: barcode.frame)
            logoLayers.append(layer)
            items.append(EmitItem(y: barcode.frame.y, x: barcode.frame.x, kind: .logo(layer)))
        }

        items.sort {
            if abs($0.y - $1.y) > 0.5 { return $0.y < $1.y }
            return $0.x < $1.x
        }

        // Merge same-Y text fragments left-to-right into one print line when they share style.
        let merged = mergeSameRowTexts(items)

        let builder = ESCPOSBuilder(config: config)
        let feed = max(0, min(40, feedLinesBeforeCut))
        let extra = max(0, min(48, lineSpacingExtraDots))
        let lineDots = UInt8(min(255, baseLineSpacingDots + extra))
        let hasRasterMedia = backgroundImage != nil || !logoLayers.isEmpty

        // POS-80 drops the first ~64-byte USB packet. Without padding, that eats
        // initializeForRaster + GS v 0 header → logo bytes print as one garbled text line.
        builder.jobStartPadding(bytes: 96)

        if let bg = backgroundImage {
            builder.initializeForRaster()
            let strip = RichTextPrintRenderer.renderBackgroundStrip(
                image: bg,
                scalePercent: backgroundScalePercent,
                config: config
            )
            builder.imageBanded(strip, maxWidth: config.dotsPerLine, bandHeight: 48)
        }

        var nativeOpen = false

        func ensureNative() {
            if nativeOpen { return }
            builder.initialize()
            if extra > 0 {
                builder.setLineSpacing(lineDots)
            } else {
                builder.resetLineSpacing()
            }
            nativeOpen = true
        }

        for item in merged {
            switch item.kind {
            case .logo(let layer):
                nativeOpen = false
                builder.initializeForRaster()
                let strip = RichTextPrintRenderer.renderLogoStrip(
                    layer: layer,
                    canvasSize: canvasSize,
                    config: config
                )
                builder.imageBanded(strip, maxWidth: config.dotsPerLine, bandHeight: 48)

            case .text(let string, let fontSize, let bold, let align, let asRule, let ruleDashed):
                let trimmed = string.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                ensureNative()
                if asRule || isDividerLine(trimmed) {
                    let cols = max(8, config.columnsPerLine)
                    builder.resetStyle().align(.left).applyTextSize(.normal)
                    if ruleDashed || isDashedDivider(trimmed) {
                        var s = ""
                        for i in 0..<cols { s.append(i % 2 == 0 ? "-" : " ") }
                        builder.appendRawTextLine(s).newline()
                    } else {
                        builder.appendRawTextLine(String(repeating: "-", count: cols)).newline()
                    }
                    continue
                }
                let size = RichTextPrintRenderer.textSize(forPointSize: fontSize)
                let escAlign: ESCPOSAlign = {
                    switch align {
                    case 1: return .center
                    case 2: return .right
                    default: return .left
                    }
                }()
                builder.align(escAlign)
                    .bold(bold)
                    .underline(false)
                    .applyTextSize(size)
                    .appendRawTextLine(string)
                    .newline()
                    .resetStyle()
            }
        }

        if !nativeOpen, merged.isEmpty, backgroundImage == nil {
            builder.initialize()
            if extra > 0 { builder.setLineSpacing(lineDots) }
        }

        builder.resetLineSpacing()
        // Logo/GS v 0 jobs must not leave FS & after cut (avoids ticket 2+ header garble).
        if hasRasterMedia {
            builder.leaveRasterSafe()
        }
        if config.cutPaper {
            builder.cut(feedLines: feed, reassertChinese: !hasRasterMedia)
        } else {
            builder.feed(lines: feed)
        }

        return builder.build()
    }

    /// Join text fragments that share the same Y band into one left-to-right line when styles match.
    private static func mergeSameRowTexts(_ items: [EmitItem]) -> [EmitItem] {
        var out: [EmitItem] = []
        var i = 0
        while i < items.count {
            guard case .text(let s0, let fs0, let b0, let a0, let r0, let d0) = items[i].kind else {
                out.append(items[i])
                i += 1
                continue
            }
            if r0 {
                out.append(items[i])
                i += 1
                continue
            }
            var combined = s0
            var j = i + 1
            while j < items.count,
                  abs(items[j].y - items[i].y) <= 0.5,
                  case .text(let s1, let fs1, let b1, let a1, let r1, _) = items[j].kind,
                  !r1, fs1 == fs0, b1 == b0, a1 == a0 {
                // Separate columns with a single space when both sides have ink.
                let left = combined.trimmingCharacters(in: .whitespaces)
                let right = s1.trimmingCharacters(in: .whitespaces)
                if left.isEmpty {
                    combined = s1
                } else if right.isEmpty {
                    // keep combined
                } else {
                    combined = left + " " + right
                }
                j += 1
            }
            out.append(EmitItem(
                y: items[i].y,
                x: items[i].x,
                kind: .text(combined, fontSize: fs0, bold: b0, align: a0, asRule: false, ruleDashed: d0)
            ))
            i = j
        }
        return out
    }

    private static func isDividerLine(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        return !compact.isEmpty && compact.allSatisfy({ $0 == "-" })
    }

    private static func isDashedDivider(_ s: String) -> Bool {
        s.contains(" ") && isDividerLine(s)
    }
}
