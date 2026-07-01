import AppKit
import Foundation

enum TemplateRenderer {
    static func renderESCPOS(template: ReceiptTemplate, data: [String: String], config: PrinterConfig) -> Data {
        let builder = ESCPOSBuilder(config: config).initialize()
        for block in template.blocks {
            renderBlock(block, data: data, builder: builder, config: config)
        }
        return builder.cut().build()
    }

    static func renderPreviewImage(template: ReceiptTemplate, data: [String: String], config: PrinterConfig) -> NSImage {
        let width = config.dotsPerLine
        let height = estimateHeight(template: template, data: data, width: width)
        let image = NSImage(size: NSSize(width: CGFloat(width), height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: height).fill()
        var y: CGFloat = 8
        for block in template.blocks {
            y = drawBlock(block, data: data, at: y, width: width, context: NSGraphicsContext.current)
        }
        image.unlockFocus()
        return image
    }

    private static func renderBlock(
        _ block: TemplateBlock,
        data: [String: String],
        builder: ESCPOSBuilder,
        config: PrinterConfig
    ) {
        switch block.type {
        case .text:
            let text = ReceiptTemplate.substitute(block.content, data: data)
            guard !text.isEmpty else { return }
            let align: ESCPOSAlign = switch block.align {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            builder.align(align)
                .bold(block.bold)
                .applyTextSize(block.size)
            if block.underline { builder.underline(true) }
            if block.reverse { builder.reversePrint(true) }
            builder.text(text).newline()
            builder.resetStyle()
        case .row:
            let left = ReceiptTemplate.substitute(block.content, data: data)
            let right = ReceiptTemplate.substitute(block.rightContent, data: data)
            let highlight = ReceiptTemplate.substitute(block.rightHighlight, data: data)
            builder.tableRowWithHighlight(
                left: left,
                rightPrefix: right,
                highlight: highlight,
                leftBold: block.bold,
                leftSize: block.size,
                rightBold: block.rightBold,
                rightSize: block.rightSize
            )
        case .line:
            let char = block.content.first ?? "-"
            builder.align(.left).line(char: char)
        case .spacer:
            builder.feed(lines: block.spacerLines)
        case .barcode:
            let content = ReceiptTemplate.substitute(block.content, data: data)
            let type: ESCPOSBarcode = block.barcodeType == .code128 ? .code128 : .ean13
            builder.barcode(
                type: type,
                content: content,
                height: block.barcodeHeight,
                width: block.barcodeWidth,
                printHRI: block.barcodePrintHRI
            )
            builder.resetStyle()
        case .qr:
            let content = ReceiptTemplate.substitute(block.content, data: data)
            builder.qrCodeImage(content)
        case .image:
            if let path = block.imagePath, let img = NSImage(contentsOfFile: path) {
                builder.image(img)
            }
        case .table:
            renderTable(block, data: data, builder: builder)
        }
    }

    private static func renderTable(_ block: TemplateBlock, data: [String: String], builder: ESCPOSBuilder) {
        if let json = data[block.dataSource ?? "items"],
           let itemsData = json.data(using: .utf8),
           let items = try? JSONDecoder().decode([[String: String]].self, from: itemsData) {
            for item in items {
                let name = item["name"] ?? ""
                let qty = item["qty"] ?? "1"
                let price = item["price"] ?? ""
                builder.tableRow(left: "\(name) x\(qty)", right: price)
            }
        } else {
            builder.text("[表格: \(block.dataSource ?? "items")]").newline()
        }
    }

    private static func estimateHeight(template: ReceiptTemplate, data: [String: String], width: Int) -> CGFloat {
        var h: CGFloat = 16
        for block in template.blocks {
            switch block.type {
            case .text: h += textBlockHeight(block.size)
            case .row:
                let split = rowNeedsSplitLayout(block)
                h += split ? textBlockHeight(block.size) + 20 : 20
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

    private static func textBlockHeight(_ size: TextSize) -> CGFloat {
        switch size {
        case .normal: 20
        case .tall: 28
        case .double: 36
        }
    }

    private static func previewFontSize(for size: TextSize, bold: Bool) -> CGFloat {
        let base: CGFloat = switch size {
        case .normal: 12
        case .tall: 16
        case .double: 22
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
                .foregroundColor: block.reverse ? NSColor.white : NSColor.black
            ]
            if block.underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let raw = ReceiptTemplate.substitute(block.content, data: data)
            let lines = raw.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                let text = line as NSString
                let size = text.size(withAttributes: attrs)
                var x: CGFloat = 4
                if block.align == .center { x = (CGFloat(width) - size.width) / 2 }
                if block.align == .right { x = CGFloat(width) - size.width - 4 }
                if block.reverse {
                    let pad: CGFloat = 2
                    NSColor.black.setFill()
                    NSRect(x: x - pad, y: y, width: size.width + pad * 2, height: size.height + 2).fill()
                }
                text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                y += size.height + 4
                if lineIndex < lines.count - 1 { y += 2 }
            }
            y += 2
        case .line:
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: y))
            path.line(to: NSPoint(x: CGFloat(width) - 4, y: y))
            path.stroke()
            y += 12
        case .spacer:
            y += CGFloat(block.spacerLines * 12)
        case .qr:
            let content = ReceiptTemplate.substitute(block.content, data: data)
            if let qr = BarcodeGenerator.makeQRCode(content, size: min(width - 40, 160)) {
                qr.draw(in: NSRect(x: (CGFloat(width) - qr.size.width) / 2, y: y, width: qr.size.width, height: qr.size.height))
                y += qr.size.height + 8
            }
        case .barcode:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: previewFont(for: .normal, bold: false),
                .foregroundColor: NSColor.black
            ]
            let content = ReceiptTemplate.substitute(block.content, data: data) as NSString
            let barH = CGFloat(block.barcodeHeight)
            NSColor.black.setFill()
            NSRect(x: CGFloat(width) * 0.15, y: y, width: CGFloat(width) * 0.7, height: barH * 0.6).fill()
            y += barH * 0.6 + 4
            if block.barcodePrintHRI {
                content.draw(at: NSPoint(x: 4, y: y), withAttributes: attrs)
                y += 16
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
}
