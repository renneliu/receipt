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
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = min(maxWidth, ((cgImage.width + 7) / 8) * 8)
        guard width > 0 else { return nil }
        let aspect = Double(cgImage.height) / Double(cgImage.width)
        let height = max(1, Int(Double(width) * aspect))
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

        ctx.interpolationQuality = .high
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
        return RasterImage(width: width, height: height, widthBytes: widthBytes, data: data)
    }
}
