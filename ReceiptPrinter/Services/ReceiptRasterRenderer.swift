import AppKit
import Foundation

/// Layout constants for 80mm thermal output (203 DPI → 576 dots typical).
struct ReceiptLayoutConfiguration: Equatable {
    let dotsPerLine: Int
    let horizontalMargin: CGFloat
    let verticalMargin: CGFloat
    let dpi: Int

    static func from(_ config: PrinterConfig, dpi: Int = 203) -> ReceiptLayoutConfiguration {
        ReceiptLayoutConfiguration(
            dotsPerLine: config.dotsPerLine,
            horizontalMargin: 8,
            verticalMargin: 8,
            dpi: dpi
        )
    }

    var contentWidth: CGFloat { CGFloat(dotsPerLine) - horizontalMargin * 2 }

    var printableWidthMM: Double {
        Double(dotsPerLine) / (Double(dpi) / 25.4)
    }
}

/// Drawn separator attachment for the rich-text editor.
/// Print/preview convert this into column-matched dash lines via `RichTextPrintRenderer.layoutLines`.
final class ReceiptDividerAttachment: NSTextAttachment {
    enum Style: String {
        case solid
        case dashed
    }

    let style: Style
    let lineWidth: CGFloat

    init(style: Style, lineWidth: CGFloat) {
        self.style = style
        self.lineWidth = lineWidth
        super.init(data: nil, ofType: nil)
        let height: CGFloat = 14
        bounds = CGRect(x: 0, y: -4, width: lineWidth, height: height)
        image = Self.makeEditorImage(style: style, width: lineWidth, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func makeEditorImage(style: Style, width: CGFloat, height: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let path = NSBezierPath()
            let y = rect.midY
            path.lineWidth = 2
            path.lineCapStyle = .butt
            switch style {
            case .solid:
                path.move(to: NSPoint(x: rect.minX, y: y))
                path.line(to: NSPoint(x: rect.maxX, y: y))
            case .dashed:
                path.setLineDash([8, 6], count: 2, phase: 0)
                path.move(to: NSPoint(x: rect.minX, y: y))
                path.line(to: NSPoint(x: rect.maxX, y: y))
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
    }
}
