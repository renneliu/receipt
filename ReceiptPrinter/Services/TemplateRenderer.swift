import AppKit
import Foundation

enum TemplateRenderer {
    /// Canonical render: same bitmap used for on-screen preview and ESC/POS raster print.
    /// Thermal printers receive GS v 0 raster bytes — not their built-in text fonts.
    static func renderESCPOS(template: ReceiptTemplate, data: [String: String], config: PrinterConfig) -> Data {
        let image = renderPreviewImage(template: template, data: data, config: config)
        return ESCPOSBuilder(config: config)
            .initializeForRaster()
            .align(.left)
            .image(image, maxWidth: config.dotsPerLine)
            .cut()
            .build()
    }

    static func renderPreviewImage(template: ReceiptTemplate, data: [String: String], config: PrinterConfig) -> NSImage {
        let width = config.dotsPerLine
        let height = estimateHeight(template: template, data: data, width: width)
        let size = NSSize(width: CGFloat(width), height: height)
        // flipped: true → origin top-left, same reading order as ESC/POS scroll
        return NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            var y: CGFloat = 8
            for block in template.blocks {
                y = drawBlock(block, data: data, at: y, width: width, context: NSGraphicsContext.current)
            }
            return true
        }
    }

    private static func estimateHeight(template: ReceiptTemplate, data: [String: String], width: Int) -> CGFloat {
        var h: CGFloat = 16
        let contentWidth = CGFloat(width) - 8
        for block in template.blocks {
            switch block.type {
            case .text:
                let raw = ReceiptTemplate.substitute(block.content, data: data)
                h += wrappedTextHeight(raw, size: block.size, bold: block.bold, width: contentWidth) + 6
            case .row:
                let split = rowNeedsSplitLayout(block)
                h += split ? textBlockHeight(block.size) + textBlockHeight(block.rightSize) + 14 : 28
            case .line: h += 16
            case .spacer: h += CGFloat(block.spacerLines * 12)
            case .barcode: h += CGFloat(block.barcodeHeight) + 24
            case .qr, .image: h += 180
            case .table:
                if let json = data[block.dataSource ?? "items"],
                   let itemsData = json.data(using: .utf8),
                   let items = try? JSONDecoder().decode([[String: String]].self, from: itemsData) {
                    h += CGFloat(items.count * 20)
                } else { h += 20 }
            }
        }
        return max(h + 20, 200)
    }

    private static func wrappedTextHeight(_ text: String, size: TextSize, bold: Bool, width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: previewFont(for: size, bold: bold),
            .paragraphStyle: wrappedParagraph(align: .left)
        ]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return max(ceil(bounds.height), textBlockHeight(size))
    }

    private static func wrappedParagraph(align: TextAlign) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        switch align {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        return style
    }

    private static func textBlockHeight(_ size: TextSize) -> CGFloat {
        switch size {
        case .normal: 20
        case .tall: 28
        case .taller: 40
        case .double: 36
        case .doubleTall: 48
        }
    }

    private static func previewFontSize(for size: TextSize, bold: Bool) -> CGFloat {
        let base: CGFloat = switch size {
        case .normal: 12
        case .tall: 16
        case .taller: 22
        case .double: 22
        case .doubleTall: 26
        }
        return base
    }

    private static func previewFont(for size: TextSize, bold: Bool) -> NSFont {
        NSFont.systemFont(ofSize: previewFontSize(for: size, bold: bold), weight: bold ? .bold : .regular)
    }

    private static func rowNeedsSplitLayout(_ block: TemplateBlock) -> Bool {
        block.size == .double || block.rightSize == .double || block.size != block.rightSize
    }

    private static func drawRowRight(
        right: String,
        highlight: String,
        attrs: [NSAttributedString.Key: Any],
        at y: CGFloat,
        width: Int
    ) {
        var rightX = CGFloat(width) - 4
        if !highlight.isEmpty {
            let hlText = "  \(highlight)  " as NSString
            let hlSize = hlText.size(withAttributes: attrs)
            rightX -= hlSize.width
            NSColor.black.setFill()
            NSRect(x: rightX, y: y, width: hlSize.width, height: hlSize.height + 2).fill()
            var hlAttrs = attrs
            hlAttrs[.foregroundColor] = NSColor.white
            hlText.draw(at: NSPoint(x: rightX, y: y), withAttributes: hlAttrs)
        }
        let prefixSize = (right as NSString).size(withAttributes: attrs)
        rightX -= prefixSize.width
        (right as NSString).draw(at: NSPoint(x: rightX, y: y), withAttributes: attrs)
    }

    private static func drawBlock(_ block: TemplateBlock, data: [String: String], at startY: CGFloat, width: Int, context: NSGraphicsContext?) -> CGFloat {
        var y = startY
        switch block.type {
        case .row:
            let left = ReceiptTemplate.substitute(block.content, data: data) as NSString
            let right = ReceiptTemplate.substitute(block.rightContent, data: data)
            let highlight = ReceiptTemplate.substitute(block.rightHighlight, data: data)
            let leftAttrs: [NSAttributedString.Key: Any] = [
                .font: previewFont(for: block.size, bold: block.bold),
                .foregroundColor: NSColor.black
            ]
            let rightAttrs: [NSAttributedString.Key: Any] = [
                .font: previewFont(for: block.rightSize, bold: block.rightBold),
                .foregroundColor: NSColor.black
            ]
            let split = rowNeedsSplitLayout(block)
            left.draw(at: NSPoint(x: 4, y: y), withAttributes: leftAttrs)
            if split {
                y += left.size(withAttributes: leftAttrs).height + 4
                drawRowRight(right: right, highlight: highlight, attrs: rightAttrs, at: y, width: width)
                y += previewFontSize(for: block.rightSize, bold: block.rightBold) + 10
            } else {
                drawRowRight(right: right, highlight: highlight, attrs: rightAttrs, at: y, width: width)
                let rowHeight = max(
                    left.size(withAttributes: leftAttrs).height,
                    previewFontSize(for: block.rightSize, bold: block.rightBold) + 4
                )
                y += rowHeight + 6
            }
        case .text:
            var attrs: [NSAttributedString.Key: Any] = [
                .font: previewFont(for: block.size, bold: block.bold),
                .foregroundColor: block.reverse ? NSColor.white : NSColor.black,
                .paragraphStyle: wrappedParagraph(align: block.align)
            ]
            if block.underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let raw = ReceiptTemplate.substitute(block.content, data: data)
            guard !raw.isEmpty else { break }
            let contentWidth = CGFloat(width) - 8
            let bounds = (raw as NSString).boundingRect(
                with: NSSize(width: contentWidth, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            let drawRect = NSRect(x: 4, y: y, width: contentWidth, height: ceil(bounds.height))
            if block.reverse {
                NSColor.black.setFill()
                drawRect.insetBy(dx: -2, dy: -1).fill()
            }
            (raw as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            y += ceil(bounds.height) + 6
        case .line:
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: y + 4))
            path.line(to: NSPoint(x: CGFloat(width) - 4, y: y + 4))
            path.lineWidth = 1
            path.stroke()
            y += 12
        case .spacer:
            y += CGFloat(block.spacerLines * 12)
        case .qr:
            let content = ReceiptTemplate.substitute(block.content, data: data)
            if let qr = BarcodeGenerator.makeQRCode(content, size: min(width - 40, 160)) {
                qr.draw(
                    in: NSRect(x: (CGFloat(width) - qr.size.width) / 2, y: y, width: qr.size.width, height: qr.size.height),
                    from: .zero,
                    operation: .copy,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)]
                )
                y += qr.size.height + 8
            }
        case .barcode:
            let content = ReceiptTemplate.substitute(block.content, data: data)
            let barH = CGFloat(block.barcodeHeight)
            let barW = CGFloat(width) * 0.78
            let barX = (CGFloat(width) - barW) / 2
            drawPreviewBarcode(content: content, in: NSRect(x: barX, y: y, width: barW, height: barH * 0.7))
            y += barH * 0.7 + 6
            if block.barcodePrintHRI {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: previewFont(for: .normal, bold: false),
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: wrappedParagraph(align: .center)
                ]
                let label = content as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: y), withAttributes: attrs)
                y += size.height + 8
            } else {
                y += 4
            }
        case .image:
            if let path = block.imagePath, let img = NSImage(contentsOfFile: path) {
                let h = min(120, img.size.height)
                let w = min(CGFloat(width) - 8, img.size.width)
                img.draw(in: NSRect(x: 4, y: y, width: w, height: h))
                y += h + 8
            }
        case .table:
            let tableAttrs: [NSAttributedString.Key: Any] = [
                .font: previewFont(for: .normal, bold: false),
                .foregroundColor: NSColor.black
            ]
            if let json = data[block.dataSource ?? "items"],
               let itemsData = json.data(using: .utf8),
               let items = try? JSONDecoder().decode([[String: String]].self, from: itemsData) {
                for item in items {
                    let left = "\(item["name"] ?? "") x\(item["qty"] ?? "1")"
                    let right = item["price"] ?? ""
                    (left as NSString).draw(at: NSPoint(x: 4, y: y), withAttributes: tableAttrs)
                    let rs = (right as NSString).size(withAttributes: tableAttrs)
                    (right as NSString).draw(at: NSPoint(x: CGFloat(width) - rs.width - 4, y: y), withAttributes: tableAttrs)
                    y += 18
                }
            }
        }
        return y
    }

    /// Simple Code128-like bars for preview/raster print (integer-pixel bar widths, no interpolation).
    private static func drawPreviewBarcode(content: String, in rect: NSRect) {
        let digits = content.filter { $0.isNumber || $0.isLetter }
        var pattern: [Bool] = [true, true, false] // start-ish
        for (index, ch) in digits.utf8.enumerated() {
            let v = Int(ch)
            pattern.append(true)
            pattern.append(index % 2 == 0)
            pattern.append(false)
            pattern.append(v % 2 == 0)
            pattern.append(true)
            pattern.append(false)
        }
        pattern.append(contentsOf: [true, true, true, false, true])
        let unit = max(1, floor(rect.width / CGFloat(max(pattern.count, 1))))
        var x = rect.minX
        NSColor.black.setFill()
        for bit in pattern {
            if bit {
                NSRect(x: x, y: rect.minY, width: unit, height: rect.height).fill()
            }
            x += unit
            if x > rect.maxX { break }
        }
    }
}
