import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum BarcodeGenerator {
    static func makeQRCode(_ string: String, size: Int) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = CGFloat(size) / output.extent.width
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func rasterizeImage(
        _ image: NSImage,
        maxWidth: Int,
        threshold: UInt8 = 128,
        scaleToWidth: Bool = false
    ) -> RasterImage? {
        rasterizeWithPNG(
            image, maxWidth: maxWidth, threshold: threshold, scaleToWidth: scaleToWidth
        )?.raster
    }

    /// Diagnostics-friendly rasterization: 1-bit raster + PNG of the 8-bit RGB intermediate.
    struct RasterizeOutput {
        let raster: RasterImage
        let grayPNG: Data?
    }

    /// - Parameter scaleToWidth: When true, output width is `maxWidth` (may upscale). When false
    ///   (default), width is `min(maxWidth, source)` — 1 preview pixel ≈ 1 printer dot.
    static func rasterizeWithPNG(
        _ image: NSImage,
        maxWidth: Int,
        threshold: UInt8 = 128,
        scaleToWidth: Bool = false
    ) -> RasterizeOutput? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Width must be multiple of 8 for GS v 0.
        let width: Int
        if scaleToWidth {
            width = max(8, (maxWidth / 8) * 8)
        } else {
            width = min(maxWidth, ((max(cgImage.width, 8) + 7) / 8) * 8)
        }
        guard width > 0 else { return nil }
        let aspect = Double(cgImage.height) / Double(max(cgImage.width, 1))
        let height = max(1, Int((Double(width) * aspect).rounded()))
        let widthBytes = width / 8

        // Normalize color depth/alpha via 8-bit sRGB, then luminance → hard threshold.
        // Do NOT Floyd–Steinberg the whole ticket: dither shreds CJK glyph edges into
        // speckles that thermal prints look like “乱码”. Color logos are already converted
        // to binary B&W at import; soft photos get contrast stretch when needed.
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        guard let rgbCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        rgbCtx.interpolationQuality = .none
        rgbCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        rgbCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        rgbCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgbPtr = rgbCtx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            return nil
        }

        var gray = [UInt8](repeating: 0, count: width * height)
        var minG = 255
        var maxG = 0
        for i in 0..<(width * height) {
            let o = i * 4
            let r = Double(rgbPtr[o])
            let g = Double(rgbPtr[o + 1])
            let b = Double(rgbPtr[o + 2])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let y = Int(luma.rounded())
            let v = UInt8(min(255, max(0, y)))
            gray[i] = v
            if Int(v) < minG { minG = Int(v) }
            if Int(v) > maxG { maxG = Int(v) }
        }

        let range = maxG - minG
        if range > 1 && range < 80 {
            let scale = 255.0 / Double(range)
            for i in 0..<gray.count {
                gray[i] = UInt8(min(255, max(0, Int(((Double(gray[i]) - Double(minG)) * scale).rounded()))))
            }
        }

        var data = Data(repeating: 0, count: widthBytes * height)
        let thr = Int(threshold)
        for y in 0..<height {
            for x in 0..<width {
                if Int(gray[y * width + x]) < thr {
                    let byteIndex = y * widthBytes + x / 8
                    let bit = 7 - (x % 8)
                    data[byteIndex] |= UInt8(1 << bit)
                }
            }
        }

        var grayPNG: Data?
        if let rgbImage = rgbCtx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: rgbImage)
            grayPNG = rep.representation(using: .png, properties: [:])
        }

        let raster = RasterImage(width: width, height: height, widthBytes: widthBytes, data: data)
        return RasterizeOutput(raster: raster, grayPNG: grayPNG)
    }
}
