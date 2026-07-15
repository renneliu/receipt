import AppKit
import SwiftUI

/// Receipt body editor: wrap-to-columns, no horizontal pan, paste as plain text.
final class ReceiptEditorTextView: NSTextView {
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func preferredPasteboardType(
        from availableTypes: [NSPasteboard.PasteboardType],
        restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?
    ) -> NSPasteboard.PasteboardType? {
        if availableTypes.contains(.string) { return .string }
        return super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let plain = pb.string(forType: .string) else { return }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: plain) else { return }
        let attributed = NSAttributedString(string: plain, attributes: typingAttributes)
        textStorage?.beginEditing()
        textStorage?.replaceCharacters(in: range, with: attributed)
        textStorage?.endEditing()
        setSelectedRange(NSRange(location: range.location + (plain as NSString).length, length: 0))
        didChangeText()
    }

    /// Keep the clip view locked horizontally — selection drag must not pan the editor sideways.
    override func scrollRangeToVisible(_ charRange: NSRange) {
        guard let layoutManager, let textContainer,
              let scrollView = enclosingScrollView else {
            super.scrollRangeToVisible(charRange)
            return
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect = rect.insetBy(dx: 0, dy: -4)
        rect.origin = rect.origin.applying(
            .init(translationX: textContainerOrigin.x, y: textContainerOrigin.y)
        )

        let visible = visibleRect
        var target = visible
        if rect.minY < visible.minY {
            target.origin.y = rect.minY
        } else if rect.maxY > visible.maxY {
            target.origin.y = rect.maxY - visible.height
        }
        target.origin.x = 0
        target.size = visible.size
        if target != visible {
            scrollToVisible(target)
        }
        // Force horizontal origin back if AppKit nudged it.
        var origin = scrollView.contentView.bounds.origin
        if abs(origin.x) > 0.5 {
            origin.x = 0
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

struct AttributedTextView: NSViewRepresentable {
    @Binding var attributedString: NSAttributedString
    var printerConfig: PrinterConfig = .default80mm
    /// Controls column-grid width so soft wrap matches ESC/POS print columns.
    var editorFontSize: CGFloat = AttributedTextView.defaultFontSize
    /// When true, text view is transparent so a canvas background image can show through.
    var clearCanvasBackground: Bool = false
    var onTextViewReady: ((NSTextView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay
        applyBackground(scrollView: scrollView, textView: nil)

        let textView = ReceiptEditorTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        applyBackground(scrollView: scrollView, textView: textView)
        // Inset + lineFragmentPadding keep large CJK glyphs from clipping on the left edge.
        textView.textContainerInset = NSSize(width: Self.editorInsetWidth, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.height]
        textView.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = Self.editorLineFragmentPadding
        textView.typingAttributes = Self.defaultTypingAttributes(fontSize: editorFontSize)
        textView.defaultParagraphStyle = Self.defaultParagraphStyle()
        textView.textStorage?.setAttributedString(attributedString)

        scrollView.documentView = textView
        applyPaperLayout(to: textView, scrollView: scrollView)

        context.coordinator.textView = textView
        onTextViewReady?(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        applyBackground(scrollView: scrollView, textView: textView)
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

    private func applyBackground(scrollView: NSScrollView, textView: NSTextView?) {
        if clearCanvasBackground {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            textView?.drawsBackground = false
            textView?.backgroundColor = .clear
        } else {
            scrollView.drawsBackground = true
            scrollView.backgroundColor = NSColor.windowBackgroundColor
            textView?.drawsBackground = true
            textView?.backgroundColor = .white
        }
    }

    private func applyPaperLayout(to textView: NSTextView, scrollView: NSScrollView) {
        let contentWidth = Self.editorContentWidth(config: printerConfig, fontSize: editorFontSize)
        let padding = Self.editorLineFragmentPadding
        let insetW = textView.textContainerInset.width
        // Padding is inside the container — expand container so wrap width stays = contentWidth.
        let containerWidth = contentWidth + padding * 2
        let paperWidth = containerWidth + insetW * 2
        textView.textContainer?.lineFragmentPadding = padding
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        let height = max(textView.frame.height, scrollView.contentSize.height)
        textView.frame = NSRect(x: 0, y: 0, width: paperWidth, height: height)
        textView.minSize = NSSize(width: paperWidth, height: 0)
        // Cap width so the document never exceeds paper — prevents horizontal pan on selection.
        textView.maxSize = NSSize(width: paperWidth, height: CGFloat.greatestFiniteMagnitude)

        if abs(scrollView.contentView.bounds.origin.x) > 0.5 {
            var origin = scrollView.contentView.bounds.origin
            origin.x = 0
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    static let editorInsetWidth: CGFloat = 12
    static let editorLineFragmentPadding: CGFloat = 6

    /// Width of one print line in editor points (matches ESC/POS column count for this font size).
    static func editorContentWidth(config: PrinterConfig, fontSize: CGFloat) -> CGFloat {
        let size = RichTextPrintRenderer.textSize(forPointSize: fontSize)
        let cols = RichTextPrintRenderer.effectiveColumns(for: size, config: config)
        let font = editorFont(ofSize: fontSize)
        let unit = ("M" as NSString).size(withAttributes: [.font: font]).width
        return ceil(unit * CGFloat(cols))
    }

    static func editorPaperWidth(config: PrinterConfig, fontSize: CGFloat) -> CGFloat {
        editorContentWidth(config: config, fontSize: fontSize)
            + editorLineFragmentPadding * 2
            + editorInsetWidth * 2
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
    /// Default editor point size = 2× normal → `TextSize.double` (GS ! width+height ×2).
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
