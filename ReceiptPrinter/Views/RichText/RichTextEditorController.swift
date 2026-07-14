import Combine
import AppKit

@MainActor
final class RichTextEditorController: ObservableObject {
    weak var textView: NSTextView?

    enum DividerStyle: String, CaseIterable, Identifiable {
        case solid
        case dashed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .solid: return "直线"
            case .dashed: return "虚线"
            }
        }

        func lineString(columns: Int) -> String {
            let width = max(8, columns)
            switch self {
            case .solid:
                return String(repeating: "-", count: width)
            case .dashed:
                var s = ""
                while s.count < width {
                    s += (s.last == "-") ? " " : "-"
                }
                return String(s.prefix(width))
            }
        }
    }

    func toggleBold() {
        mutateAttributes { attrs in
            let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: AttributedTextView.defaultFontSize)
            let traits = NSFontManager.shared.traits(of: font)
            let newFont = traits.contains(.boldFontMask)
                ? NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            attrs[.font] = newFont
        }
    }

    func toggleItalic() {
        mutateAttributes { attrs in
            let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: AttributedTextView.defaultFontSize)
            let traits = NSFontManager.shared.traits(of: font)
            let newFont = traits.contains(.italicFontMask)
                ? NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
                : NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            attrs[.font] = newFont
        }
    }

    func toggleUnderline() {
        mutateAttributes { attrs in
            if attrs[.underlineStyle] != nil {
                attrs.removeValue(forKey: .underlineStyle)
            } else {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }
    }

    func applyFontSize(_ size: CGFloat) {
        mutateAttributes { attrs in
            let existing = attrs[.font] as? NSFont
            let traits = existing.map { NSFontManager.shared.traits(of: $0) } ?? []
            var font = AttributedTextView.editorFont(ofSize: size)
            if traits.contains(.boldFontMask) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            attrs[.font] = font
            let para = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? (AttributedTextView.defaultParagraphStyle().mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            para.lineBreakMode = .byCharWrapping
            attrs[.paragraphStyle] = para
        }
    }

    func applyAlignment(_ alignment: NSTextAlignment) {
        guard let textView, let storage = textView.textStorage else { return }
        let sel = textView.selectedRange()

        let targetRange: NSRange
        if storage.length == 0 {
            targetRange = NSRange(location: 0, length: 0)
        } else if sel.length > 0 {
            targetRange = (storage.string as NSString).paragraphRange(for: sel)
        } else {
            let loc = min(sel.location, storage.length - 1)
            targetRange = (storage.string as NSString).paragraphRange(for: NSRange(location: loc, length: 0))
        }

        if targetRange.length > 0 {
            storage.beginEditing()
            var index = targetRange.location
            let end = NSMaxRange(targetRange)
            while index < end {
                var effective = NSRange()
                var attrs = storage.attributes(at: index, effectiveRange: &effective)
                let clipped = NSIntersectionRange(effective, targetRange)
                let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                style.alignment = alignment
                attrs[.paragraphStyle] = style
                storage.setAttributes(attrs, range: clipped)
                index = NSMaxRange(effective)
            }
            storage.endEditing()
        }

        var typing = textView.typingAttributes
        let style = (typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.alignment = alignment
        typing[.paragraphStyle] = style
        textView.typingAttributes = typing
        textView.didChangeText()
    }

    func applyLineSpacing(_ spacing: CGFloat) {
        mutateParagraph { $0.lineSpacing = spacing }
    }

    func applyKern(_ kern: CGFloat) {
        mutateAttributes { $0[.kern] = kern }
    }

    func applyForegroundColor(_ color: NSColor) {
        mutateAttributes { $0[.foregroundColor] = color }
    }

    func clearFormatting() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let defaults = AttributedTextView.defaultTypingAttributes(fontSize: AttributedTextView.defaultFontSize)
        if range.length > 0 {
            textView.textStorage?.setAttributes(defaults, range: range)
        }
        textView.typingAttributes = defaults
    }

    func insertPlainText(_ text: String) {
        guard let textView else { return }
        let attrs = textView.typingAttributes.isEmpty
            ? AttributedTextView.defaultTypingAttributes()
            : textView.typingAttributes
        let insertion = NSAttributedString(string: text, attributes: attrs)
        textView.insertText(insertion, replacementRange: textView.selectedRange())
    }

    func insertDivider(style: DividerStyle, columns: Int) {
        guard let textView else { return }
        let typingSize = (textView.typingAttributes[.font] as? NSFont)?.pointSize
            ?? AttributedTextView.defaultFontSize
        let config = PrinterConfig(columnsPerLine: max(8, columns))
        let lineWidth = AttributedTextView.editorContentWidth(config: config, fontSize: typingSize)
        let attachmentStyle: ReceiptDividerAttachment.Style = style == .solid ? .solid : .dashed
        let attachment = ReceiptDividerAttachment(style: attachmentStyle, lineWidth: lineWidth)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.paragraphSpacingBefore = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .attachment: attachment,
            .paragraphStyle: para,
            .font: NSFont.systemFont(ofSize: 4)
        ]
        let piece = NSMutableAttributedString(string: "\n")
        let attachmentString = NSMutableAttributedString(attachment: attachment)
        attachmentString.addAttributes(attrs, range: NSRange(location: 0, length: attachmentString.length))
        piece.append(attachmentString)
        piece.append(NSAttributedString(string: "\n"))
        textView.insertText(piece, replacementRange: textView.selectedRange())
    }

    func insertPlaceholder(fieldName: String) {
        insertPlainText("{{\(fieldName)}}")
    }

    private func mutateAttributes(_ block: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let textView else { return }
        let range = textView.selectedRange()
        textView.undoManager?.beginUndoGrouping()
        if range.length == 0 {
            var typing = textView.typingAttributes
            block(&typing)
            textView.typingAttributes = typing
        } else {
            textView.textStorage?.beginEditing()
            textView.textStorage?.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                var updated = attrs
                block(&updated)
                textView.textStorage?.setAttributes(updated, range: subRange)
            }
            textView.textStorage?.endEditing()
        }
        textView.undoManager?.endUndoGrouping()
    }

    private func mutateParagraph(_ block: (NSMutableParagraphStyle) -> Void) {
        mutateAttributes { attrs in
            let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            block(style)
            attrs[.paragraphStyle] = style
        }
    }
}
