import AppKit
import SwiftUI

/// Receipt body editor: wrap-to-columns, no horizontal pan, paste as plain text.
final class ReceiptEditorTextView: NSTextView {
    /// When set, vertical `scrollRangeToVisible` is suppressed (outer SwiftUI ScrollView owns scroll).
    var suppressInternalVerticalScroll = false

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
        if suppressInternalVerticalScroll { return }
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
        var origin = scrollView.contentView.bounds.origin
        if abs(origin.x) > 0.5 {
            origin.x = 0
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// Container: either embeds a plain NSTextView (sequence page) or an NSScrollView (quick print).
final class AttributedTextHostView: NSView {
    let textView: ReceiptEditorTextView
    private(set) var scrollView: NSScrollView?
    var embedsWithoutScroll = false

    init(textView: ReceiptEditorTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func installEmbeddedLayout() {
        scrollView?.removeFromSuperview()
        scrollView = nil
        textView.removeFromSuperview()
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.autoresizingMask = [.width, .height]
        textView.frame = bounds
        addSubview(textView)
        embedsWithoutScroll = true
        textView.suppressInternalVerticalScroll = true
        // Allow layout taller than the host; outer SwiftUI ScrollView owns scrolling.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
    }

    func installScrollLayout() {
        textView.removeFromSuperview()
        let scroll = scrollView ?? NSScrollView(frame: bounds)
        scroll.translatesAutoresizingMaskIntoConstraints = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        if scroll.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            addSubview(scroll)
        }
        scrollView = scroll
        embedsWithoutScroll = false
        textView.suppressInternalVerticalScroll = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.height]
    }

    override func layout() {
        super.layout()
        if embedsWithoutScroll {
            textView.frame = bounds
        } else {
            scrollView?.frame = bounds
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
    /// Embed NSTextView without an inner NSScrollView so outer SwiftUI ScrollView
    /// scrolls text + overlays together (Excel sequence page).
    var disablesInternalVerticalScroll: Bool = false
    /// Reports laid-out content height (points), including textContainerInset.
    var onLaidOutContentHeight: ((CGFloat) -> Void)?
    var onTextViewReady: ((NSTextView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> AttributedTextHostView {
        let textView = ReceiptEditorTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: Self.editorInsetWidth, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = Self.editorLineFragmentPadding
        textView.typingAttributes = Self.defaultTypingAttributes(fontSize: editorFontSize)
        textView.defaultParagraphStyle = Self.defaultParagraphStyle()
        textView.textStorage?.setAttributedString(attributedString)

        let host = AttributedTextHostView(textView: textView)
        if disablesInternalVerticalScroll {
            host.installEmbeddedLayout()
        } else {
            host.installScrollLayout()
        }
        applyBackground(host: host)
        applyPaperLayout(host: host)

        context.coordinator.textView = textView
        onTextViewReady?(textView)
        return host
    }

    func updateNSView(_ host: AttributedTextHostView, context: Context) {
        let textView = host.textView
        context.coordinator.parent = self

        if disablesInternalVerticalScroll != host.embedsWithoutScroll {
            if disablesInternalVerticalScroll {
                host.installEmbeddedLayout()
            } else {
                host.installScrollLayout()
            }
        }

        applyBackground(host: host)
        applyPaperLayout(host: host)

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
        applyPaperLayout(host: host)
        if disablesInternalVerticalScroll {
            context.coordinator.reportLaidOutHeight(from: textView)
        }
    }

    private func applyBackground(host: AttributedTextHostView) {
        let textView = host.textView
        if clearCanvasBackground {
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.scrollView?.drawsBackground = false
            host.scrollView?.backgroundColor = .clear
            textView.drawsBackground = false
            textView.backgroundColor = .clear
        } else {
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            host.scrollView?.drawsBackground = true
            host.scrollView?.backgroundColor = NSColor.windowBackgroundColor
            textView.drawsBackground = true
            textView.backgroundColor = .white
        }
    }

    private func applyPaperLayout(host: AttributedTextHostView) {
        let textView = host.textView
        let contentWidth = Self.editorContentWidth(config: printerConfig, fontSize: editorFontSize)
        let padding = Self.editorLineFragmentPadding
        let insetW = textView.textContainerInset.width
        let insetH = textView.textContainerInset.height
        let containerWidth = contentWidth + padding * 2
        let paperWidth = containerWidth + insetW * 2
        textView.textContainer?.lineFragmentPadding = padding
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        if host.embedsWithoutScroll {
            // Host frame comes from SwiftUI documentHeight; do not clamp maxSize to it or
            // NSTextView clips the last soft-wrapped lines even when the outer ScrollView grows.
            let h = max(host.bounds.height, 1)
            textView.frame = NSRect(x: 0, y: 0, width: paperWidth, height: h)
            textView.minSize = NSSize(width: paperWidth, height: h)
            textView.maxSize = NSSize(width: paperWidth, height: CGFloat.greatestFiniteMagnitude)
            if let lm = textView.layoutManager, let tc = textView.textContainer {
                lm.ensureLayout(for: tc)
                _ = insetH
            }
        } else if let scrollView = host.scrollView {
            let height = max(textView.frame.height, scrollView.contentSize.height)
            textView.frame = NSRect(x: 0, y: 0, width: paperWidth, height: height)
            textView.minSize = NSSize(width: paperWidth, height: 0)
            textView.maxSize = NSSize(width: paperWidth, height: CGFloat.greatestFiniteMagnitude)
            if abs(scrollView.contentView.bounds.origin.x) > 0.5 {
                var origin = scrollView.contentView.bounds.origin
                origin.x = 0
                scrollView.contentView.setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// Layout height of attributed text at the editor column width (points).
    static func measureEditorHeight(
        attributedString: NSAttributedString,
        config: PrinterConfig,
        fontSize: CGFloat
    ) -> CGFloat {
        let contentWidth = editorContentWidth(config: config, fontSize: fontSize)
        let padding = editorLineFragmentPadding
        let containerWidth = contentWidth + padding * 2
        let storage = NSTextStorage(attributedString: attributedString)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return max(40, ceil(used.height + 24))
    }

    static let editorInsetWidth: CGFloat = 12
    static let editorLineFragmentPadding: CGFloat = 6

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

    static let normalFontSize: CGFloat = 14
    static let defaultWidthMultiplier: CGFloat = 2
    static let defaultHeightMultiplier: CGFloat = 2
    static let defaultFontSize: CGFloat = normalFontSize * defaultHeightMultiplier

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AttributedTextView
        weak var textView: NSTextView?
        var isUpdatingFromView = false
        var isUpdatingFromSwiftUI = false
        private var lastReportedHeight: CGFloat = -1

        init(_ parent: AttributedTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromView, let textView else { return }
            isUpdatingFromSwiftUI = true
            parent.attributedString = textView.attributedString()
            isUpdatingFromSwiftUI = false
            reportLaidOutHeight(from: textView)
        }

        func reportLaidOutHeight(from textView: NSTextView) {
            guard parent.disablesInternalVerticalScroll,
                  let lm = textView.layoutManager,
                  let tc = textView.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let inset = textView.textContainerInset.height
            let contentH = ceil(used.height + inset * 2 + 40)
            guard abs(contentH - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = contentH
            parent.onLaidOutContentHeight?(contentH)
        }
    }
}
