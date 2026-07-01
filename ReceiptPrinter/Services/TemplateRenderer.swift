import AppKit
import Foundation

enum TemplateRenderer {
    static func renderESCPOS(template: ReceiptTemplate, data: [String: String], config: PrinterConfig) -> Data {
        if template.name.contains("Orpheum") {
            return OrpheumTicketRenderer.renderESCPOS(data: data, config: config)
        }
        let builder = ESCPOSBuilder(config: config).initialize()
        for (index, block) in template.blocks.enumerated() {
            // #region agent log
            DebugLog.write(
                hypothesisId: "D",
                location: "TemplateRenderer.renderBlock",
                message: "render block",
                data: [
                    "index": String(index),
                    "type": block.type.rawValue,
                    "size": block.size.rawValue,
                    "bold": block.bold ? "1" : "0",
                    "content": String(block.content.prefix(30))
                ]
            )
            // #endregion
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
                .text(text)
                .newline()
                .bold(false)
                .applyTextSize(.normal)
        case .row:
            let left = ReceiptTemplate.substitute(block.content, data: data)
            let right = ReceiptTemplate.substitute(block.rightContent, data: data)
            let highlight = ReceiptTemplate.substitute(block.rightHighlight, data: data)
            builder.align(.left)
                .tableRowWithHighlight(
                    left: left,
                    rightPrefix: right,
                    highlight: highlight,
                    leftBold: block.bold,
                    leftSize: block.size
                )
        case .line:
            builder.line()
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
            case .row: h += block.size == .double ? 36 : 20
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
                .font: previewFont(for: .normal, bold: false),
                .foregroundColor: NSColor.black
            ]
            left.draw(at: NSPoint(x: 4, y: y), withAttributes: leftAttrs)
            var rightText = right
            if !highlight.isEmpty {
                rightText += "  \(highlight)  "
            }
            let rs = (rightText as NSString).size(withAttributes: rightAttrs)
            (rightText as NSString).draw(at: NSPoint(x: CGFloat(width) - rs.width - 4, y: y), withAttributes: rightAttrs)
            y += max(left.size(withAttributes: leftAttrs).height, rs.height) + 6
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: previewFont(for: block.size, bold: block.bold),
                .foregroundColor: NSColor.black
            ]
            let text = ReceiptTemplate.substitute(block.content, data: data) as NSString
            let size = text.size(withAttributes: attrs)
            var x: CGFloat = 4
            if block.align == .center { x = (CGFloat(width) - size.width) / 2 }
            if block.align == .right { x = CGFloat(width) - size.width - 4 }
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            y += size.height + 6
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
