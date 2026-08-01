import XCTest
@testable import ReceiptPrinter

final class ReceiptPrinterCoreTests: XCTestCase {
    func testL10nEnglishMapsDiagnosticAndSampleTicket() {
        XCTAssertEqual(L10n.ui("打印作业", .english), "Print Jobs")
        XCTAssertEqual(L10n.ui("示例影票", .english), "Sample Ticket")
        XCTAssertEqual(L10n.ui("打印诊断", .english), "Print Diagnostics")
        XCTAssertEqual(L10n.ui("打印作业", .chinese), "打印作业")
        XCTAssertEqual(L10n.ui("示例影票", .chinese), "示例影票")
    }

    func testPlaceholderResolutionMovieTicketEndTime() {
        var template = ReceiptTemplate(name: "电影票")
        template.blocks = [TemplateBlock(type: .text, content: "{{showDateTime}}")]
        let manual: [String: String] = [
            "venueName": "Orpheum",
            "hallNumber": "4",
            "movieTitle": "Test",
            "showStartISO": "2026-06-28T08:00:00Z",
            "adDurationMinutes": "15",
            "movieDurationMinutes": "120",
            "ticketType": "Adult",
            "ticketPrice": "20",
            "barcodeBase": "12345678",
            "ticketSerial": "001"
        ]
        var settings = AppSettings()
        settings.defaultAdvertisingMinutes = 10
        let context = TemplateDataContext(manual: manual, settings: settings)
        let resolved = PlaceholderResolutionService.resolve(template: template, context: context)
        XCTAssertFalse(resolved["showDateTime"]?.isEmpty ?? true)
    }

    func testTemplateDocumentRoundTrip() {
        var template = ReceiptTemplate(name: "Test")
        template.blocks = [
            TemplateBlock(type: .text, content: "Hello {{name}}"),
            TemplateBlock(type: .line, content: "")
        ]
        template.defaultData = ["name": "World"]
        let document = TemplateDocumentMigration.fromReceiptTemplate(template)
        let back = TemplateDocumentMigration.toReceiptTemplate(document)
        XCTAssertEqual(back.name, template.name)
        XCTAssertEqual(back.blocks.count, template.blocks.count)
    }

    func testPrinterConfigDotsPerLine80mm() {
        let config = PrinterConfig.default80mm
        XCTAssertEqual(config.dotsPerLine, 576)
        XCTAssertEqual(config.columnsPerLine, 48)
    }

