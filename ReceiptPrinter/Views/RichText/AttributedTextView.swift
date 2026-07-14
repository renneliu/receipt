import AppKit
import SwiftUI

struct AttributedTextView: NSViewRepresentable {
    @Binding var attributedString: NSAttributedString
    var printerConfig: PrinterConfig = .default80mm
    /// Controls column-grid width so soft wrap matches ESC/POS print columns.
    var editorFontSize: CGFloat = AttributedTextView.defaultFontSize
    var onTextViewReady: ((NSTextView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.typingAttributes = Self.defaultTypingAttributes(fontSize: editorFontSize)
        textView.defaultParagraphStyle = Self.defaultParagraphStyle()
        textView.textStorage?.setAttributedString(attributedString)

        applyPaperLayout(to: textView, scrollView: scrollView)

        context.coordinator.textView = textView
        onTextViewReady?(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        applyPaperLayout(to: textView, scrollView: scrollView)

        var typing = textView.typingAttributes
        let currentFont = (typing[.font] as? NSFont) ?? Self.editorFont(ofSize: editorFontSize)
        if abs(currentFont.pointSize - editorFontSize) > 0.5, textView.selectedRange().length == 0 {
            typing[.font] = Self.editorFont(ofSize: editorFontSize)
            textView.typingAttributes = typing
        }

        if context.coordinator.isUpdatingFromSwiftUI { return }
        if textView.attributedString() != attributedString {
            context.coordinator.isUpdatingFromView = true
            textView.textStorage?.setAttributedString(attributedString)
            context.coordinator.isUpdatingFromView = false
        }
    }

    private func applyPaperLayout(to textView: NSTextView, scrollView: NSScrollView) {
        let contentWidth = Self.editorContentWidth(config: printerConfig, fontSize: editorFontSize)
        let inset = textView.textContainerInset.width * 2
        let paperWidth = contentWidth + inset
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        let frame = textView.frame
        textView.frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: paperWidth, height: max(frame.height, scrollView.contentSize.height))
        textView.minSize = NSSize(width: paperWidth, height: 0)
        textView.maxSize = NSSize(width: paperWidth, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Width of one print line in editor points (matches ESC/POS column count for this font size).
    static func editorContentWidth(config: PrinterConfig, fontSize: CGFloat) -> CGFloat {
        let size = RichTextPrintRenderer.textSize(forPointSize: fontSize)
        let cols = RichTextPrintRenderer.effectiveColumns(for: size, config: config)
        let font = editorFont(ofSize: fontSize)
        let unit = ("M" as NSString).size(withAttributes: [.font: font]).width
        return ceil(unit * CGFloat(cols))
    }

    static func editorPaperWidth(config: PrinterConfig, fontSize: CGFloat) -> CGFloat {
        editorContentWidth(config: config, fontSize: fontSize) + 20
    }

    static func editorFont(ofSize size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func defaultParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineBreakMode = .byCharWrapping
        style.alignment = .left
        return style
    }

    static func defaultTypingAttributes(fontSize: CGFloat = defaultFontSize) -> [NSAttributedString.Key: Any] {
        [
            .font: editorFont(ofSize: fontSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: defaultParagraphStyle()
        ]
    }

    // MARK: - Centralized default receipt style (single source of truth)
    //
    // Requirement: default text prints at 2× normal size.
    // `normalFontSize` is the 1× baseline; `defaultFontSize` = 2× baseline and is the size
    // applied to new text, typing, plain-text loads, preview, and print. It maps to
    // `TextSize.double` via `RichTextPrintRenderer.textSize(forPointSize:)`.
    static let normalFontSize: CGFloat = 14
    static let defaultWidthMultiplier: CGFloat = 2
    static let defaultHeightMultiplier: CGFloat = 2
    /// Default editor point size = 2× normal → `TextSize.double` (GS ! double-width & double-height).
    static let defaultFontSize: CGFloat = normalFontSize * defaultHeightMultiplier

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AttributedTextView
        weak var textView: NSTextView?
        var isUpdatingFromView = false
        var isUpdatingFromSwiftUI = false

        init(_ parent: AttributedTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromView, let textView else { return }
            isUpdatingFromSwiftUI = true
            parent.attributedString = textView.attributedString()
            isUpdatingFromSwiftUI = false
        }
    }
}
