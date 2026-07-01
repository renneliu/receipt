import AppKit
import CoreImage

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
}
