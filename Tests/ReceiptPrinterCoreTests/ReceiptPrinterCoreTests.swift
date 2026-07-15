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
}
