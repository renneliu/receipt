import XCTest
@testable import ReceiptPrinter

final class ReceiptPrinterCoreTests: XCTestCase {
    func testGmailTimeRangeSevenDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clause = GmailTimeRange.sevenDays.afterClause(now: now)
        XCTAssertNotNil(clause)
        XCTAssertTrue(clause?.hasPrefix("after:") == true)
    }

    func testGmailTimeRangeAnyIsEmpty() {
        XCTAssertNil(GmailTimeRange.any.queryFragment())
    }

    func testComposedGmailExtraQueryMergesParts() {
        var settings = AppSettings()
        settings.gmailTimeRange = .sevenDays
        settings.gmailFilter.senderContains = "orpheum"
        settings.gmailSearchQuery = "is:unread"
        let query = settings.composedGmailExtraQuery(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(query.contains("after:"))
        XCTAssertTrue(query.contains("from:"))
        XCTAssertTrue(query.contains("is:unread"))
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

    func testEmailExtractionAnchor() {
        let body = "Movie: Dunkirk\nHall: 4\nPrice: $28"
        let field = EmailExtractionField(
            id: "hall",
            label: "Hall",
            strategy: .anchorBeforeAfter(before: "Hall: ", after: "\n")
        )
        let value = EmailExtractionEngine.extractField(field, from: body)
        XCTAssertEqual(value, "4")
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
        XCTAssertEqual(Double(subtotal?.frame.y ?? 0), 100 + 28, accuracy: 0.1)
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
        let footer = layout.texts.first { $0.text == "页脚备注" }
        let header = layout.texts.first { $0.text == "页眉误放" }
        XCTAssertEqual(Double(footer?.frame.y ?? -1), 40 + Double(pitch), accuracy: 0.1)
        XCTAssertEqual(Double(header?.frame.y ?? -1), 200, accuracy: 0.1)
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
}
