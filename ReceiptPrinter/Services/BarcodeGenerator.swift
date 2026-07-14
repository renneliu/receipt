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

    static func rasterizeImage(_ image: NSImage, maxWidth: Int, threshold: UInt8 = 128) -> RasterImage? {
        rasterizeWithPNG(image, maxWidth: maxWidth, threshold: threshold)?.raster
    }

    /// Diagnostics-friendly rasterization: returns the 1-bit raster AND a PNG of the exact
    /// normalized grayscale bitmap that was thresholded to produce it, so `final-rendered-image.png`
    /// and `monochrome-raster.bin` describe the same pixels for one job.
    struct RasterizeOutput {
        let raster: RasterImage
        let grayPNG: Data?
    }

    static func rasterizeWithPNG(_ image: NSImage, maxWidth: Int, threshold: UInt8 = 128) -> RasterizeOutput? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // 1 preview pixel → 1 printer dot; width must be multiple of 8 for GS v 0
        let width = min(maxWidth, ((max(cgImage.width, 8) + 7) / 8) * 8)
        guard width > 0 else { return nil }
        let aspect = Double(cgImage.height) / Double(max(cgImage.width, 1))
        let height = max(1, Int((Double(width) * aspect).rounded()))
        let widthBytes = width / 8

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = ctx.data else { return nil }
        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: width * height)

        var data = Data(repeating: 0, count: widthBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                if pixels[y * width + x] < threshold {
                    let byteIndex = y * widthBytes + x / 8
                    let bit = 7 - (x % 8)
                    data[byteIndex] |= UInt8(1 << bit)
                }
            }
        }

        var grayPNG: Data?
        if let normalized = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: normalized)
            grayPNG = rep.representation(using: .png, properties: [:])
        }

        let raster = RasterImage(width: width, height: height, widthBytes: widthBytes, data: data)
        return RasterizeOutput(raster: raster, grayPNG: grayPNG)
    }
}