    func testQuickPrintPreviewAndPrintShareLayout() {
        let config = PrinterConfig.default80mm
        let text = """
        Hello 测试小票

        ReceiptPrinter 快速打印
        --------------------------------

        的是非得失饭店干豆腐干豆腐和高峰会将根据法国航空距离疯狂干活艰苦奋斗不过没地方，帮个忙你下班就看到符合国际快递

        --------------------------------
        """
        let attrs = AttributedTextView.defaultTypingAttributes()
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let preview = RichTextPrintRenderer.renderImage(attributedString: attributed, config: config)
        XCTAssertEqual(preview.size.width, CGFloat(config.dotsPerLine))

        var printConfig = config
        printConfig.cutPaper = true
        let escpos = RichTextPrintRenderer.renderESCPOS(attributedString: attributed, config: printConfig)
        // POS-80 reliable path: native GBK text (FS &), NOT whole-page GS v 0.
        XCTAssertFalse(escpos.contains(Data([0x1D, 0x76, 0x30])))
        XCTAssertTrue(escpos.contains(Data([0x1C, 0x26]))) // FS & Chinese mode
        // Proven mixed path (diag 20260714-224905): Latin under FS ., CJK under FS &.
        XCTAssertTrue(escpos.contains(Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]))) // Hello
        XCTAssertTrue(escpos.contains(Data([0x1C, 0x2E]))) // FS . for Latin-leading runs
        XCTAssertTrue(escpos.contains(Data([0xB2, 0xE2, 0xCA, 0xD4]))) // GBK 测试

        let lines = RichTextPrintRenderer.layoutLines(from: attributed, config: config)
        let textLines = lines.compactMap { line -> (String, TextSize)? in
            if case .text(let s, let size, _, _, _) = line { return (s, size) }
            return nil
        }
        XCTAssertTrue(textLines.contains { $0.0.contains("Hello") })
        XCTAssertTrue(textLines.contains { $0.0.contains("测试") })
        XCTAssertTrue(textLines.contains { $0.0.contains("Receipt") })
        XCTAssertTrue(textLines.contains { $0.0.contains("快速") })
    }

    func testQuickPrintAlignmentEmitsESCAlign() {
        let config = PrinterConfig.default80mm
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        var attrs = AttributedTextView.defaultTypingAttributes()
        attrs[.paragraphStyle] = para
        let attributed = NSAttributedString(string: "居中测试", attributes: attrs)
        let lines = RichTextPrintRenderer.layoutLines(from: attributed, config: config)
        XCTAssertTrue(lines.contains {
            if case .text(_, _, _, _, .center) = $0 { return true }
            return false
        })
        let escpos = RichTextPrintRenderer.renderESCPOS(attributedString: attributed, config: config)
        // ESC a 1 = center
        XCTAssertTrue(escpos.contains(Data([0x1B, 0x61, 0x01])))
        XCTAssertFalse(escpos.contains(Data([0x1D, 0x76, 0x30])))
    }

    // MARK: - Determinism & default-style regression (production correctness)

    private static let regressionContent = """
    默认样式测试：这整行必须使用默认字体的两倍大小
    中文测试：收到就发给和空间的水工回复即可
    English test: ReceiptPrinter ABC 123
    混合测试：中文 English 123 中文 ABC
    连续打印测试：相同内容连续打印五次，结果必须完全一致
    """

    func testDefaultUnformattedTextResolvesToDoubleSize() {
        // Requirement: unformatted text must resolve to 2× normal size.
        XCTAssertEqual(AttributedTextView.defaultFontSize,
                       AttributedTextView.normalFontSize * AttributedTextView.defaultHeightMultiplier)
        XCTAssertEqual(RichTextPrintRenderer.textSize(forPointSize: AttributedTextView.defaultFontSize), .double)

        let attrs = AttributedTextView.defaultTypingAttributes()
        let attributed = NSAttributedString(string: Self.regressionContent, attributes: attrs)
        let lines = RichTextPrintRenderer.layoutLines(from: attributed, config: .default80mm)
        let textSizes = lines.compactMap { line -> TextSize? in
            if case .text(_, let size, _, _, _) = line { return size }
            return nil
        }
        XCTAssertFalse(textSizes.isEmpty)
        // Every default (unformatted) line — including the mixed CJK+EN line — must be double.
        XCTAssertTrue(textSizes.allSatisfy { $0 == .double })
    }

    func testRepeatedPayloadGenerationIsDeterministic() {
        // Requirement: same input → same print payload, every time (no random changes).
        var config = PrinterConfig.default80mm
        config.cutPaper = true
        let attrs = AttributedTextView.defaultTypingAttributes()
        let attributed = NSAttributedString(string: Self.regressionContent, attributes: attrs)

        let baseline = RichTextPrintRenderer.renderESCPOS(attributedString: attributed, config: config)
        XCTAssertFalse(baseline.contains(Data([0x1D, 0x76, 0x30])))
        XCTAssertTrue(baseline.starts(with: Data([0x1B, 0x40]))) // explicit ESC @ init every job
        XCTAssertTrue(baseline.contains(Data([0x1C, 0x26]))) // FS & Chinese mode
        for _ in 0..<100 {
            let again = RichTextPrintRenderer.renderESCPOS(attributedString: attributed, config: config)
            XCTAssertEqual(again, baseline, "Identical input must produce byte-identical payload")
        }
    }

    func testStyleIsolationDoesNotLeakToDefaultRange() {
        // A bold/custom-size range must not change the following default range's resolved size.
        let config = PrinterConfig.default80mm
        let mutable = NSMutableAttributedString()
        var bold = AttributedTextView.defaultTypingAttributes()
        bold[.font] = NSFontManager.shared.convert(
            AttributedTextView.editorFont(ofSize: AttributedTextView.defaultFontSize),
            toHaveTrait: .boldFontMask
        )
        mutable.append(NSAttributedString(string: "粗体BOLD\n", attributes: bold))
        mutable.append(NSAttributedString(string: "默认default", attributes: AttributedTextView.defaultTypingAttributes()))

        let lines = RichTextPrintRenderer.layoutLines(from: mutable, config: config)
        let texts = lines.compactMap { line -> (String, TextSize, Bool)? in
            if case .text(let s, let size, let b, _, _) = line { return (s, size, b) }
            return nil
        }
        let defaultLine = texts.first { $0.0.contains("默认") }
        XCTAssertNotNil(defaultLine)
        XCTAssertEqual(defaultLine?.1, .double)   // default size preserved
        XCTAssertEqual(defaultLine?.2, false)     // bold did not leak
    }

    func testMixedContentUsesGBKTextBytes() {
        // Body is native text with FS & / FS . segmentation — GBK CJK bytes must be present.
        let config = PrinterConfig.default80mm
        let attributed = NSAttributedString(
            string: "中文 English 123 测试 ABC",
            attributes: AttributedTextView.defaultTypingAttributes()
        )
        let escpos = RichTextPrintRenderer.renderESCPOS(attributedString: attributed, config: config)
        XCTAssertFalse(escpos.contains(Data([0x1D, 0x76, 0x30])))
        XCTAssertTrue(escpos.contains(Data([0x1C, 0x26]))) // FS & Chinese text mode
        XCTAssertTrue(escpos.contains(Data([0xB2, 0xE2, 0xCA, 0xD4]))) // GBK 测试
        // CJK-leading mixed source keeps English bytes; may still emit FS . for ASCII-only wrap tails.
        XCTAssertTrue(escpos.contains(Data([0x45, 0x6E, 0x67, 0x6C, 0x69, 0x73, 0x68]))) // "English"
        XCTAssertFalse(escpos.contains(Data([0x3F, 0x3F]))) // no "??" replacement runs
    }

    func testMixedCJKAndASCIIStayOnSameWrappedLines() {
        // Attribute-run splitting must NOT force ASCII onto its own printed line.
        let config = PrinterConfig.default80mm
        let source = "还为客人还未哦日哦为UI惹我尽量快点就撒开了的哈萨克了哈疯狂的时候疯狂脸上"
        // Simulate NSTextView font-run boundaries between CJK and Latin.
        let mutable = NSMutableAttributedString()
        let font = AttributedTextView.editorFont(ofSize: AttributedTextView.defaultFontSize)
        mutable.append(NSAttributedString(string: "还为客人还未哦日哦为", attributes: [.font: font]))
        mutable.append(NSAttributedString(
            string: "UI",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: AttributedTextView.defaultFontSize, weight: .regular)]
        ))
        mutable.append(NSAttributedString(string: "惹我尽量快点就撒开了的哈萨克了哈疯狂的时候疯狂脸上", attributes: [.font: font]))
        XCTAssertEqual(mutable.string, source)

        let lines = RichTextPrintRenderer.layoutLines(from: mutable, config: config)
        let texts = lines.compactMap { line -> String? in
            if case .text(let s, _, _, _, _) = line { return s }
            return nil
        }
        XCTAssertFalse(texts.contains("UI"), "ASCII must wrap with neighboring CJK, not its own line")
        XCTAssertTrue(texts.contains { $0.contains("UI") && $0.contains("哦为") })
    }

    func testLegacyDashDividerUsesNativeText() {
        let config = PrinterConfig.default80mm
        let body = NSAttributedString(
            string: "Hello\n\(String(repeating: "-", count: 48))\nWorld",
            attributes: AttributedTextView.defaultTypingAttributes()
        )
        let image = RichTextPrintRenderer.renderImage(attributedString: body, config: config)
        XCTAssertEqual(image.size.width, CGFloat(config.dotsPerLine))
        let escpos = RichTextPrintRenderer.renderESCPOS(attributedString: body, config: config)
        XCTAssertFalse(escpos.contains(Data([0x1D, 0x76, 0x30])))
        let lines = RichTextPrintRenderer.layoutLines(from: body, config: config)
        XCTAssertTrue(lines.contains { if case .divider = $0 { return true }; return false })
    }

    func testSequenceComposerTruncatesToPlaceholderColumns() {
        let config = PrinterConfig.default80mm
        let fontSize = AttributedTextView.defaultFontSize
        let paperW = AttributedTextView.editorPaperWidth(config: config, fontSize: fontSize)
        let body = NSAttributedString(string: "标题\n", attributes: AttributedTextView.defaultTypingAttributes())
        let m = SequenceLayoutComposer.metrics(config: config, fontSize: fontSize, paperWidthPoints: paperW)
        // Box ~4 columns wide on second grid row (overlay paint, not append).
        let frame = SequencePlaceholderFrame(
            x: m.contentOriginX,
            y: m.contentOriginY + m.lineHeight,
            width: m.unitWidth * 4,
            height: m.lineHeight
        )
        let box = SequencePlaceholder(bindingKey: "姓名", frame: frame)
        let composed = SequenceLayoutComposer.compose(
            body: body,
            placeholders: [box],
            values: ["姓名": "张三李四王五赵六"],
            config: config,
            fontSize: fontSize,
            paperWidthPoints: paperW
        )
        let lines = composed.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "标题")
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        let painted = lines[1]
        let valueWidth = ReceiptTextLayout.displayWidth(
            painted.filter { !$0.isWhitespace }.map(String.init).joined()
        )
        XCTAssertLessThanOrEqual(valueWidth, 4 + 2, "placeholder value must not exceed box column width")
        XCTAssertTrue(painted.contains("张") || painted.contains("三"))
    }

    func testSequenceComposerOverlaysPlaceholderBesideBodyOnSameRow() {
        let config = PrinterConfig.default80mm
        let fontSize = AttributedTextView.defaultFontSize
        let paperW = AttributedTextView.editorPaperWidth(config: config, fontSize: fontSize)
        let m = SequenceLayoutComposer.metrics(config: config, fontSize: fontSize, paperWidthPoints: paperW)
        let body = NSAttributedString(string: "左侧文字", attributes: AttributedTextView.defaultTypingAttributes())
        let frame = SequencePlaceholderFrame(
            x: m.contentOriginX + m.unitWidth * 10,
            y: m.contentOriginY,
            width: m.unitWidth * 6,
            height: m.lineHeight
        )
        let composed = SequenceLayoutComposer.compose(
            body: body,
            placeholders: [SequencePlaceholder(bindingKey: "序列", frame: frame)],
            values: ["序列": "1"],
            config: config,
            fontSize: fontSize,
            paperWidthPoints: paperW
        )
        let first = composed.string.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(first.contains("左侧"), "body prefix must remain on row 0")
        XCTAssertTrue(first.contains("1"), "placeholder value must overlay same row")
    }

    func testSequenceComposerPrintsNativeNotRaster() {
        let config = PrinterConfig.default80mm
        let fontSize = AttributedTextView.defaultFontSize
        let paperW = AttributedTextView.editorPaperWidth(config: config, fontSize: fontSize)
        let body = NSAttributedString(
            string: "Hello {{名}}",
            attributes: AttributedTextView.defaultTypingAttributes()
        )
        let frame = SequencePlaceholderFrame(x: 20, y: 40, width: 120, height: 36)
        let composed = SequenceLayoutComposer.compose(
            body: body,
            placeholders: [SequencePlaceholder(bindingKey: "名", frame: frame)],
            values: ["名": "测试"],
            config: config,
            fontSize: fontSize,
            paperWidthPoints: paperW
        )
        XCTAssertTrue(composed.string.contains("Hello") || composed.string.contains("测试"))
        let escpos = RichTextPrintRenderer.renderESCPOS(attributedString: composed, config: config)
        XCTAssertFalse(escpos.contains(Data([0x1D, 0x76, 0x30])))
        XCTAssertTrue(escpos.contains(Data([0x1C, 0x26])))
    }

    func testQuickPrintAutoNumberIncrementsAndPads() {
        XCTAssertEqual(QuickPrintAutoNumber.format(start: "01", offset: 0), "01")
        XCTAssertEqual(QuickPrintAutoNumber.format(start: "01", offset: 2), "03")
        XCTAssertEqual(QuickPrintAutoNumber.format(start: "A01", offset: 1), "A02")
        XCTAssertEqual(QuickPrintAutoNumber.format(start: "99", offset: 1), "100")
    }

    func testQuickPrintAutoNumberAdvancesStartAfterPrint() {
        var n = QuickPrintAutoNumber(startValue: "01", batchCount: 3)
        n.advanceAfterPrint(count: 3)
        XCTAssertEqual(n.startValue, "04")
        n.advanceAfterPrint(count: 1)
        XCTAssertEqual(n.startValue, "05")
    }

    func testComposeTextOverlaysPaintsNumberWithoutRaster() {
        let config = PrinterConfig.default80mm
        let fontSize = AttributedTextView.defaultFontSize
        let paperW = AttributedTextView.editorPaperWidth(config: config, fontSize: fontSize)
        let body = NSAttributedString(
            string: "Hello 测试小票",
            attributes: AttributedTextView.defaultTypingAttributes(fontSize: fontSize)
        )
        let frame = SequencePlaceholderFrame(x: 200, y: 12, width: 80, height: 36)
        let composed = SequenceLayoutComposer.composeTextOverlays(
            body: body,
            overlays: [.init(text: "01", frame: frame, fontSize: fontSize)],
            config: config,
            fontSize: fontSize,
            paperWidthPoints: paperW
        )
        XCTAssertTrue(composed.string.contains("01") || composed.string.contains("Hello"))
        let escpos = RichTextPrintRenderer.renderSequenceESCPOS(
            pages: [body],
            config: config,
            media: .init(
                textOverlays: [.init(text: "01", frame: frame, fontSize: fontSize)],
                canvasSize: CGSize(width: paperW, height: 480)
            ),
            pageTextOverlays: [[.init(text: "01", frame: frame, fontSize: fontSize)]],
            editorFontSize: fontSize,
            paperWidthPoints: paperW
        )
        XCTAssertTrue(escpos.contains(Data([0x1C, 0x26]))) // FS & native Chinese
        XCTAssertFalse(escpos.contains(Data([0x1D, 0x76, 0x30]))) // no GS v 0 without logos
    }

    func testPOSReceiptTotalsQuantityAndAmount() {
        let items = [
            POSLineItem(code: "1", name: "A", quantity: "2", amount: "10.5"),
            POSLineItem(code: "2", name: "B", quantity: "3", amount: "1.5")
        ]
        XCTAssertEqual(POSReceiptTotals.quantitySubtotal(items: items), 5)
        XCTAssertEqual(POSReceiptTotals.amountSubtotal(items: items), 12.0, accuracy: 0.001)
        XCTAssertEqual(POSReceiptTotals.amountTotal(items: items, surcharge: "2"), 14.0, accuracy: 0.001)
        XCTAssertEqual(POSReceiptTotals.itemCount(items: items), 2)
        XCTAssertEqual(POSReceiptTotals.formatAmount(12), "12.00")
        XCTAssertEqual(POSReceiptTotals.formatQuantity(5), "5")
    }

    func testPOSExcelLookupByMappedCodeColumn() {
        let table = SpreadsheetTable(
            headers: ["SKU", "品名", "Qty", "Price"],
            rows: [
                ["A01", "茶", "2", "18"],
                ["B02", "咖啡", "1", "25"]
            ]
        )
        let map = POSExcelColumnMap(
            codeHeader: "SKU",
            nameHeader: "品名",
            quantityHeader: "Qty",
            amountHeader: "Price"
        )
        let hit = POSExcelLookupService.lookup(code: "B02", table: table, map: map)
        XCTAssertEqual(hit?.name, "咖啡")
        XCTAssertEqual(hit?.quantity, "1")
        XCTAssertEqual(hit?.amount, "25")
        XCTAssertNil(POSExcelLookupService.lookup(code: "ZZZ", table: table, map: map))
    }

    func testPOSLineBandExpandShiftsFooterAndRepeatsRows() {
        var template = POSReceiptTemplate.makeBlank(name: "t")
        template.enableCode = true
        template.enableQuantity = true
        template.enableAmount = true
        template.elements = [
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 40, width: 80, height: 24),
                fieldKind: .code
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 100, y: 40, width: 120, height: 24),
                fieldKind: .name
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 100, width: 100, height: 24),
                fieldKind: .amountSubtotal,
                ticketSection: .footer
            ),
            POSReceiptElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: 12, y: 8, width: 80, height: 20),
                content: "店名",
                ticketSection: .header
            )
        ]
        let band = POSReceiptLayoutEngine.lineBand(template: template)
        XCTAssertNotNil(band)
        // pitch = height + 4
        XCTAssertEqual(Double(band!.height), 28, accuracy: 0.1)

        let items = [
            POSLineItem(code: "1", name: "甲", quantity: "1", amount: "10"),
            POSLineItem(code: "2", name: "乙", quantity: "2", amount: "20")
        ]
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: items,
            surcharge: "0"
        )
        let names = layout.texts.filter { $0.text == "甲" || $0.text == "乙" }
        XCTAssertEqual(names.count, 2)
        let codeAndNameRow0 = layout.texts.filter { $0.text == "1" || $0.text == "甲" }
        XCTAssertEqual(Set(codeAndNameRow0.map(\.frame.y)).count, 1, "编号与项目应在同一行")
        let subtotal = layout.texts.first { $0.text == "30.00" }
        XCTAssertNotNil(subtotal)
        // Footer tracks itemsBottom (designBandBottom = name.y+h = 64), not mere (span-pitch).
        let itemsBottom = Double(POSReceiptLayoutEngine.printRowY(template: template))
            + Double(POSReceiptLayoutEngine.itemPitch(template: template)) * 2
        let designBandBottom = 40.0 + 24.0
        XCTAssertEqual(
            Double(subtotal?.frame.y ?? 0),
            100 + (itemsBottom - designBandBottom),
            accuracy: 0.1
        )
        let header = layout.texts.first { $0.text == "店名" }
        XCTAssertEqual(Double(header?.frame.y ?? -1), 8, accuracy: 0.1)
    }

    func testPOSExplicitFooterShiftsEvenWhenAboveItemBand() {
        var template = POSReceiptTemplate.makeBlank(name: "t")
        template.enableCode = true
        // Footer marker placed near header Y — only ticketSection decides shift.
        template.elements = [
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 80, width: 40, height: 28),
                fieldKind: .code
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 60, y: 80, width: 120, height: 28),
                fieldKind: .name
            ),
            POSReceiptElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: 12, y: 40, width: 100, height: 20),
                content: "页脚备注",
                ticketSection: .footer
            ),
            POSReceiptElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: 12, y: 200, width: 100, height: 20),
                content: "页眉误放",
                ticketSection: .header
            )
        ]
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: [
                POSLineItem(code: "1", name: "A", quantity: "", amount: ""),
                POSLineItem(code: "2", name: "B", quantity: "", amount: "")
            ],
            surcharge: "0"
        )
        let pitch = POSReceiptLayoutEngine.itemPitch(template: template)
        let designBandBottom = 80.0 + 28.0
        let itemsBottom = Double(POSReceiptLayoutEngine.printRowY(template: template))
            + Double(pitch) * 2
        let footer = layout.texts.first { $0.text == "页脚备注" }
        let header = layout.texts.first { $0.text == "页眉误放" }
        XCTAssertEqual(
            Double(footer?.frame.y ?? -1),
            40 + (itemsBottom - designBandBottom),
            accuracy: 0.1
        )
        XCTAssertEqual(Double(header?.frame.y ?? -1), 200, accuracy: 0.1)
    }

    /// Footer divider/text must not push the item band below them, and must sit after the last item.
    func testPOSFooterFollowsItemsBottomDespiteDesignedOverlap() {
        var template = POSReceiptTemplate.makeBlank(name: "t")
        template.enableCode = false
        template.enableQuantity = false
        template.enableAmount = false
        template.elements = [
            POSReceiptElement(
                kind: .logo,
                frame: SequencePlaceholderFrame(x: 20, y: 16, width: 100, height: 106),
                ticketSection: .header
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 140, width: 200, height: 40),
                fieldKind: .name
            ),
            POSReceiptElement(
                kind: .divider,
                frame: SequencePlaceholderFrame(x: 20, y: 180, width: 278, height: 22),
                ticketSection: .footer
            ),
            POSReceiptElement(
                kind: .textBox,
                frame: SequencePlaceholderFrame(x: 20, y: 200, width: 200, height: 28),
                content: "Thanks for coming",
                ticketSection: .footer
            )
        ]
        let printY = POSReceiptLayoutEngine.printRowY(template: template)
        XCTAssertEqual(
            Double(printY),
            140,
            accuracy: 0.1,
            "footer chrome must not push printRowY below the designed name row"
        )

        let items = [
            POSLineItem(name: "甲"),
            POSLineItem(name: "乙"),
            POSLineItem(name: "丙")
        ]
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: items,
            surcharge: "0"
        )
        let lastName = layout.texts.last { ["甲", "乙", "丙"].contains($0.text) }
        let divider = layout.texts.first { $0.asRule }
        let thanks = layout.texts.first { $0.text == "Thanks for coming" }
        XCTAssertNotNil(lastName)
        XCTAssertNotNil(divider)
        XCTAssertNotNil(thanks)
        let itemsBottom = (lastName?.frame.y ?? 0) + POSReceiptLayoutEngine.itemPitch(template: template)
        XCTAssertGreaterThanOrEqual(
            Double(divider?.frame.y ?? -1),
            Double(itemsBottom) - 0.5,
            "divider should sit at/after last item"
        )
        XCTAssertGreaterThan(
            Double(thanks?.frame.y ?? -1),
            Double(divider?.frame.y ?? 0),
            "thanks keeps relative order under divider"
        )
    }

    func testPOSNameWrapsAndGrowsRowHeight() {
        var template = POSReceiptTemplate.makeBlank(name: "t")
        template.enableCode = true
        // Narrow name frame forces width-based wrap (not legacy 字数).
        template.elements = [
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 40, width: 40, height: 28),
                fieldKind: .code
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 60, y: 40, width: 48, height: 28),
                fontSize: 16,
                fieldKind: .name
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 100, width: 100, height: 24),
                fieldKind: .amountSubtotal
            )
        ]
        // Long enough that even packed ~120pt@16 wraps; assert width-fit not fixed 字数.
        let long = "一二三四五六七八九十一二三四五六七八九十"
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: [
                POSLineItem(code: "1", name: long, quantity: "", amount: "10"),
                POSLineItem(code: "2", name: "短", quantity: "", amount: "5")
            ],
            surcharge: "0"
        )
        let nameBox = layout.texts.first { $0.text.contains("一") }
        XCTAssertNotNil(nameBox)
        XCTAssertTrue(nameBox!.text.contains("\n"), "长名称应按框宽换行")
        XCTAssertGreaterThan(nameBox!.frame.height, 28, "长名称框应增高以容纳换行")
        let short = layout.texts.first { $0.text == "短" }
        XCTAssertNotNil(short)
        XCTAssertGreaterThan(short!.frame.y, nameBox!.frame.y, "第二条应在第一条换行之后")
        let subtotal = layout.texts.first { $0.text == "15.00" }
        XCTAssertNotNil(subtotal)
        XCTAssertGreaterThan(subtotal!.frame.y, nameBox!.frame.y)
    }

    func testPOSNameWrapPreservesEnglishWords() {
        let lines = ReceiptTextLayout.wrapFittingWidth(
            "Hello wonderful world",
            maxWidth: 90,
            fontSize: 16,
            preserveEnglishWords: true
        )
        for line in lines {
            XCTAssertFalse(line.hasSuffix("wonde") || line.hasPrefix("rful"))
        }
        XCTAssertGreaterThan(lines.count, 1)
    }

    func testPOSNameWrapFillsWidthWhenFontShrinks() {
        let text = "快水工就看到符合高科技的风格"
        let width: CGFloat = 120
        let large = ReceiptTextLayout.wrapFittingWidth(text, maxWidth: width, fontSize: 28)
        let small = ReceiptTextLayout.wrapFittingWidth(text, maxWidth: width, fontSize: 12)
        XCTAssertGreaterThan(
            small.first?.count ?? 0,
            large.first?.count ?? 0,
            "小号字体应在同一框宽内排入更多字"
        )
        let legacy = ReceiptTextLayout.wrap(text, maxColumns: 12, asciiAsDoubleWidth: false)
        XCTAssertEqual(legacy.first?.count, 6, "旧字数换行与字号无关")
        XCTAssertNotEqual(small.first?.count, legacy.first?.count)
    }

    func testPOSLineFieldsForceSameRowEvenIfTemplateYDiffers() {
        var template = POSReceiptTemplate.makeBlank(name: "t")
        template.enableCode = true
        template.elements = [
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 40, width: 40, height: 28),
                fieldKind: .code
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 80, y: 120, width: 120, height: 28),
                fieldKind: .name
            )
        ]
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: [POSLineItem(code: "9", name: "同行", quantity: "", amount: "")],
            surcharge: "0"
        )
        let code = layout.texts.first { $0.text == "9" }
        let name = layout.texts.first { $0.text == "同行" }
        XCTAssertEqual(code?.frame.y, name?.frame.y)
        XCTAssertEqual(Double(POSReceiptLayoutEngine.itemPitch(template: template)), 32, accuracy: 0.1)
    }

    func testPOSLineSpacingExtraWidensItemPitch() {
        var template = POSReceiptTemplate.makeBlank(name: "spacing")
        let base = POSReceiptLayoutEngine.itemPitch(template: template)
        template.lineSpacingExtraDots = 12
        let widened = POSReceiptLayoutEngine.itemPitch(template: template)
        XCTAssertEqual(Double(widened - base), 12, accuracy: 0.1)
    }

    func testPOSNativeWrapContinuationKeepsSameTextSize() {
        // Regression: wrap line 2 used to fall back to 28pt → GS ! double while line 1 stayed normal.
        var template = POSReceiptTemplate.makeBlank(name: "size")
        template.enableCode = false
        if let idx = template.elements.firstIndex(where: { $0.fieldKind == .name }) {
            template.elements[idx].fontSize = 18
            template.elements[idx].frame = SequencePlaceholderFrame(x: 12, y: 80, width: 278, height: 28)
        }
        // Long enough to wrap at 48 cols (CJK width 2).
        let name = String(repeating: "测", count: 30)
        let result = POSReceiptPrintComposer.compose(
            template: template,
            items: [POSLineItem(code: "", name: name, quantity: "", amount: "")],
            surcharge: "0",
            backgroundImage: nil,
            logoImages: [:],
            config: .default80mm
        )
        let payload = result.artifacts.payload
        // GS ! 0x11 = double; GS ! 0x00 = normal. 18pt → normal only.
        func countPattern(_ pattern: [UInt8]) -> Int {
            let needle = Data(pattern)
            var count = 0
            var search = payload.startIndex
            while search < payload.endIndex,
                  let r = payload[search...].range(of: needle) {
                count += 1
                search = r.upperBound
            }
            return count
        }
        XCTAssertEqual(countPattern([0x1D, 0x21, 0x11]), 0, "18pt name must not emit GS ! double on wrap continuations")
        XCTAssertGreaterThan(countPattern([0x1D, 0x21, 0x00]), 0)
    }

    /// Payload once split a 23-CJK name after 12 chars (24 cols) despite wrapCols=48 — char-grid bug.
    func testPOSNativeKeepsShortNameOnOneLine() {
        var template = POSReceiptTemplate.makeBlank(name: "oneline")
        template.enableCode = false
        if let idx = template.elements.firstIndex(where: { $0.fieldKind == .name }) {
            template.elements[idx].fontSize = 18
            template.elements[idx].frame = SequencePlaceholderFrame(x: 12, y: 140, width: 278, height: 40)
        }
        let name = "分社电光火石开个会开始大家都说了克己复礼看电视"
        XCTAssertEqual(name.count, 23)
        let result = POSReceiptPrintComposer.compose(
            template: template,
            items: [POSLineItem(code: "", name: name, quantity: "", amount: "")],
            surcharge: "0",
            backgroundImage: nil,
            logoImages: [:],
            config: .default80mm
        )
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        let gbk = try! XCTUnwrap(name.data(using: enc))
        XCTAssertNotNil(
            result.artifacts.payload.range(of: gbk),
            "name must appear contiguous in payload (no mid-name LF)"
        )
    }

    func testPOSNativeWrapUsesElementFontColumnsNotDoubleGrid() {
        let config = PrinterConfig.default80mm
        let paperW: CGFloat = 302
        let frame = SequencePlaceholderFrame(x: 12, y: 80, width: 278, height: 28)
        let name = "水电费水电费水电费水电费是"
        let wrapCols = SequenceLayoutComposer.wrapColumns(
            for: frame, fontSize: 18, config: config, paperWidthPoints: paperW
        )
        let printed = ReceiptTextLayout.wrap(name, maxColumns: wrapCols, asciiAsDoubleWidth: false)
        XCTAssertEqual(printed.count, 1, "18pt name must not re-wrap on 24-col double grid")
        XCTAssertGreaterThanOrEqual(wrapCols, 26)
        XCTAssertLessThanOrEqual(wrapCols, 48)
        let posMetrics = SequenceLayoutComposer.metricsForPOSPrint(
            config: config, paperWidthPoints: paperW
        )
        XCTAssertEqual(posMetrics.columns, 48)

        var template = POSReceiptTemplate.makeBlank(name: "wrap")
        template.enableCode = false
        if let idx = template.elements.firstIndex(where: { $0.fieldKind == .name }) {
            template.elements[idx].fontSize = 18
            template.elements[idx].frame = frame
        }
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: [POSLineItem(code: "", name: name, quantity: "", amount: "")],
            surcharge: "0",
            config: config
        )
        let placed = layout.texts.first { $0.text.contains("水电") }
        XCTAssertEqual(placed?.text.split(separator: "\n").count, 1)
    }

    func testPOSComposeUsesNativeTextNotFullPageRaster() {
        var template = POSReceiptTemplate.makeBlank(name: "native")
        template.enableCode = true
        template.lineSpacingExtraDots = 8
        let result = POSReceiptPrintComposer.compose(
            template: template,
            items: [POSLineItem(code: "A1", name: "测试项目", quantity: "1", amount: "10")],
            surcharge: "0",
            backgroundImage: nil,
            logoImages: [:],
            config: .default80mm
        )
        XCTAssertTrue(result.artifacts.usedNativeText)
        XCTAssertFalse(result.artifacts.usedRaster)
        XCTAssertTrue(
            result.artifacts.renderMode == .nativeText || result.artifacts.renderMode == .mixed
        )
        // FS & Chinese mode (native), not a whole-ticket GS v 0 bake of the preview.
        XCTAssertTrue(result.artifacts.payload.contains(Data([0x1C, 0x26])))
        // ESC 3 with base 30 + extra 8 = 38
        XCTAssertTrue(result.artifacts.payload.contains(Data([0x1B, 0x33, 38])))
        // GBK for 测 (0xB2E2) should appear in payload
        XCTAssertTrue(result.artifacts.payload.contains(Data([0xB2, 0xE2])))
        // USB first-packet pad (same as movie-ticket path).
        XCTAssertTrue(result.artifacts.payload.prefix(96).allSatisfy { $0 == 0 })
    }

    func testPOSTemplateCutFeedAppearsInPayload() {
        var template = POSReceiptTemplate.makeBlank(name: "cut-feed")
        template.feedLinesBeforeCut = 7
        var config = PrinterConfig.default80mm
        config.cutPaper = true
        config.feedLinesBeforeCut = 12
        let result = POSReceiptPrintComposer.compose(
            template: template,
            items: [POSLineItem(name: "A")],
            surcharge: "0",
            backgroundImage: nil,
            logoImages: [:],
            config: config
        )
        XCTAssertEqual(template.resolvedFeedLinesBeforeCut(config: config), 7)
        // ESC d n before cut
        XCTAssertTrue(result.artifacts.payload.contains(Data([0x1B, 0x64, 7])))
        XCTAssertFalse(result.artifacts.payload.contains(Data([0x1B, 0x64, 12])))
    }

    func testPOSLogoJobStartsWithUSBPaddingBeforeRaster() {
        let logoId = UUID()
        var template = POSReceiptTemplate.makeBlank(name: "logo-pad")
        var logoEl = POSReceiptElement(
            kind: .logo,
            frame: SequencePlaceholderFrame(x: 20, y: 16, width: 100, height: 60),
            ticketSection: .header
        )
        logoEl.id = logoId
        template.elements = [
            logoEl,
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 140, width: 200, height: 40),
                fieldKind: .name
            )
        ]
        let logo = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        let result = POSReceiptPrintComposer.compose(
            template: template,
            items: [POSLineItem(name: "示例")],
            surcharge: "0",
            backgroundImage: nil,
            logoImages: [logoId: logo],
            config: .default80mm
        )
        let payload = result.artifacts.payload
        XCTAssertTrue(payload.prefix(96).allSatisfy { $0 == 0 }, "96 NUL pad protects GS v 0 header")
        XCTAssertEqual(
            Array(payload.dropFirst(96).prefix(4)),
            [0x1B, 0x40, 0x1C, 0x2E],
            "raster init must follow padding"
        )
        XCTAssertTrue(payload.contains(Data([0x1D, 0x76, 0x30, 0x00])))
    }

    func testPOSFirstItemStartsBelowLogo() {
        var template = POSReceiptTemplate.makeBlank(name: "t")
        template.enableCode = true
        template.elements = [
            POSReceiptElement(
                kind: .logo,
                frame: SequencePlaceholderFrame(x: 20, y: 10, width: 100, height: 80)
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 40, width: 40, height: 28),
                fieldKind: .code
            ),
            POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 60, y: 40, width: 120, height: 28),
                fieldKind: .name
            )
        ]
        let printY = POSReceiptLayoutEngine.printRowY(template: template)
        XCTAssertGreaterThanOrEqual(printY, 10 + 80 + 4)
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: [
                POSLineItem(code: "1", name: "首条", quantity: "", amount: ""),
                POSLineItem(code: "2", name: "次条", quantity: "", amount: "")
            ],
            surcharge: "0"
        )
        let first = layout.texts.first { $0.text == "首条" }
        let second = layout.texts.first { $0.text == "次条" }
        XCTAssertEqual(first?.frame.y, printY)
        XCTAssertEqual(second?.frame.y, printY + POSReceiptLayoutEngine.itemPitch(template: template))
    }

    func testPOSTemplateRoundTripStoreIsolatesExcelMeta() throws {
        let store = POSReceiptTemplateStore()
        var a = POSReceiptTemplate.makeBlank(name: "A")
        a.excelDisplayName = "a.csv"
        a.excelCachedHeaders = ["编号", "项目"]
        a.excelColumnMap.codeHeader = "编号"
        store.saveMeta(a)

        var b = POSReceiptTemplate.makeBlank(name: "B")
        b.excelDisplayName = "b.csv"
        b.excelCachedHeaders = ["code", "name"]
        store.saveMeta(b)

        let loaded = store.loadAll()
        let la = loaded.first { $0.id == a.id }
        let lb = loaded.first { $0.id == b.id }
        XCTAssertEqual(la?.excelDisplayName, "a.csv")
        XCTAssertEqual(la?.excelColumnMap.codeHeader, "编号")
        XCTAssertEqual(lb?.excelDisplayName, "b.csv")
        XCTAssertNotEqual(la?.excelCachedHeaders, lb?.excelCachedHeaders)

        store.delete(a)
        store.delete(b)
    }

    func testPOSSurchargePercentAnnotation() {
        var template = POSReceiptTemplate.makeBlank(name: "附加费")
        template.elements.append(POSReceiptElement(
            kind: .fieldPlaceholder,
            frame: SequencePlaceholderFrame(x: 12, y: 200, width: 80, height: 28),
            fieldKind: .surcharge,
            ticketSection: .footer
        ))
        let layout = POSReceiptLayoutEngine.expand(
            template: template,
            items: [POSLineItem(code: "1", name: "A", quantity: "1", amount: "100")],
            surcharge: "10.00",
            surchargePercentLabel: "10%"
        )
        let surcharge = layout.texts.first { $0.text == "10.00" }
        XCTAssertEqual(surcharge?.annotation, "(10%)")
        let plain = POSReceiptLayoutEngine.expand(
            template: template,
            items: [POSLineItem(code: "1", name: "A", quantity: "1", amount: "100")],
            surcharge: "10.00",
            surchargePercentLabel: nil
        )
        XCTAssertNil(plain.texts.first { $0.text == "10.00" }?.annotation)
    }

    func testMovieTicketCountSerialAndSeats() {
        var draft = MovieTicketDraft.blank()
        draft.serialNumber = "477560/001"
        XCTAssertEqual(draft.serialBase, "477560")
        draft.setTicketCount(2)
        draft.seatModeUnallocated = false
        draft.seatAreas = ["K15", "K16"]
        draft.syncSeatArrays()

        let t0 = draft.draftForTicket(at: 0)
        let t1 = draft.draftForTicket(at: 1)
        XCTAssertEqual(t0.serialNumber, "477560/001")
        XCTAssertEqual(t1.serialNumber, "477560/002")
        XCTAssertEqual(t0.seatArea, "K15")
        XCTAssertEqual(t1.seatArea, "K16")
        XCTAssertEqual(draft.serialForTicket(at: 3), "477560/004")
    }

    func testMovieTicketEndTimeAndUnallocatedSeat() {
        var draft = MovieTicketDraft.blank(defaultAd: 15)
        var cal = Calendar.current
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 16; c.hour = 18; c.minute = 0
        let start = cal.date(from: c)!
        draft.showDate = cal.startOfDay(for: start)
        draft.showStartTime = start
        draft.movieDurationMinutes = 117
        draft.adDurationMinutes = 15
        draft.seatModeUnallocated = true
        draft.movieTitle = "Test"
        let end = draft.showEndTime
        XCTAssertEqual(cal.component(.hour, from: end), 20)
        XCTAssertEqual(cal.component(.minute, from: end), 12)

        var template = MovieTicketTemplate.makeRitz(name: "t")
        template.unallocatedSeatLabel = "ADMIT"
        let layout = MovieTicketLayoutEngine.expand(template: template, draft: draft)
        let seat = layout.texts.first { text in
            template.elements.contains { $0.fieldKind == .seatArea }
                && text.frame == template.elements.first { $0.fieldKind == .seatArea }?.frame
        }
        XCTAssertEqual(seat?.text, "ADMIT")
    }

    func testMovieTicketHallDisplayModes() throws {
        var draft = MovieTicketDraft.blank()
        draft.hall = "Screen 2"
        var el = MovieTicketElement(
            kind: .fieldPlaceholder,
            frame: SequencePlaceholderFrame(x: 0, y: 0, width: 100, height: 20),
            fieldKind: .hall
        )
        XCTAssertEqual(el.resolvedHallText(from: draft), "Cinema 2")

        el.hallDisplayMode = .numberOnly
        XCTAssertEqual(el.resolvedHallText(from: draft), "2")

        el.hallDisplayMode = .customPrefix
        el.hallNumberPrefix = "Screen"
        XCTAssertEqual(el.resolvedHallText(from: draft), "Screen 2")

        // Round-trip without hallNumberPrefix key (legacy templates).
        var legacy = el
        legacy.hallNumberPrefix = nil
        let encoded = try JSONEncoder().encode(legacy)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        var stripped = obj ?? [:]
        stripped.removeValue(forKey: "hallNumberPrefix")
        stripped.removeValue(forKey: "hallDisplayMode")
        let legacyData = try JSONSerialization.data(withJSONObject: stripped)
        let decoded = try JSONDecoder().decode(MovieTicketElement.self, from: legacyData)
        XCTAssertEqual(decoded.fieldKind, .hall)
        XCTAssertNil(decoded.hallNumberPrefix)

        el.hallDisplayMode = .asRecognized
        XCTAssertEqual(el.resolvedHallText(from: draft), "Screen 2")

        draft.hall = "IMAX 1"
        el.hallDisplayMode = .cinemaNumber
        XCTAssertEqual(el.resolvedHallText(from: draft), "Cinema 1")
    }

    func testMovieTicketMakeBlankIsEmpty() {
        let blank = MovieTicketTemplate.makeBlank(name: "新影票模板")
        XCTAssertTrue(blank.elements.isEmpty)
        XCTAssertFalse(blank.usesRitzLayout)
        XCTAssertFalse(blank.usesIMAXSydneyLayout)
        let ritz = MovieTicketTemplate.makeRitz(name: "示例影票")
        XCTAssertFalse(ritz.elements.isEmpty)
        XCTAssertTrue(ritz.usesRitzLayout)
        XCTAssertTrue(ritz.elements.contains { $0.fieldKind == .movieTitle })
    }

    func testMovieTicketRelativeRectClamped() {
        let r = MovieTicketRelativeRect(x: -0.1, y: 0.9, width: 0.5, height: 0.5).clamped()
        XCTAssertGreaterThanOrEqual(r.x, 0)
        XCTAssertLessThanOrEqual(r.x + r.width, 1.0001)
        XCTAssertLessThanOrEqual(r.y + r.height, 1.0001)
    }

    func testMovieTicketPDFKeywordMatch() {
        let rule = MovieTicketPDFRule(name: "Ritz", detectorKeywords: ["ritz", "The Ritz"])
        let hits = MovieTicketPDFRecognitionService.matchRules(
            text: "Welcome to The Ritz Cinemas",
            rules: [rule]
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(
            MovieTicketPDFRecognitionService.matchRules(text: "Orpheum only", rules: [rule]).isEmpty
        )
    }

    /// Dendy / Event style: "Thursday, July 9 Stratford, 6:00 pm" — US month-day order.
    func testShowDateRecognizesUSWeekdayMonthDay() {
        let page = """
        THANK YOU FOR YOUR ORDER!
        TICKETS
        The Dark Knight
        Thursday, July 9 Stratford, 6:00 pm (Ends at 8:52 pm)
        X 1 Cinema 3 Row G Seat 7
        Adult Event
        """
        let date = MovieTicketPDFRecognitionService.dateOnly(from: page)
        XCTAssertEqual(date, "Thursday, July 9")
        XCTAssertNil(MovieTicketPDFRecognitionService.dateOnly(from: "The Dark Knight"))
    }

    /// Dendy web PDF: show line "July 23rd…" must win over purchase "July 22, 2026 10:27 am".
    func testDendyShowDatePrefersShowingLineOverPurchaseTimestamp() {
        let page = """
        SHOWING
        Membership
        A Clockwork Orange
        View & manage membership
        July 23rd, 6:15 pm (Ends at 8:52 pm)
        Account Information
        x 1 Cinema 3 Retro Film
        CARD VISA ...3450 $23.95
        TOTAL $23.95
        July 22, 2026 10:27 am
        """
        XCTAssertEqual(
            MovieTicketPDFRecognitionService.dateOnly(from: page),
            "July 23rd"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.endTime, text: page),
            "8:52 pm"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.startTime, text: page),
            "6:15 pm"
        )
    }

    func testEndTimeIsPDFExtractableAndAppliesDuration() {
        XCTAssertTrue(MovieTicketFieldKind.endTime.isPDFExtractable)

        var draft = MovieTicketDraft.blank(defaultAd: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var day = DateComponents()
        day.year = 2026; day.month = 7; day.day = 9
        if let d = cal.date(from: day) { draft.showDate = d }
        var time = DateComponents()
        time.hour = 18; time.minute = 0
        if let t0 = cal.date(from: time) { draft.showStartTime = t0 }

        MovieTicketPDFRecognitionService.apply(
            fields: [.endTime: "Ends at 8:52 pm"],
            to: &draft
        )
        let end = draft.showEndTime
        XCTAssertEqual(cal.component(.hour, from: end), 20)
        XCTAssertEqual(cal.component(.minute, from: end), 52)
        XCTAssertEqual(draft.movieDurationMinutes, 172)
    }

    func testEventDendyPageTextDetectors() {
        let page = """
        THANK YOU FOR YOUR ORDER!
        TICKETS
        The Dark Knight
        Thursday, July 9 Stratford, 6:00 pm (Ends at 8:52 pm)
        X 1 Cinema 3 Row G Seat 7
        Adult Event
        Club 25% Off Ticket
        """
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "The Dark Knight"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.hall, text: page),
            "Cinema 3"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.seatArea, text: page),
            "G7"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.ticketType, text: page),
            "Adult Event"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.showDate, text: page),
            "Thursday, July 9"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.endTime, text: page),
            "8:52 pm"
        )
    }

    /// Web confirmation PDF: title sits above the SHOWING label (not SHOWING itself).
    func testWebTicketTitleAboveShowingLabel() {
        let page = """
        Tax invoice Thank you for your order!
        The Dark Knight
        SHOWING
        Wednesday, July 22, 2026 6:15 pm (Ends at 8:52 pm)
        X 1 Cinema 3 Row H Seat 3
        Adult Event
        """
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "The Dark Knight"
        )
        XCTAssertNotEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "SHOWING"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.hall, text: page),
            "Cinema 3"
        )
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.seatArea, text: page),
            "H3"
        )
    }

    /// Blank lines / chrome between title and SHOWING must not block detection.
    func testWebTicketTitleWithGapsAboveShowing() {
        let page = """
        LOGOUT HOME Tax invoice Thank you for your order!
        Orders
        Hi, XIAOYU

        The Dark Knight

        SHOWING
        July 22, 2026 6:15 pm
        Cinema 3
        """
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "The Dark Knight"
        )
    }

    /// Nav label "Account Overview" must lose to the real title near SHOWING.
    func testWebTicketRejectsAccountOverviewAsTitle() {
        let page = """
        Account Overview
        Orders
        Tax invoice Thank you for your order!

        The Dark Knight
        SHOWING
        July 22, 2026 6:15 pm (Ends at 8:52 pm)
        X 1 Cinema 3 Row H Seat 3
        Adult Event
        """
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "The Dark Knight"
        )
        XCTAssertFalse(
            (MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page) ?? "")
                .localizedCaseInsensitiveContains("Account")
        )
    }

    /// Some PDFs emit title after SHOWING before the clock line.
    func testWebTicketTitleBelowShowingBeforeClock() {
        let page = """
        Account Overview
        SHOWING
        The Dark Knight
        July 22, 2026 6:15 pm
        Cinema 3
        """
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "The Dark Knight"
        )
    }

    /// Runtime evidence: "👋 Hi, XIAOYU" scored above "A Clockwork Orange" — must prefer the film.
    func testWebTicketPrefersClockworkOrangeOverGreeting() {
        let page = """
        Current Upcoming
        👋 Hi, XIAOYU
        order!
        SHOWING
        A Clockwork Orange
        View & manage membership
        July 22, 2026 6:15 pm
        Cinema 3
        """
        XCTAssertEqual(
            MovieTicketPDFFieldRecognizer.detectFromPageText(.movieTitle, text: page),
            "A Clockwork Orange"
        )
    }

    func testOrpheumOrderSummaryTotalNotTax() {
        // Orpheum Order Summary: integer Total, tax on the next line — must not return 2.64.
        let page = """
        Order Summary
        28/09/2025 10:50:17 AM
        1 x Bookingfee 2.5
        1 x To Live To Live | C4 Orpheum 26.5
        Total 29
        Including Tax 2.64
        """
        XCTAssertEqual(
            MovieTicketPDFRecognitionService.totalCurrency(fromPageText: page),
            "29"
        )

        let withCents = """
        Total (inc. GST) $45.00
        GST $4.09
        """
        XCTAssertEqual(
            MovieTicketPDFRecognitionService.totalCurrency(fromPageText: withCents),
            "$45.00"
        )
    }

    func testOrpheumTemplateLayoutAndCompose() {
        let template = MovieTicketTemplate.makeOrpheum()
        XCTAssertEqual(template.name, "Orpheum")
        XCTAssertTrue(template.usesOrpheumLayout)
        XCTAssertFalse(template.usesRitzLayout)
        XCTAssertEqual(template.layoutStyle, "orpheum")
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .hall && $0.isInverted })
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .movieTitle })
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .barcode })
        XCTAssertTrue(template.elements.contains {
            $0.kind == .textBox && $0.content.localizedCaseInsensitiveContains("Orpheum")
        })

        let draft = MovieTicketDraft.orpheumSample().draftForTicket(at: 0)
        let config = PrinterConfig()
        let result = MovieTicketPrintComposer.compose(
            template: template,
            draft: draft,
            backgroundImage: nil,
            config: config
        )
        XCTAssertFalse(result.artifacts.payload.isEmpty)
        XCTAssertGreaterThan(result.previewImage.size.width, 0)
        XCTAssertTrue(result.artifacts.printerModelHint?.contains("Orpheum") == true)
    }

    func testDendyTemplateLayoutAndCompose() {
        let template = MovieTicketTemplate.makeDendy()
        XCTAssertEqual(template.name, "Dendy")
        XCTAssertTrue(template.usesDendyLayout)
        XCTAssertFalse(template.usesRitzLayout)
        XCTAssertFalse(template.usesOrpheumLayout)
        XCTAssertEqual(template.layoutStyle, "dendy")
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .movieTitle })
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .qrCode })
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .hall && $0.hallDisplayMode == .cinemaNumber })
        XCTAssertTrue(template.elements.contains {
            $0.fieldKind == .serialNumber && ($0.content.contains("Code") || $0.content.contains("#"))
        })

        let draft = MovieTicketDraft.dendySample().draftForTicket(at: 0)
        XCTAssertEqual(draft.movieTitle, "The Testament of Ann Lee")
        XCTAssertEqual(draft.bookingCode, "6924686")
        let config = PrinterConfig()
        let result = MovieTicketPrintComposer.compose(
            template: template,
            draft: draft,
            backgroundImage: nil,
            config: config
        )
        XCTAssertFalse(result.artifacts.payload.isEmpty)
        XCTAssertGreaterThan(result.previewImage.size.height, 100)
        XCTAssertTrue(result.artifacts.printerModelHint?.contains("Dendy") == true)

        let payload = result.artifacts.payload
        XCTAssertTrue(payload.contains(Data("Cinema 3".utf8)))
        XCTAssertTrue(payload.contains(Data("Seat F7".utf8)))
        XCTAssertTrue(payload.contains(Data("Adult Event".utf8)))
        XCTAssertTrue(payload.contains(Data("Code: #6924686".utf8)))
        XCTAssertTrue(payload.contains(Data("Ticket #466713335".utf8)))
        XCTAssertTrue(payload.contains(Data("Ends at ".utf8)))

        // Cinema/seat at stock 2×3 (GS ! 0x12) fits one line; title mirrors that.
        let titleEl = template.elements.first { $0.fieldKind == .movieTitle }!
        let hallEl = template.elements.first { $0.fieldKind == .hall }!
        let titleScale = MovieTicketRitzESCPOS.printScale(
            fontSize: titleEl.fontSize, boxHeight: titleEl.frame.height
        )
        let hallScale = MovieTicketRitzESCPOS.printScale(
            fontSize: hallEl.fontSize, boxHeight: hallEl.frame.height
        )
        XCTAssertEqual(titleScale.width, 2)
        XCTAssertEqual(titleScale.height, 3)
        XCTAssertEqual(hallScale.width, 2)
        XCTAssertEqual(hallScale.height, 3)
        // GS ! n = ((w-1)<<4) | (h-1) → 2×3 = 0x12
        XCTAssertTrue(payload.contains(Data([0x1D, 0x21, 0x12])))
        XCTAssertFalse(payload.contains(Data([0x1D, 0x21, 0x22])))

        // Session date includes year.
        let year = Calendar.current.component(.year, from: draft.showDate)
        XCTAssertTrue(payload.contains(Data(", \(year), ".utf8)) || payload.contains(Data("\(year),".utf8)))

        var small = template
        for kind: MovieTicketFieldKind in [.movieTitle, .hall, .seatArea] {
            if let i = small.elements.firstIndex(where: { $0.fieldKind == kind }) {
                small.elements[i].fontSize = 11
                small.elements[i].frame.height = 13
            }
        }
        let smallPayload = MovieTicketPrintComposer.compose(
            template: small,
            draft: draft,
            backgroundImage: nil,
            config: config
        ).artifacts.payload
        // 1×1 on title/cinema → no 3×3; code line may still emit 2×2.
        XCTAssertTrue(smallPayload.contains(Data([0x1D, 0x21, 0x00])))
        XCTAssertFalse(smallPayload.contains(Data([0x1D, 0x21, 0x22])))
    }

    func testIMAXSydneyTemplateLayoutAndCompose() {
        let made = MovieTicketTemplate.makeIMAXSydney()
        let template = made.template
        XCTAssertEqual(template.name, "IMAX SYDNEY")
        XCTAssertTrue(template.usesIMAXSydneyLayout)
        XCTAssertEqual(template.layoutStyle, "imaxSydney")
        XCTAssertTrue(template.elements.contains { $0.id == made.logoElementId && $0.kind == .logo })
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .barcode })
        XCTAssertTrue(template.elements.contains { $0.fieldKind == .seatArea })

        let draft = MovieTicketDraft.imaxSydneySample().draftForTicket(at: 0)
        let config = PrinterConfig()
        let result = MovieTicketPrintComposer.compose(
            template: template,
            draft: draft,
            backgroundImage: nil,
            logoImages: [:],
            config: config
        )
        XCTAssertFalse(result.artifacts.payload.isEmpty)
        XCTAssertGreaterThan(result.previewImage.size.height, 100)
        XCTAssertTrue(result.artifacts.printerModelHint?.contains("IMAX") == true)

        // Meta must not wrap on Font A leftovers — payload uses Font B path + tight `d:`.
        let payload = result.artifacts.payload
        let meta = "EFTP | T/N: 536011/001 | d:16072026 1740 | u:9613"
        XCTAssertTrue(
            String(decoding: payload, as: UTF8.self).contains("EFTP")
                || payload.contains(Data(meta.utf8))
                || payload.contains(Data("536011/001".utf8))
        )
    }

    func testPrintedMovieTitleAppendsRatingOnlyWhenToggleOn() {
        var draft = MovieTicketDraft(movieTitle: "The Bride!", contentRating: "M")
        XCTAssertEqual(draft.printedMovieTitle(using: []), "The Bride!")
        draft.printContentRating = true
        XCTAssertEqual(draft.printedMovieTitle(using: []), "The Bride! (M)")
        // Avoid doubling if already present
        draft.movieTitle = "The Bride! (M)"
        XCTAssertEqual(draft.printedMovieTitle(using: []), "The Bride! (M)")
    }

    func testContentRatingPrintMappingShortensMA15() {
        let mappings = MovieTicketRatingPrintMapping.defaults
        XCTAssertEqual(MovieTicketRatingPrintMapping.printLabel(for: "MA 15+", mappings: mappings), "MA15")
        XCTAssertEqual(MovieTicketRatingPrintMapping.printLabel(for: "ma15+", mappings: mappings), "MA15")
        XCTAssertEqual(MovieTicketRatingPrintMapping.printLabel(for: "PG", mappings: mappings), "PG")
        let draft = MovieTicketDraft(movieTitle: "The Bride!", contentRating: "MA 15+", printContentRating: true)
        XCTAssertEqual(draft.printedMovieTitle(using: mappings), "The Bride! (MA15)")
    }

    func testTMDBPreferredCertificationPrefersAU() {
        let payload = TMDBReleaseDatesPayload(results: [
            TMDBReleaseCountry(iso3166: "US", releaseDates: [TMDBReleaseDateEntry(certification: "R")]),
            TMDBReleaseCountry(iso3166: "AU", releaseDates: [TMDBReleaseDateEntry(certification: "M")]),
            TMDBReleaseCountry(iso3166: "GB", releaseDates: [TMDBReleaseDateEntry(certification: "15")])
        ])
        XCTAssertEqual(TMDBMovieMetadataProvider.preferredCertification(from: payload), "M")
    }
}
