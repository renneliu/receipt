import Foundation

enum ReceiptTextLayout {
    /// CJK and fullwidth count as 2 columns; ASCII as 1.
    static func displayWidth(_ string: String) -> Int {
        string.unicodeScalars.reduce(0) { sum, scalar in
            sum + (scalar.value > 0x7F ? 2 : 1)
        }
    }

    static func wrap(_ text: String, maxColumns: Int) -> [String] {
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
                let charWidth = char.unicodeScalars.first.map { $0.value > 0x7F ? 2 : 1 } ?? 1
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
}
