import Foundation
import AppKit

enum ESCPOSAlign: UInt8 {
    case left = 0, center = 1, right = 2
}

enum ESCPOSBarcode: UInt8 {
    case code128 = 73
    case ean13 = 67
}

final class ESCPOSBuilder {
    private var data = Data()
    private let config: PrinterConfig
    private var isDoubleSize = false

    init(config: PrinterConfig = .default80mm) {
        self.config = config
    }

    private var effectiveColumns: Int {
        max(8, isDoubleSize ? config.columnsPerLine / 2 : config.columnsPerLine)
    }

    func build() -> Data { data }

    @discardableResult
    func initialize() -> Self {
        data.append(contentsOf: [0x1B, 0x40])
        if config.encoding == .gbk {
            data.append(contentsOf: [0x1C, 0x26])
            data.append(contentsOf: [0x1B, 0x74, 0x00])
        }
        return self
    }

    @discardableResult
    func setLineSpacing(_ dots: UInt8) -> Self {
        data.append(contentsOf: [0x1B, 0x33, dots])
        return self
    }

    @discardableResult
    func resetLineSpacing() -> Self {
        data.append(contentsOf: [0x1B, 0x32])
        return self
    }

    @discardableResult
    func align(_ align: ESCPOSAlign) -> Self {
        data.append(contentsOf: [0x1B, 0x61, align.rawValue])
        return self
    }

    @discardableResult
    func bold(_ on: Bool) -> Self {
        data.append(contentsOf: [0x1B, 0x45, on ? 1 : 0])
        return self
    }

    @discardableResult
    func textSize(normal: Bool) -> Self {
        applyTextSize(normal ? .normal : .double)
        return self
    }

    @discardableResult
    func applyTextSize(_ size: TextSize) -> Self {
        isDoubleSize = size == .double
        let mode: UInt8 = switch size {
        case .normal: 0x00
        case .tall: 0x01
        case .double: 0x11
        }
        // #region agent log
        DebugLog.write(
            hypothesisId: "A",
            location: "ESCPOSBuilder.applyTextSize",
            message: "text size command",
            data: ["size": size.rawValue, "gsMode": String(format: "0x%02X", mode)]
        )
        // #endregion
        data.append(contentsOf: [0x1D, 0x21, mode])
        return self
    }

    @discardableResult
    func reversePrint(_ on: Bool) -> Self {
        data.append(contentsOf: [0x1D, 0x42, on ? 1 : 0])
        return self
    }

    @discardableResult
    func text(_ string: String) -> Self {
        let maxCols = effectiveColumns
        let lines = ReceiptTextLayout.wrap(string, maxColumns: maxCols)
        for (index, line) in lines.enumerated() {
            if !line.isEmpty {
                appendEncoded(line)
            }
            if index < lines.count - 1 {
                data.append(0x0A)
            }
        }
        return self
    }

    private func appendEncoded(_ string: String) {
        switch config.encoding {
        case .utf8:
            if let encoded = string.data(using: .utf8) {
                data.append(encoded)
            }
        case .gbk:
            appendGBKPlain(string)
        }
    }

    /// Send raw GBK bytes without FS & / FS . mode toggles (avoids boundary corruption on many printers).
    private func appendGBKPlain(_ string: String) {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        guard let encoded = string.data(using: encoding) else { return }
        data.append(encoded)
    }

    @discardableResult
    func newline(_ count: Int = 1) -> Self {
        for _ in 0..<count { data.append(0x0A) }
        return self
    }

    @discardableResult
    func feed(lines: Int) -> Self {
        data.append(contentsOf: [0x1B, 0x64, UInt8(min(lines, 255))])
        return self
    }

    @discardableResult
    func line(char: Character = "-") -> Self {
        let width = config.dotsPerLine / 12
        return text(String(repeating: char, count: width)).newline()
    }

    @discardableResult
    func tableRow(left: String, right: String, width: Int? = nil) -> Self {
        let totalWidth = width ?? effectiveColumns
        let rightWidth = ReceiptTextLayout.displayWidth(right)
        let leftMax = max(2, totalWidth - rightWidth - 1)
        let wrappedLeft = ReceiptTextLayout.wrap(left, maxColumns: leftMax)
        for (index, leftPart) in wrappedLeft.enumerated() {
            if index == wrappedLeft.count - 1 {
                let leftW = ReceiptTextLayout.displayWidth(leftPart)
                let padding = max(1, totalWidth - leftW - rightWidth)
                appendEncoded(leftPart + String(repeating: " ", count: padding) + right)
            } else {
                appendEncoded(leftPart)
            }
            data.append(0x0A)
        }
        return self
    }

