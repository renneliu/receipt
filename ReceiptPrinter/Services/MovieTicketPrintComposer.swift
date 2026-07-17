import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum MovieTicketPrintComposer {
    struct Result {
        var artifacts: PrintArtifacts
        var previewImage: NSImage
    }

    static func compose(
        template: MovieTicketTemplate,
        draft: MovieTicketDraft,
        backgroundImage: NSImage?,
        logoImages: [UUID: NSImage] = [:],
        config: PrinterConfig,
        now: Date = Date()
    ) -> Result {
        _ = backgroundImage

        let logoImage = template.elements
            .first(where: { $0.kind == .logo })
            .flatMap { logoImages[$0.id] }

        let escposPayload: Data
        let preview: NSImage
        let hint: String
        if template.usesIMAXSydneyLayout {
            escposPayload = MovieTicketIMAXESCPOS.render(
                template: template,
                draft: draft,
                config: config,
                logoImage: logoImage,
                now: now
            )
            preview = MovieTicketIMAXESCPOS.previewImage(
                template: template,
                draft: draft,
                config: config,
                logoImage: logoImage,
                now: now
            )
            hint = "Movie ticket native ESC/POS (IMAX Sydney Font A + logo)"
        } else {
            escposPayload = MovieTicketRitzESCPOS.render(
                template: template,
                draft: draft,
                config: config,
                now: now
            )
            preview = MovieTicketRitzESCPOS.previewImage(
                template: template,
                draft: draft,
                config: config,
                now: now
            )
            hint = "Movie ticket native ESC/POS (Ritz Font A + GS !)"
        }
        let pngData = preview.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        } ?? Data()

        let artifacts = PrintArtifacts(
            sourceText: draft.movieTitle,
            attributedRTFD: nil,
            pngData: pngData,
            rasterData: Data(),
            payload: escposPayload,
            imagePixelWidth: Int(preview.size.width),
            imagePixelHeight: Int(preview.size.height),
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
            printerModelHint: hint
        )
        return Result(artifacts: artifacts, previewImage: preview)
    }

    /// Real Code 128 via Core Image (Ritz-style 1D barcode).
    static func makeCode128Barcode(content: String, size: CGSize) -> NSImage? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(trimmed.utf8)
        guard let output = filter.outputImage else { return nil }
        let targetW = max(40, size.width)
        let targetH = max(24, size.height)
        let sx = targetW / max(output.extent.width, 1)
        let sy = targetH / max(output.extent.height, 1)
        let transformed = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: NSSize(width: targetW, height: targetH))
        image.addRepresentation(rep)
        return image
    }

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
