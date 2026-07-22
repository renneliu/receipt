import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Excel / CSV row-sequence printing: rich-text body + draggable column placeholders.
/// Print: software-composite bitmap → `initializeForRaster` + GS v 0 (no Chinese mode).
struct SpreadsheetSequencePrintView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var editorController = RichTextEditorController()
    @State private var attributedText = NSAttributedString(
        string: "",
        attributes: AttributedTextView.defaultTypingAttributes()
    )
    @State private var placeholders: [SequencePlaceholder] = []
    @State private var selectedPlaceholderID: UUID?
    @State private var selectedRowIndex: Int = 0
    @State private var isPrinting = false
    @State private var message = ""
    @State private var previewPayload: QuickPrintPreviewPayload?
    @State private var editorFontSize: Double = AttributedTextView.defaultFontSize
    @State private var spreadsheet: SpreadsheetTable?
    @State private var importInfo = ""
    @State private var isSequencePrinting = false
    @State private var sequenceProgress = ""
    @State private var showSaveSheet = false
    @State private var saveName = ""
    @State private var showLoadSheet = false
    @State private var savedTemplates: [(document: SpreadsheetSequenceDocument, body: NSAttributedString)] = []
    @State private var documentID = UUID()
    @State private var backgroundImage: NSImage?
    @State private var backgroundScalePercent: Double = 100
    @State private var logos: [SequenceLogoItem] = []
    @State private var logoImages: [UUID: NSImage] = [:]
    @State private var selectedLogoID: UUID?
    /// Live NSTextView usedRect height (embed mode); corrects soft-wrap measure underestimates.
    @State private var liveEditorHeight: CGFloat = 0

    private let draftStore = QuickPrintStore(filename: "spreadsheet-sequence-draft.rtfd")
    private let templateStore = SequenceTemplateStore()
    private let paperCanvasMinHeight: CGFloat = 480

    private var columns: Int { appState.settings.printerConfig.columnsPerLine }

    private var paperWidth: CGFloat {
        AttributedTextView.editorPaperWidth(
            config: appState.settings.printerConfig,
            fontSize: CGFloat(editorFontSize)
        )
    }

    /// Canvas / ticket design height: max(Enter rows, soft-wrap ink, live layout, overlays).
    private var documentHeight: CGFloat {
        let fontSize = CGFloat(editorFontSize)
        let newlineCount = newlineLineCount(in: attributedText.string)
        let newlineH = heightForNewlineCount(newlineCount, fontSize: fontSize)
        let softWrapH = AttributedTextView.measureEditorHeight(
            attributedString: attributedText,
            config: appState.settings.printerConfig,
            fontSize: fontSize
        )
        let logoBottom = logos.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let phBottom = placeholders.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let overlayBottom = max(logoBottom, phBottom)
        return max(
            paperCanvasMinHeight,
            newlineH,
            softWrapH,
            liveEditorHeight,
            overlayBottom + 40
        )
    }

    private func newlineLineCount(in text: String) -> Int {
        if text.isEmpty { return 1 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Height of N hard lines (one Enter = one row), matching editor typography.
    private func heightForNewlineCount(_ count: Int, fontSize: CGFloat) -> CGFloat {
        let n = max(1, count)
        let attrs = AttributedTextView.defaultTypingAttributes(fontSize: fontSize)
        // Trailing space keeps the last empty line measurable.
        let stub = String(repeating: "\n", count: n - 1) + " "
        let measured = AttributedTextView.measureEditorHeight(
            attributedString: NSAttributedString(string: stub, attributes: attrs),
            config: appState.settings.printerConfig,
            fontSize: fontSize
        )
        return measured
    }

    private var caretDocumentY: CGFloat {
        guard let tv = editorController.textView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else {
            return documentHeight
        }
        let sel = tv.selectedRange()
        let glyph = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
        rect.origin.y += tv.textContainerOrigin.y
        return min(documentHeight, max(0, rect.maxY))
    }

    private var canvasSize: CGSize {
        CGSize(width: paperWidth, height: documentHeight)
    }

    private var pageMedia: RichTextPrintRenderer.SequencePageMedia {
        let layers = logos
            .sorted { $0.zIndex < $1.zIndex }
            .compactMap { item -> RichTextPrintRenderer.SequenceLogoLayer? in
                guard let image = logoImages[item.id] else { return nil }
                return .init(image: image, frame: item.frame)
            }
        return RichTextPrintRenderer.SequencePageMedia(
            background: backgroundImage,
            backgroundScalePercent: backgroundScalePercent,
            logos: layers,
            canvasSize: canvasSize
        )
    }

    private var selectedPlaceholder: SequencePlaceholder? {
        placeholders.first { $0.id == selectedPlaceholderID }
    }

    private var currentRowValues: [String: String] {
        guard let sheet = spreadsheet, !sheet.rows.isEmpty else { return [:] }
        let idx = min(max(0, selectedRowIndex), sheet.rows.count - 1)
        return mergeValues(headers: sheet.headers, row: sheet.rows[idx])
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    HStack {
                        Spacer(minLength: 0)
                        paperCanvas
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footerBar
            }
            .frame(minWidth: 480)

            sidePanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
        .navigationTitle(L10n.ui("Excel表格序列打印"))
        .onAppear {
            loadSavedContent()
            loadDraftMedia()
        }
        .onChange(of: attributedText) { _, newValue in
            draftStore.save(newValue)
        }
        .onChange(of: placeholders) { _, _ in
            persistDraftMedia()
        }
        .onChange(of: logos) { _, _ in
            persistDraftMedia()
        }
        .onChange(of: backgroundScalePercent) { _, _ in
            persistDraftMedia()
        }
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
        .sheet(isPresented: $showSaveSheet) {
            saveTemplateSheet
        }
        .sheet(isPresented: $showLoadSheet) {
            loadTemplateSheet
        }
    }

    private var paperCanvas: some View {
        let height = documentHeight
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    if let bg = backgroundImage {
                        let fitted = RichTextPrintRenderer.fitCenterRect(
                            imageSize: bg.size,
                            in: NSRect(x: 0, y: 0, width: paperWidth, height: height)
                        )
                        let p = max(SequenceLogoItem.minScalePercent, min(SequenceLogoItem.maxScalePercent, backgroundScalePercent)) / 100
                        let w = fitted.width * p
                        let h = fitted.height * p
                        Image(nsImage: bg)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: w, height: h)
                            .position(x: paperWidth / 2, y: height / 2)
                            .allowsHitTesting(false)
                    }

                    AttributedTextView(
                        attributedString: $attributedText,
                        printerConfig: appState.settings.printerConfig,
                        editorFontSize: CGFloat(editorFontSize),
                        clearCanvasBackground: backgroundImage != nil,
                        disablesInternalVerticalScroll: true,
                        onLaidOutContentHeight: { laidOut in
                            if abs(laidOut - liveEditorHeight) > 0.5 {
                                liveEditorHeight = laidOut
                            }
                        },
                        onTextViewReady: { textView in
                            editorController.textView = textView
                        }
                    )
                    .frame(width: paperWidth, height: height)

                    ZStack {
                        ForEach(Array(logos.enumerated()), id: \.element.id) { index, item in
                            if let image = logoImages[item.id] {
                                LogoBoxOverlay(
                                    title: "Logo \(index + 1)",
                                    image: image,
                                    frame: bindingLogoFrame(id: item.id),
                                    isSelected: Binding(
                                        get: { selectedLogoID == item.id },
                                        set: { selected in
                                            if selected {
                                                selectedLogoID = item.id
                                                selectedPlaceholderID = nil
                                            } else if selectedLogoID == item.id {
                                                selectedLogoID = nil
                                            }
                                        }
                                    ),
                                    paperSize: canvasSize,
                                    onFrameChanged: {
                                        syncLogoScaleFromFrame(id: item.id)
                                    },
                                    onDelete: { removeLogo(id: item.id) }
                                )
                            }
                        }
                    }
                    .frame(width: paperWidth, height: height)

                    PlaceholderBoxOverlay(
                        placeholders: $placeholders,
                        selectedID: $selectedPlaceholderID,
                        values: currentRowValues,
                        paperSize: canvasSize,
                        printerConfig: appState.settings.printerConfig,
                        fontSize: CGFloat(editorFontSize)
                    )
                    .frame(width: paperWidth, height: height)
                    .onChange(of: selectedPlaceholderID) { _, newID in
                        if newID != nil { selectedLogoID = nil }
                    }

                    // Anchor for scrolling the caret into the outer ScrollView.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(x: 8, y: caretDocumentY)
                        .id("caret-anchor")
                }
                .frame(width: paperWidth, height: height)
                .background(Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .id("doc-top")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: attributedText) { _, _ in
                // Keep typing caret visible when Enters grow the document past the viewport.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("caret-anchor", anchor: .center)
                    }
                }
            }
        }
    }

    private var sidePanel: some View {
        Form {
            Section(L10n.ui("文本格式")) {
                RichTextToolbar(
                    controller: editorController,
                    columnsPerLine: columns,
                    fontSize: $editorFontSize
                )
            }

            Section(L10n.ui("导入表格")) {
                Text(L10n.ui("导入 CSV/XLSX 后会按列自动创建可拖动占位框。打印为软件合成位图（无中文模式），避免混排乱码。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.ui("导入 Excel / CSV…")) {
                    importSpreadsheet()
                }
                if let sheet = spreadsheet {
                    Text("已导入 \(sheet.rows.count) 行 · \(sheet.headers.count) 列")
                        .font(.caption)
                    Text(sheet.headers.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !importInfo.isEmpty {
                    Text(importInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.ui("版面图片")) {
                Text(L10n.ui("背景在文字下方（等比居中，可用百分比缩放）；彩色 Logo/背景导入时自动转为黑白以保证热敏清晰。可添加多个 Logo。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(backgroundImage == nil ? L10n.ui("添加背景图…") : L10n.ui("更换背景图…")) {
                        pickImage { img in
                            backgroundImage = ImagePreprocessor.toBinaryBlackWhite(img)
                            backgroundScalePercent = 100
                            persistDraftMedia()
                        }
                    }
                    if backgroundImage != nil {
                        Button(L10n.ui("清除背景"), role: .destructive) {
                            backgroundImage = nil
                            backgroundScalePercent = 100
                            persistDraftMedia()
                        }
                    }
                }
                if backgroundImage != nil {
                    HStack(spacing: 8) {
                        Text(L10n.ui("背景大小"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            "",
                            value: Binding(
                                get: { backgroundScalePercent },
                                set: { setBackgroundScale($0) }
                            ),
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 52)
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: Binding(
                                get: { backgroundScalePercent },
                                set: { setBackgroundScale($0) }
                            ),
                            in: SequenceLogoItem.minScalePercent...SequenceLogoItem.maxScalePercent,
                            step: 5
                        )
                        .labelsHidden()
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
                Button(L10n.ui("添加 Logo…")) {
                    pickImage { img in
                        addLogo(img)
                    }
                }
                if !logos.isEmpty {
                    ForEach(Array(logos.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button {
                                    selectedLogoID = item.id
                                    selectedPlaceholderID = nil
                                } label: {
                                    Text("Logo \(index + 1)")
                                        .fontWeight(selectedLogoID == item.id ? .semibold : .regular)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button(L10n.ui("删除"), role: .destructive) {
                                    removeLogo(id: item.id)
                                }
                                .controlSize(.small)
                            }
                            HStack(spacing: 8) {
                                Text(L10n.ui("大小"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "",
                                    value: Binding(
                                        get: { logos.first(where: { $0.id == item.id })?.scalePercent ?? 100 },
                                        set: { setLogoScale(id: item.id, percent: $0) }
                                    ),
                                    format: .number.precision(.fractionLength(0))
                                )
                                .frame(width: 52)
                                Text("%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { logos.first(where: { $0.id == item.id })?.scalePercent ?? 100 },
                                        set: { setLogoScale(id: item.id, percent: $0) }
                                    ),
                                    in: SequenceLogoItem.minScalePercent...SequenceLogoItem.maxScalePercent,
                                    step: 5
                                )
                                .labelsHidden()
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedLogoID == item.id ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08))
                        )
                    }
                    Button(L10n.ui("清除全部 Logo"), role: .destructive) {
                        clearAllLogos()
                    }
                }
            }

            if let sheet = spreadsheet, !sheet.headers.isEmpty {
                Section(L10n.ui("添加占位框")) {
                    FlowLayout(spacing: 6) {
                        ForEach(sheet.headers, id: \.self) { header in
                            let name = header.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                Button(name) {
                                    addPlaceholder(bindingKey: name)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    Text(L10n.ui("也可在正文插入 {{列名}} 令牌："))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(sheet.headers, id: \.self) { header in
                            let name = header.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                Button("{{\(name)}}") {
                                    editorController.insertPlaceholder(fieldName: name)
                                    syncEditorToState()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            if !placeholders.isEmpty {
                Section(L10n.ui("占位框")) {
                    ForEach(placeholders) { box in
                        HStack {
                            Button {
                                selectedPlaceholderID = box.id
                            } label: {
                                HStack {
                                    Image(systemName: selectedPlaceholderID == box.id
                                          ? "checkmark.square.fill"
                                          : "square")
                                    Text(box.bindingKey)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) {
                                deletePlaceholder(id: box.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除「\(box.bindingKey)」")
                        }
                    }
                    if selectedPlaceholder != nil {
                        Button(L10n.ui("删除选中占位框"), role: .destructive) {
                            if let id = selectedPlaceholderID {
                                deletePlaceholder(id: id)
                            }
                        }
                    }
                }
            }

            if let box = selectedPlaceholder, let sheet = spreadsheet {
                Section("序列内容 · \(box.bindingKey)") {
                    Text(L10n.ui("点选一行可在编辑区预览该行；数值可直接修改。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(sheet.rows.indices), id: \.self) { rowIndex in
                        sequenceRowEditor(rowIndex: rowIndex, bindingKey: box.bindingKey)
                    }
                }
            } else if spreadsheet != nil {
                Section(L10n.ui("序列内容")) {
                    Text(L10n.ui("点选画布上的占位框后，这里显示该列各行数据。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sheet = spreadsheet, !sheet.rows.isEmpty {
                        Picker(L10n.ui("预览行"), selection: $selectedRowIndex) {
                            ForEach(Array(sheet.rows.indices), id: \.self) { i in
                                Text("第 \(i + 1) 行").tag(i)
                            }
                        }
                    }
                }
            }

            Section(L10n.ui("模板")) {
                Button(L10n.ui("存为模板…")) {
                    saveName = "序列打印 \(Date().formatted(date: .abbreviated, time: .shortened))"
                    showSaveSheet = true
                }
                .disabled(attributedText.length == 0 && placeholders.isEmpty && backgroundImage == nil && logos.isEmpty)
                Button(L10n.ui("载入模板…")) {
                    savedTemplates = templateStore.loadAll()
                    showLoadSheet = true
                }
            }

            Section(L10n.ui("打印")) {
                Button(isPrinting ? L10n.ui("打印中…") : L10n.ui("打印当前 (⌘↩)")) {
                    Task { await printCurrent() }
                }
                .disabled(isPrinting || isSequencePrinting || appState.settings.selectedPrinterName == nil)
                .keyboardShortcut(.return, modifiers: .command)
                Button(isSequencePrinting ? L10n.ui("打印中…") : L10n.ui("打印序列")) {
                    Task { await sequencePrintAll() }
                }
                .disabled(
                    isSequencePrinting
                        || isPrinting
                        || appState.settings.selectedPrinterName == nil
                        || spreadsheet?.isEmpty != false
                )
                if !sequenceProgress.isEmpty {
                    Text(sequenceProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private func sequenceRowEditor(rowIndex: Int, bindingKey: String) -> some View {
        let selected = selectedRowIndex == rowIndex
        return HStack(alignment: .center, spacing: 8) {
            Text("\(rowIndex + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            TextField(
                L10n.ui("值"),
                text: Binding(
                    get: { cellValue(row: rowIndex, key: bindingKey) },
                    set: { setCellValue(row: rowIndex, key: bindingKey, value: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowIndex = rowIndex
        }
    }

    private var footerBar: some View {
        HStack {
            if let printer = appState.settings.selectedPrinterName {
                Text("打印机: \(printer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.ui("请先在「设置」中选择 CUPS 打印机"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.ui("清空")) { clearContent() }
            Button(L10n.ui("预览")) {
                Task { await previewCurrent() }
            }
            Button(isPrinting ? L10n.ui("打印中...") : L10n.ui("打印当前 (⌘↩)")) {
                Task { await printCurrent() }
            }
            .disabled(isPrinting || appState.settings.selectedPrinterName == nil)
            Button(isSequencePrinting ? L10n.ui("打印中…") : L10n.ui("打印序列")) {
                Task { await sequencePrintAll() }
            }
            .disabled(
                isSequencePrinting
                    || appState.settings.selectedPrinterName == nil
                    || spreadsheet?.isEmpty != false
            )
        }
        .padding()
        .background(.bar)
    }

    private var saveTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.ui("存为模板")).font(.headline)
            TextField(L10n.ui("模板名称"), text: $saveName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.ui("取消")) { showSaveSheet = false }
                Button(L10n.ui("保存")) {
                    saveAsTemplate()
                    showSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var loadTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.ui("载入模板")).font(.headline)
            if savedTemplates.isEmpty {
                Text(L10n.ui("暂无已存模板"))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(savedTemplates, id: \.document.id) { item in
                        Button {
                            loadTemplate(item.document, body: item.body)
                            showLoadSheet = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.document.name)
                                Text("占位框 \(item.document.placeholders.count) · \(item.document.updatedAt.formatted())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            templateStore.delete(id: savedTemplates[i].document.id)
                        }
                        savedTemplates = templateStore.loadAll()
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button(L10n.ui("关闭")) { showLoadSheet = false }
            }
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }

    // MARK: - Actions

    private func addPlaceholder(bindingKey: String, staggerIndex: Int? = nil) {
        let m = SequenceLayoutComposer.metrics(
            config: appState.settings.printerConfig,
            fontSize: CGFloat(editorFontSize),
            paperWidthPoints: paperWidth
        )
        let idx = staggerIndex ?? placeholders.count
        let col = idx % 2
        let row = idx / 2
        var frame = SequencePlaceholderFrame(
            x: m.contentOriginX + CGFloat(col) * (m.unitWidth * 12 + 12),
            y: m.contentOriginY + CGFloat(row) * (m.lineHeight * 2 + 16) + 48,
            width: m.unitWidth * 10,
            height: m.lineHeight * 2
        )
        frame = frame.clamped(to: canvasSize)
        let box = SequencePlaceholder(
            bindingKey: bindingKey,
            frame: frame,
            fontSize: CGFloat(editorFontSize),
            zIndex: (placeholders.map(\.zIndex).max() ?? 0) + 1
        )
        placeholders.append(box)
        selectedPlaceholderID = box.id
    }

    private func deletePlaceholder(id: UUID) {
        placeholders.removeAll { $0.id == id }
        if selectedPlaceholderID == id {
            selectedPlaceholderID = nil
        }
        persistDraftMedia()
    }

    private func loadSavedContent() {
        guard let saved = draftStore.load(), saved.length > 0 else { return }
        attributedText = saved
    }

    private func loadDraftMedia() {
        var meta = templateStore.loadDraftMeta()
        meta.normalizeLogos()
        placeholders = meta.placeholders
        logos = meta.logos
        logoImages = templateStore.loadDraftLogoImages(items: logos)
        backgroundImage = templateStore.loadDraftBackgroundImage()
        backgroundScalePercent = min(
            SequenceLogoItem.maxScalePercent,
            max(SequenceLogoItem.minScalePercent, meta.backgroundScalePercent)
        )
        if backgroundImage == nil { backgroundScalePercent = 100 }
        logos.removeAll { logoImages[$0.id] == nil }
        if selectedLogoID.map({ logoImages[$0] == nil }) == true {
            selectedLogoID = nil
        }
    }

    private func persistDraftMedia() {
        let pairs = logos.compactMap { item -> (item: SequenceLogoItem, image: NSImage)? in
            guard let image = logoImages[item.id] else { return nil }
            return (item, image)
        }
        templateStore.saveDraft(
            placeholders: placeholders,
            logos: pairs,
            backgroundImage: backgroundImage,
            backgroundScalePercent: backgroundScalePercent
        )
    }

    private func setBackgroundScale(_ percent: Double) {
        backgroundScalePercent = min(
            SequenceLogoItem.maxScalePercent,
            max(SequenceLogoItem.minScalePercent, percent.rounded())
        )
    }

    private func pickImage(completion: @escaping (NSImage) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .png, .jpeg, .tiff, .gif, .bmp,
            UTType(filenameExtension: "webp") ?? .png
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url) else {
            message = L10n.ui("无法读取图片")
            return
        }
        completion(image)
    }

    private func bindingLogoFrame(id: UUID) -> Binding<SequencePlaceholderFrame> {
        Binding(
            get: {
                logos.first(where: { $0.id == id })?.frame
                    ?? SequencePlaceholderFrame(x: 0, y: 0, width: 80, height: 40)
            },
            set: { newFrame in
                guard let idx = logos.firstIndex(where: { $0.id == id }) else { return }
                logos[idx].frame = newFrame.clamped(to: canvasSize, minSize: CGSize(width: 36, height: 24))
            }
        )
    }

    private func syncLogoScaleFromFrame(id: UUID) {
        guard let idx = logos.firstIndex(where: { $0.id == id }) else { return }
        logos[idx].syncScaleFromFrame(paper: canvasSize)
        persistDraftMedia()
    }

    private func setLogoScale(id: UUID, percent: Double) {
        guard let idx = logos.firstIndex(where: { $0.id == id }) else { return }
        logos[idx].applyScalePercent(percent, paper: canvasSize)
        selectedLogoID = id
        selectedPlaceholderID = nil
        persistDraftMedia()
    }

    private func addLogo(_ image: NSImage) {
        let mono = ImagePreprocessor.toBinaryBlackWhite(image)
        let id = UUID()
        let item = SequenceLogoItem.makeDefault(
            id: id,
            imageFilename: SpreadsheetSequenceDocument.logoFilename(for: id),
            imageSize: mono.size,
            paperWidth: paperWidth,
            paperSize: canvasSize,
            staggerIndex: logos.count,
            zIndex: (logos.map(\.zIndex).max() ?? 0) + 1
        )
        logos.append(item)
        logoImages[id] = mono
        selectedLogoID = id
        selectedPlaceholderID = nil
        persistDraftMedia()
    }

    private func removeLogo(id: UUID) {
        logos.removeAll { $0.id == id }
        logoImages.removeValue(forKey: id)
        if selectedLogoID == id { selectedLogoID = nil }
        persistDraftMedia()
    }

    private func clearAllLogos() {
        logos = []
        logoImages = [:]
        selectedLogoID = nil
        persistDraftMedia()
    }

    private func clearContent() {
        attributedText = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
        placeholders = []
        selectedPlaceholderID = nil
        selectedRowIndex = 0
        backgroundImage = nil
        backgroundScalePercent = 100
        logos = []
        logoImages = [:]
        selectedLogoID = nil
        draftStore.clear()
        templateStore.clearDraftPlaceholders()
        message = ""
        sequenceProgress = ""
    }

    private func syncEditorToState() {
        if let tv = editorController.textView {
            attributedText = tv.attributedString()
        }
    }

    private func importSpreadsheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .tabSeparatedText,
            .plainText,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "xls") ?? .data,
            UTType(filenameExtension: "csv") ?? .commaSeparatedText
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let table = try SpreadsheetImportService.load(from: url)
            spreadsheet = table
            selectedRowIndex = 0
            importInfo = "来自 \(url.lastPathComponent)"
            message = "已导入 \(table.rows.count) 行 · \(table.headers.count) 列（请手动添加占位框）"
        } catch {
            appState.lastError = error.localizedDescription
            importInfo = error.localizedDescription
            message = error.localizedDescription
        }
    }

    private func composedForCurrentRow() -> NSAttributedString {
        syncEditorToState()
        let values = currentRowValues
        return SequenceLayoutComposer.compose(
            body: attributedText,
            placeholders: placeholders,
            values: values,
            config: appState.settings.printerConfig,
            fontSize: CGFloat(editorFontSize),
            paperWidthPoints: paperWidth
        )
    }

    private func previewCurrent() async {
        let composed = composedForCurrentRow()
        let image = RichTextPrintRenderer.renderSequencePageImage(
            attributedString: composed,
            config: appState.settings.printerConfig,
            media: pageMedia
        )
        previewPayload = QuickPrintPreviewPayload(image: image)
    }

    private func printCurrent() async {
        await printDocument(composedForCurrentRow())
    }

    private func sequencePrintAll() async {
        guard let sheet = spreadsheet, !sheet.isEmpty else { return }
        guard appState.settings.selectedPrinterName != nil else { return }
        syncEditorToState()
        isSequencePrinting = true
        defer { isSequencePrinting = false }

        sequenceProgress = "正在合成 \(sheet.rows.count) 张…"
        var pages: [NSAttributedString] = []
        var firstLines: [String] = []
        for (index, row) in sheet.rows.enumerated() {
            selectedRowIndex = index
            let values = mergeValues(headers: sheet.headers, row: row)
            let composed = SequenceLayoutComposer.compose(
                body: attributedText,
                placeholders: placeholders,
                values: values,
                config: appState.settings.printerConfig,
                fontSize: CGFloat(editorFontSize),
                paperWidthPoints: paperWidth
            )
            pages.append(composed)
            firstLines.append(composed.string.components(separatedBy: "\n").first ?? "")
        }

        var config = appState.settings.printerConfig
        config.cutPaper = true
        let media = pageMedia
        let payload = RichTextPrintRenderer.renderSequenceESCPOS(
            pages: pages,
            config: config,
            media: media,
            editorFontSize: CGFloat(editorFontSize),
            paperWidthPoints: paperWidth
        )
        let previewImage = RichTextPrintRenderer.renderSequencePageImage(
            attributedString: pages[0],
            config: config,
            media: media
        )
        let hasMedia = media.background != nil || !media.logos.isEmpty
        let firstRaster = hasMedia
            ? BarcodeGenerator.rasterizeWithPNG(previewImage, maxWidth: config.dotsPerLine)
            : nil
        let pngData = firstRaster?.grayPNG
            ?? previewImage.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
            ?? Data()
        let raster = firstRaster?.raster
        let widthBytes = raster?.widthBytes ?? 0
        let height = raster?.height ?? 0
        let rasterData = raster?.data ?? Data()
        let expected = widthBytes * height
        let sourceText = firstLines.enumerated()
            .map { "[\($0.offset)] \($0.element)" }
            .joined(separator: "\n")
        let artifacts = PrintArtifacts(
            sourceText: sourceText,
            attributedRTFD: nil,
            pngData: pngData,
            rasterData: rasterData,
            payload: payload,
            imagePixelWidth: Int(previewImage.size.width),
            imagePixelHeight: Int(previewImage.size.height),
            rasterWidthBytes: widthBytes,
            rasterHeight: height,
            headerXL: widthBytes & 0xFF,
            headerXH: (widthBytes >> 8) & 0xFF,
            headerYL: height & 0xFF,
            headerYH: (height >> 8) & 0xFF,
            expectedRasterBytes: expected,
            renderMode: .nativeText,
            usedNativeText: true,
            usedRaster: hasMedia,
            dpi: 203,
            printableWidthDots: config.dotsPerLine,
            printerModelHint: hasMedia
                ? "POS-80 sequence native GBK + media strip"
                : "POS-80 sequence native GBK"
        )

        sequenceProgress = L10n.ui("正在打印序列…")
        let statusPollingWasActive = appState.gmailSync.isRunning
        let record = await appState.runDiagnosticPrint(
            artifacts: artifacts,
            statusPollingWasActive: statusPollingWasActive
        )
        if let err = record?.transportError {
            sequenceProgress = "序列打印失败: \(err)"
        } else {
            sequenceProgress = "序列打印完成：\(sheet.rows.count) 张"
        }
        message = sequenceProgress
    }

    private func saveAsTemplate() {
        syncEditorToState()
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let newID = UUID()
        documentID = newID
        let doc = SpreadsheetSequenceDocument(
            id: newID,
            name: name,
            placeholders: placeholders,
            paperWidthMM: appState.settings.printerConfig.paperWidthMM,
            editorFontSize: editorFontSize,
            backgroundScalePercent: backgroundImage == nil ? 100 : backgroundScalePercent,
            logos: logos
        )
        let pairs = logos.compactMap { item -> (item: SequenceLogoItem, image: NSImage)? in
            guard let image = logoImages[item.id] else { return nil }
            return (item, image)
        }
        templateStore.save(
            document: doc,
            body: attributedText,
            backgroundImage: backgroundImage,
            logos: pairs
        )
        message = "已保存模板「\(name)」"
    }

    private func loadTemplate(_ doc: SpreadsheetSequenceDocument, body: NSAttributedString) {
        var normalized = doc
        normalized.normalizeLogos()
        documentID = normalized.id
        attributedText = body
        placeholders = normalized.placeholders
        editorFontSize = normalized.editorFontSize
        selectedPlaceholderID = nil
        backgroundImage = templateStore.loadBackground(document: normalized)
        backgroundScalePercent = backgroundImage == nil
            ? 100
            : min(
                SequenceLogoItem.maxScalePercent,
                max(SequenceLogoItem.minScalePercent, normalized.backgroundScalePercent)
            )
        logos = normalized.logos.map { item in
            var copy = item
            copy.frame = copy.frame.clamped(to: canvasSize, minSize: CGSize(width: 36, height: 24))
            return copy
        }
        logoImages = templateStore.loadLogoImages(document: normalized)
        logos.removeAll { logoImages[$0.id] == nil }
        selectedLogoID = nil
        draftStore.save(body)
        persistDraftMedia()
        message = "已载入「\(normalized.name)」"
    }

    private func mergeValues(headers: [String], row: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for (colIndex, header) in headers.enumerated() {
            let key = header.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = colIndex < row.count ? row[colIndex] : ""
        }
        return values
    }

    private func cellValue(row: Int, key: String) -> String {
        guard let sheet = spreadsheet,
              let col = sheet.headers.firstIndex(of: key),
              sheet.rows.indices.contains(row) else { return "" }
        if sheet.rows[row].count <= col {
            return ""
        }
        return sheet.rows[row][col]
    }

    private func setCellValue(row: Int, key: String, value: String) {
        guard var sheet = spreadsheet,
              let col = sheet.headers.firstIndex(of: key),
              sheet.rows.indices.contains(row) else { return }
        while sheet.rows[row].count <= col {
            sheet.rows[row].append("")
        }
        sheet.rows[row][col] = value
        spreadsheet = sheet
    }

    private func printDocument(_ content: NSAttributedString, cut: Bool = true) async {
        guard appState.settings.selectedPrinterName != nil else { return }
        isPrinting = true
        defer { isPrinting = false }
        var config = appState.settings.printerConfig
        config.cutPaper = cut

        let rtfd = try? content.data(
            from: NSRange(location: 0, length: content.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        // Same raster path as sequence so background/logo appear and Chinese stays stable.
        let artifacts = RichTextPrintRenderer.buildSequenceRasterArtifacts(
            attributedString: content,
            config: config,
            media: pageMedia,
            sourceText: content.string,
            attributedRTFD: rtfd
        )

        let statusPollingWasActive = appState.gmailSync.isRunning
        if let record = await appState.runDiagnosticPrint(
            artifacts: artifacts,
            statusPollingWasActive: statusPollingWasActive
        ) {
            if record.transportError == nil {
                message = L10n.ui("已发送到打印机")
            } else {
                message = "打印失败: \(record.transportError ?? "")"
            }
        }
    }
}