    @discardableResult
    func tableRowWithHighlight(
        left: String,
        rightPrefix: String,
        highlight: String,
        leftBold: Bool = false,
        leftSize: TextSize = .normal
    ) -> Self {
        let highlightText = highlight.isEmpty ? "" : "  \(highlight)  "
        let leftCols = columnWidth(left, size: leftSize)
        let rightWidth = ReceiptTextLayout.displayWidth(rightPrefix) + ReceiptTextLayout.displayWidth(highlightText)
        let padding = max(1, config.columnsPerLine - leftCols - rightWidth)

        bold(leftBold).applyTextSize(leftSize)
        appendEncoded(left)
        bold(false).applyTextSize(.normal)
        appendEncoded(String(repeating: " ", count: padding) + rightPrefix)
        if !highlightText.isEmpty {
            reversePrint(true)
            appendEncoded(highlightText)
            reversePrint(false)
        }
        // #region agent log
        DebugLog.write(
            hypothesisId: "B",
            location: "ESCPOSBuilder.tableRowWithHighlight",
            message: "mixed row",
            data: [
                "left": String(left.prefix(20)),
                "leftSize": leftSize.rawValue,
                "leftBold": leftBold ? "1" : "0",
                "highlight": highlightText,
                "padding": String(padding)
            ]
        )
        // #endregion
        data.append(0x0A)
        return self
    }

    private func columnWidth(_ text: String, size: TextSize) -> Int {
        let base = ReceiptTextLayout.displayWidth(text)
        return size == .double ? base * 2 : base
    }

    @discardableResult
    func barcode(
        type: ESCPOSBarcode,
        content: String,
        height: UInt8 = 80,
        width: UInt8 = 2,
        printHRI: Bool = true
    ) -> Self {
        align(.center)
        data.append(contentsOf: [0x1D, 0x68, height])
        data.append(contentsOf: [0x1D, 0x48, printHRI ? 2 : 0])
        data.append(contentsOf: [0x1D, 0x77, min(width, 6)])
        data.append(contentsOf: [0x1D, 0x6B, type.rawValue, UInt8(content.utf8.count)])
        if let bytes = content.data(using: .ascii) {
            data.append(bytes)
        }
        // #region agent log
        DebugLog.write(
            hypothesisId: "C",
            location: "ESCPOSBuilder.barcode",
            message: "barcode command",
            data: [
                "height": String(height),
                "width": String(width),
                "printHRI": printHRI ? "1" : "0",
                "content": String(content.prefix(30))
            ]
        )
        // #endregion
        newline()
        return self
    }

    @discardableResult
    func barcode(type: ESCPOSBarcode, content: String, height: UInt8 = 80) -> Self {
        barcode(type: type, content: content, height: height, width: 2, printHRI: true)
    }

    @discardableResult
    func qrCode(_ content: String) -> Self {
        qrCodeImage(content)
    }

    @discardableResult
    func qrCodeImage(_ content: String, maxWidth: Int? = nil) -> Self {
        let qrSize = maxWidth ?? min(config.dotsPerLine, 200)
        guard let qrImage = BarcodeGenerator.makeQRCode(content, size: qrSize) else {
            return self
        }
        return self.image(qrImage, maxWidth: qrSize)
    }

    @discardableResult
    func image(_ nsImage: NSImage, maxWidth: Int? = nil) -> Self {
        let targetWidth = maxWidth ?? config.dotsPerLine
        guard let raster = BarcodeGenerator.rasterizeImage(nsImage, maxWidth: targetWidth) else { return self }
        appendRasterImage(raster)
        return self
    }

    private func appendRasterImage(_ raster: RasterImage) {
        let widthBytes = raster.widthBytes
        let xL = UInt8(widthBytes & 0xFF)
        let xH = UInt8((widthBytes >> 8) & 0xFF)
        let yL = UInt8(raster.height & 0xFF)
        let yH = UInt8((raster.height >> 8) & 0xFF)
        data.append(contentsOf: [0x1D, 0x76, 0x30, 0x00, xL, xH, yL, yH])
        data.append(raster.data)
        feed(lines: 1)
    }

    @discardableResult
    func cut() -> Self {
        if config.cutPaper {
            feed(lines: config.feedLinesBeforeCut)
            data.append(contentsOf: [0x1D, 0x56, 0x00])
        }
        return self
    }
}

struct RasterImage {
    let width: Int
    let height: Int
    let widthBytes: Int
    let data: Data
}
