import AppKit
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

    /// Keep a single line no wider than `maxColumns` (CJK counts as 2), clipping the
    /// overflow. Any text after a hard line break is dropped (single-line only).
    static func clip(_ text: String, maxColumns: Int, asciiAsDoubleWidth: Bool = false) -> String {
        guard maxColumns > 0 else { return "" }
        let firstLine = text.components(separatedBy: "\n").first ?? text
        var out = ""
        var width = 0
        for ch in firstLine {
            let w = ch.unicodeScalars.first.map {
                columnWidth($0.value, asciiAsDoubleWidth: asciiAsDoubleWidth)
            } ?? 1
            if width + w > maxColumns { break }
            out.append(ch)
            width += w
        }
        return out
    }

    /// Wrap to an optical width (points). Latin words stay intact when possible; CJK breaks per glyph.
    static func wrapFittingWidth(
        _ text: String,
        maxWidth: CGFloat,
        fontSize: CGFloat,
        preserveEnglishWords: Bool = true
    ) -> [String] {
        let limit = max(8, maxWidth)
        let font = NSFont.monospacedSystemFont(ofSize: max(8, fontSize), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func measure(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: attrs).width
        }

        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty {
                lines.append("")
                continue
            }
            let tokens = preserveEnglishWords ? tokenize(paragraph) : paragraph.map { String($0) }
            var current = ""
            for token in tokens {
                let candidate = current + token
                if measure(candidate) <= limit || current.isEmpty {
                    if measure(token) > limit && current.isEmpty {
                        // Oversized token: hard-split by character.
                        for ch in token {
                            let piece = String(ch)
                            if measure(current + piece) <= limit || current.isEmpty {
                                current += piece
                            } else {
                                lines.append(current)
                                current = piece
                            }
                        }
                    } else {
                        current = candidate
                    }
                } else {
                    lines.append(current)
                    if measure(token) <= limit {
                        current = token
                    } else {
                        current = ""
                        for ch in token {
                            let piece = String(ch)
                            if measure(current + piece) <= limit || current.isEmpty {
                                current += piece
                            } else {
                                lines.append(current)
                                current = piece
                            }
                        }
                    }
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        return lines.isEmpty ? [""] : lines
    }

    /// Fill a divider line to `columns` printer columns (CJK display width).
    static func dividerLine(columns: Int, dashed: Bool) -> String {
        guard columns > 0 else { return "" }
        var s = ""
        let fill = dashed ? "- " : "-"
        while displayWidth(s) < columns {
            s += fill
        }
        var out = ""
        var width = 0
        for ch in s {
            let w = displayWidth(String(ch))
            if width + w > columns { break }
            out.append(ch)
            width += w
        }
        return out
    }

    /// Latin alphanumeric runs stay as one token; whitespace kept; other scalars (CJK etc.) are single glyphs.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace {
                tokens.append(String(ch))
                i = text.index(after: i)
                continue
            }
            if isWordChar(ch) {
                var j = text.index(after: i)
                while j < text.endIndex, isWordChar(text[j]) {
                    j = text.index(after: j)
                }
                tokens.append(String(text[i..<j]))
                i = j
                continue
            }
            tokens.append(String(ch))
            i = text.index(after: i)
        }
        return tokens
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        guard ch.isASCII else { return false }
        return ch.isLetter || ch.isNumber || ch == "'" || ch == "-"
    }

    private static func columnWidth(_ scalar: UInt32, asciiAsDoubleWidth: Bool) -> Int {
        if scalar > 0x7F { return 2 }
        if asciiAsDoubleWidth, scalar >= 0x20, scalar <= 0x7E { return 2 }
        return 1
    }
}
