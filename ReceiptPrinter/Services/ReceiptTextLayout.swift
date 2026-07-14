import Foundation

enum ReceiptTextLayout {
    /// When true, printable ASCII is counted as 2 columns (matches POS fullwidth Latin under Chinese mode).
    static func displayWidth(_ string: String, asciiAsDoubleWidth: Bool = false) -> Int {
        string.unicodeScalars.reduce(0) { sum, scalar in
            sum + columnWidth(scalar.value, asciiAsDoubleWidth: asciiAsDoubleWidth)
        }
    }

    static func wrap(_ text: String, maxColumns: Int, asciiAsDoubleWidth: Bool = false) -> [String] {
        guard maxColumns > 0 else { return [text] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty {
                lines.append("")
                continue
            }
            var current = ""
            var currentWidth = 0
            for char in paragraph {
                let charWidth = char.unicodeScalars.first.map {
                    columnWidth($0.value, asciiAsDoubleWidth: asciiAsDoubleWidth)
                } ?? 1
                if currentWidth + charWidth > maxColumns, !current.isEmpty {
                    lines.append(current)
                    current = String(char)
                    currentWidth = charWidth
                } else {
                    current.append(char)
                    currentWidth += charWidth
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        return lines.isEmpty ? [""] : lines
    }

    private static func columnWidth(_ scalar: UInt32, asciiAsDoubleWidth: Bool) -> Int {
        if scalar > 0x7F { return 2 }
        if asciiAsDoubleWidth, scalar >= 0x20, scalar <= 0x7E { return 2 }
        return 1
    }
}
