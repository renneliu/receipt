import Foundation
import CoreGraphics

/// Auto-incrementing stamp on the Quick Print canvas (printed as a text overlay).
struct QuickPrintAutoNumber: Codable, Equatable {
    var enabled: Bool = false
    /// Starting display value, e.g. `"01"` or `"A01"`. Trailing digits increment.
    var startValue: String = "01"
    var fontSize: CGFloat = AttributedTextView.defaultFontSize
    var frame: SequencePlaceholderFrame = SequencePlaceholderFrame(x: 200, y: 16, width: 96, height: 44)
    /// How many tickets to print in one batch (each page keeps body/media; only this number changes).
    var batchCount: Int = 1

    static let minBatch = 1
    static let maxBatch = 200
    static let minFontSize: CGFloat = 10
    static let maxFontSize: CGFloat = 72
    /// Preset font sizes for the picker (pt).
    static let fontSizeChoices: [CGFloat] = [14, 18, 24, 28, 32, 40, 48, 56, 64, 72]

    mutating func clampBatch() {
        batchCount = min(Self.maxBatch, max(Self.minBatch, batchCount))
    }

    mutating func clampFontSize() {
        fontSize = min(Self.maxFontSize, max(Self.minFontSize, fontSize))
    }

    /// Value for page `offset` (0-based) from `startValue`.
    func formattedValue(offset: Int) -> String {
        Self.format(start: startValue, offset: max(0, offset))
    }

    /// Advance stored start value after printing `count` tickets.
    mutating func advanceAfterPrint(count: Int) {
        guard count > 0 else { return }
        startValue = formattedValue(offset: count)
    }

    static func format(start: String, offset: Int) -> String {
        let chars = Array(start)
        var digitStart = chars.count
        while digitStart > 0, chars[digitStart - 1].isNumber {
            digitStart -= 1
        }
        let prefix = String(chars[..<digitStart])
        let digits = String(chars[digitStart...])
        guard !digits.isEmpty, let base = Int(digits) else {
            if offset == 0 { return start }
            return start.isEmpty ? "\(offset)" : "\(start)\(offset)"
        }
        let width = digits.count
        let value = base + offset
        return prefix + String(format: "%0\(width)lld", Int64(value))
    }
}
