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
        // This POS-80 prints Chinese correctly in GBK + FS & text mode.
        // Whole-page GS v 0 is often misread as text → garbled output (runtime evidence).
        if config.encoding == .gbk {
            data.append(contentsOf: [0x1C, 0x26]) // FS & enable Chinese character mode
            data.append(contentsOf: [0x1B, 0x74, 0x00]) // ESC t 0
        }
        return self
    }

    /// Reset without Chinese character mode — used before GS v 0 raster (when supported).
    @discardableResult
    func initializeForRaster() -> Self {
        data.append(contentsOf: [0x1B, 0x40])
        data.append(contentsOf: [0x1C, 0x2E])
        data.append(contentsOf: [0x1B, 0x40])
        return self
    }

    @discardableResult
    func resetStyle() -> Self {
        underline(false)
        reversePrint(false)
        bold(false)
        applyTextSize(.normal)
        align(.left)
        return self
    }

    private static func rowNeedsSplitLayout(leftSize: TextSize, rightSize: TextSize) -> Bool {
        leftSize == .double || rightSize == .double || leftSize != rightSize
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
        data.append(contentsOf: [0x1D, 0x21, mode])
        return self
    }

    @discardableResult
    func underline(_ on: Bool) -> Self {
        data.append(contentsOf: [0x1B, 0x2D, on ? 1 : 0])
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

    /// Encode a single already-wrapped line (no additional wrap). Used by WYSIWYG quick-print.
    @discardableResult
    func appendRawTextLine(_ string: String) -> Self {
        if !string.isEmpty {
            appendEncoded(string)
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

    /// Segment halfwidth ASCII / CJK on the same LF line with FS . / FS &.
    private func appendGBKPlain(_ string: String) {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        let cleaned = String(string.unicodeScalars.filter { $0.value != 0xFFFC })
        guard !cleaned.isEmpty else { return }

        for segment in Self.scriptRuns(cleaned) {
            let isCJK = segment.unicodeScalars.contains { $0.value > 0x7F }
            data.append(contentsOf: isCJK ? [0x1C, 0x26] : [0x1C, 0x2E])
            if let encoded = segment.data(using: encoding) {
                data.append(encoded)
            }
        }
    }

    /// Group characters into ASCII-only vs CJK/fullwidth runs (spaces stay with the run).
    private static func scriptRuns(_ string: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var currentIsCJK: Bool?
        for scalar in string.unicodeScalars {
            let isCJK = scalar.value > 0x7F
            if let cur = currentIsCJK, cur != isCJK, !current.isEmpty {
                runs.append(current)
                current = ""
            }
            currentIsCJK = isCJK
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { runs.append(current) }
        return runs.isEmpty ? [string] : runs
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
        leftSize: TextSize = .normal,
        rightBold: Bool = false,
        rightSize: TextSize = .normal
    ) -> Self {
        let highlightText = highlight.isEmpty ? "" : "  \(highlight)  "

        if Self.rowNeedsSplitLayout(leftSize: leftSize, rightSize: rightSize) {
            align(.left)
            bold(leftBold).applyTextSize(leftSize)
            appendEncoded(left)
            data.append(0x0A)
            resetStyle()

            align(.right)
            bold(rightBold).applyTextSize(rightSize)
            appendEncoded(rightPrefix)
            if !highlightText.isEmpty {
                reversePrint(true)
                appendEncoded(highlightText)
                reversePrint(false)
            }
            data.append(0x0A)
            resetStyle()
            return self
        }

        let leftCols = ReceiptTextLayout.displayWidth(left)
        let rightCols = ReceiptTextLayout.displayWidth(rightPrefix)
            + (highlightText.isEmpty ? 0 : ReceiptTextLayout.displayWidth(highlightText))
        let padding = max(1, effectiveColumns - leftCols - rightCols)

        align(.left)
        bold(leftBold).applyTextSize(leftSize)
        appendEncoded(left)
        bold(false).applyTextSize(.normal)
        appendEncoded(String(repeating: " ", count: padding))
        bold(rightBold).applyTextSize(rightSize)
        appendEncoded(rightPrefix)
        if !highlightText.isEmpty {
            reversePrint(true)
            appendEncoded(highlightText)
            reversePrint(false)
        }
        data.append(0x0A)
        resetStyle()
        return self
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
        // Cancel Chinese character mode before bit-image; otherwise clones often print raster as GBK text.
        data.append(contentsOf: [0x1C, 0x2E])
        let widthBytes = raster.widthBytes
        let xL = UInt8(widthBytes & 0xFF)
        let xH = UInt8((widthBytes >> 8) & 0xFF)
        let yL = UInt8(raster.height & 0xFF)
        let yH = UInt8((raster.height >> 8) & 0xFF)
        // GS v 0: xL/xH = bytes per row, yL/yH = number of rows. Payload MUST be exactly
        // widthBytes*height, else the printer reads trailing image bytes as commands (garbage).
        let expectedRasterBytes = widthBytes * raster.height
        assert(expectedRasterBytes == raster.data.count, "GS v 0 raster byte count mismatch")
        data.append(contentsOf: [0x1D, 0x76, 0x30, 0x00, xL, xH, yL, yH])
        data.append(raster.data)
        feed(lines: 1)
    }

    @discardableResult
    func cut(feedLines override: Int? = nil) -> Self {
        if config.cutPaper {
            let lines = max(1, min(override ?? config.feedLinesBeforeCut, 255))
            feed(lines: lines)
            // Full cut (GS V 0) — works on this POS-80 after text jobs.
            data.append(contentsOf: [0x1D, 0x56, 0x00])
        }
        return self
    }

    /// Paper advance for dedicated 「走纸」.
    /// Empty LFs alone are unreliable; print a space each line so the head actually advances.
    @discardableResult
    func feedPaperAction(lines: Int) -> Self {
        let n = max(1, min(lines, 40))
        for _ in 0..<n {
            appendEncoded(" ")
            data.append(0x0A)
        }
        feed(lines: n)
        return self
    }

    /// Dedicated 「切纸」: advance then a single full cut (GS V 0).
    /// Multiple cut variants in one job caused repeated cuts on POS-80 (log evidence).
    @discardableResult
    func cutPaperAction(feedLines: Int = 12) -> Self {
        let n = max(12, min(feedLines, 40))
        appendEncoded(" ")
        newline(2)
        feed(lines: n)
        data.append(contentsOf: [0x1D, 0x56, 0x00])
        return self
    }
}

struct RasterImage {
    let width: Int
    let height: Int
    let widthBytes: Int
    let data: Data
}
