import AppKit
import Foundation

enum POSReceiptPrintComposer {
    struct Result {
        var artifacts: PrintArtifacts
        var previewImage: NSImage
    }

    static func compose(
        template: POSReceiptTemplate,
        items: [POSLineItem],
        surcharge: String,
        surchargePercentLabel: String? = nil,
        backgroundImage: NSImage?,
        logoImages: [UUID: NSImage],
        config: PrinterConfig,
        ticketAutoNumber: String? = nil,
        now: Date = Date(),
        expandFooterShift: Bool = true
    ) -> Result {
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: items,
            surcharge: surcharge,
            surchargePercentLabel: surchargePercentLabel,
            now: now,
            ticketAutoNumber: ticketAutoNumber,
            config: config,
            expandFooterShift: expandFooterShift
        )

        let paper = CGSize(width: template.paperSize.width, height: layout.canvasHeight)
        let body = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
        let fontSize = AttributedTextView.defaultFontSize

        let gridTexts = layout.texts.filter { !$0.asOverlay }
        let overlayTexts = layout.texts.filter(\.asOverlay)

        let placeholders: [SequencePlaceholder] = gridTexts.enumerated().map { index, t in
            SequencePlaceholder(
                id: UUID(),
                bindingKey: "pos_\(index)",
                frame: t.frame,
                fontSize: t.fontSize,
                alignment: t.alignment,
                zIndex: index
            )
        }
        var values: [String: String] = [:]
        for (index, t) in gridTexts.enumerated() {
            values["pos_\(index)"] = t.text
        }

        let composed = SequenceLayoutComposer.compose(
            body: body,
            placeholders: placeholders,
            values: values,
            config: config,
            fontSize: fontSize,
            paperWidthPoints: paper.width
        )

        var logoLayers: [RichTextPrintRenderer.SequenceLogoLayer] = []
        for placed in layout.logos {
            guard let img = logoImages[placed.elementId] else { continue }
            logoLayers.append(.init(image: img, frame: placed.frame))
        }
        for barcode in layout.barcodeTexts {
            if let img = makeBarcodeImage(content: barcode.text, size: CGSize(width: barcode.frame.width, height: barcode.frame.height)) {
                logoLayers.append(.init(image: img, frame: barcode.frame))
            }
        }

        let textOverlays: [RichTextPrintRenderer.SequenceTextOverlay] = overlayTexts.map {
            .init(
                text: $0.text,
                frame: $0.frame,
                fontSize: $0.fontSize,
                alignment: $0.alignment,
                asRule: $0.asRule,
                ruleDashed: $0.ruleDashed,
                isBold: $0.isBold,
                annotation: $0.annotation
            )
        }

        let media = RichTextPrintRenderer.SequencePageMedia(
            background: backgroundImage,
            backgroundScalePercent: template.backgroundScalePercent,
            logos: logoLayers,
            textOverlays: textOverlays,
            canvasSize: paper
        )

        let preview = RichTextPrintRenderer.renderSequencePageImage(
            attributedString: composed,
            config: config,
            media: media
        )
        let pngData = preview.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        } ?? Data()

        // POS designer needs WYSIWYG fonts → print the preview bitmap as banded GS v 0.
        // Native-GBK grid path collapses all overlay fontSize (log: usedNativeText=true → 字体全没).
        // Band init re-asserts FS . per strip so raster bytes are not read as GBK.
        // End on cut only — trailing ESC @ after cut left ticket 2+ garbled on POS-80.
        let feed = max(config.feedLinesBeforeCut, 12)
        let warmup = Self.whiteStrip(width: config.dotsPerLine, height: 24)
        let payload = ESCPOSBuilder(config: config)
            .initializeForRaster()
            .align(.left)
            .imageBanded(warmup, maxWidth: config.dotsPerLine, bandHeight: 24)
            .initializeForRaster()
            .align(.left)
            .imageBanded(preview, maxWidth: config.dotsPerLine, bandHeight: 48)
            .cut(feedLines: feed, reassertChinese: false)
            .build()
        let artifacts = PrintArtifacts(
            sourceText: composed.string,
            attributedRTFD: nil,
            pngData: pngData,
            rasterData: Data(),
            payload: payload,
            imagePixelWidth: Int(preview.size.width),
            imagePixelHeight: Int(preview.size.height),
            rasterWidthBytes: 0,
            rasterHeight: 0,
            headerXL: 0,
            headerXH: 0,
            headerYL: 0,
            headerYH: 0,
            expectedRasterBytes: 0,
            renderMode: .raster,
            usedNativeText: false,
            usedRaster: true,
            dpi: 203,
            printableWidthDots: config.dotsPerLine,
            printerModelHint: "POS receipt preview-raster banded (WYSIWYG)"
        )

        return Result(artifacts: artifacts, previewImage: preview)
    }

    private static func whiteStrip(width: Int, height: Int) -> NSImage {
        let w = max(8, width)
        let h = max(8, height)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
    }

    /// Simple Code128-like bars (same approach as TemplateRenderer preview).
    static func makeBarcodeImage(content: String, size: CGSize) -> NSImage? {
        let w = max(40, size.width)
        let h = max(24, size.height)
        return NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let digits = content.filter { $0.isNumber || $0.isLetter }
            guard !digits.isEmpty else { return false }
            var pattern: [Bool] = [true, true, false]
            for (index, ch) in digits.utf8.enumerated() {
                let v = Int(ch)
                pattern.append(true)
                pattern.append(index % 2 == 0)
                pattern.append(false)
                pattern.append(v % 2 == 0)
                pattern.append(true)
                pattern.append(false)
            }
            pattern.append(contentsOf: [true, true, true, false, true])
            let unit = max(1, floor(rect.width / CGFloat(max(pattern.count, 1))))
            var x = rect.minX
            NSColor.black.setFill()
            for bit in pattern {
                if bit {
                    NSRect(x: x, y: rect.minY + 2, width: unit, height: rect.height - 4).fill()
                }
                x += unit
                if x > rect.maxX { break }
            }
            return true
        }
    }
}
