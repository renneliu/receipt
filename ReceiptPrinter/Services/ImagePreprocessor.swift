import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum ImagePreprocessor {
    static func preprocess(_ image: NSImage, targetWidth: Int = 576) -> NSImage {
        guard let enhanced = enhanceContrast(image) else { return image }
        return resizeToWidth(enhanced, width: targetWidth)
    }

    static func enhanceContrast(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.contrast = 1.2
        filter.brightness = 0.02
        filter.saturation = 0
        guard let output = filter.outputImage else { return image }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }

    static func resizeToWidth(_ image: NSImage, width: Int) -> NSImage {
        let aspect = image.size.height / max(image.size.width, 1)
        let height = max(1, CGFloat(width) * aspect)
        let newSize = NSSize(width: CGFloat(width), height: height)
        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }

    /// Convert any color/grayscale image to crisp pure black & white (for thermal logos / backgrounds).
    /// Uses Rec.709 luminance + Otsu threshold so soft color logos become sharp ink.
    static func toBinaryBlackWhite(_ image: NSImage, maxEdge: Int = 1200) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }

        let srcW = max(cg.width, 1)
        let srcH = max(cg.height, 1)
        let scale = min(1.0, Double(maxEdge) / Double(max(srcW, srcH)))
        let width = max(1, Int((Double(srcW) * scale).rounded()))
        let height = max(1, Int((Double(srcH) * scale).rounded()))

        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        guard let rgbCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        rgbCtx.interpolationQuality = .high
        rgbCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        rgbCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        rgbCtx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let ptr = rgbCtx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            return image
        }

        var hist = [Int](repeating: 0, count: 256)
        var luminance = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            let a = Int(ptr[o + 3])
            let y: UInt8
            if a < 16 {
                y = 255 // treat near-transparent as paper white
            } else {
                let r = Double(ptr[o])
                let g = Double(ptr[o + 1])
                let b = Double(ptr[o + 2])
                y = UInt8(min(255, max(0, (0.2126 * r + 0.7152 * g + 0.0722 * b).rounded())))
            }
            luminance[i] = y
            hist[Int(y)] += 1
        }

        let threshold = otsuThreshold(histogram: hist, total: width * height)

        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let outCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return image }
        guard let outPtr = outCtx.data?.bindMemory(to: UInt8.self, capacity: width * height) else {
            return image
        }
        for i in 0..<(width * height) {
            outPtr[i] = luminance[i] < threshold ? 0 : 255
        }
        guard let outCG = outCtx.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: outCG)
        let result = NSImage(size: NSSize(width: width, height: height))
        result.addRepresentation(rep)
        return result
    }

    /// Otsu's method: maximize between-class variance for a binary split.
    private static func otsuThreshold(histogram: [Int], total: Int) -> UInt8 {
        guard total > 0 else { return 128 }
        var sumAll = 0
        for t in 0..<256 {
            sumAll += t * histogram[t]
        }
        var sumB = 0
        var wB = 0
        var maxVar = -1.0
        var best = 128
        for t in 0..<256 {
            wB += histogram[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += t * histogram[t]
            let mB = Double(sumB) / Double(wB)
            let mF = Double(sumAll - sumB) / Double(wF)
            let diff = mB - mF
            let between = Double(wB) * Double(wF) * diff * diff
            if between > maxVar {
                maxVar = between
                best = t
            }
        }
        return UInt8(best)
    }
}
