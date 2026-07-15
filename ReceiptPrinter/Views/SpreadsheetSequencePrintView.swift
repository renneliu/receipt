import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Excel / CSV row-sequence printing: rich-text body + draggable column placeholders.
/// Print path matches Quick Print (native GBK via `RichTextPrintRenderer`), not whole-page raster.
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

    private let draftStore = QuickPrintStore(filename: "spreadsheet-sequence-draft.rtfd")
    private let templateStore = SequenceTemplateStore()
    private var columns: Int { appState.settings.printerConfig.columnsPerLine }

    private var paperWidth: CGFloat {
        AttributedTextView.editorPaperWidth(
            config: appState.settings.printerConfig,
            fontSize: CGFloat(editorFontSize)
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
        .navigationTitle("Excel表格序列打印")
        .onAppear {
            loadSavedContent()
            placeholders = templateStore.loadDraftPlaceholders()
        }
        .onChange(of: attributedText) { _, newValue in
            draftStore.save(newValue)
        }
        .onChange(of: placeholders) { _, newValue in
            templateStore.saveDraftPlaceholders(newValue)
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
        let height: CGFloat = 720
        return ZStack(alignment: .topLeading) {
            AttributedTextView(
                attributedString: $attributedText,
                printerConfig: appState.settings.printerConfig,
                editorFontSize: CGFloat(editorFontSize)
            ) { textView in
                editorController.textView = textView
            }
            .frame(width: paperWidth, height: height)

            PlaceholderBoxOverlay(
                placeholders: $placeholders,
                selectedID: $selectedPlaceholderID,
                values: currentRowValues,
                paperSize: CGSize(width: paperWidth, height: height),
                printerConfig: appState.settings.printerConfig,
                fontSize: CGFloat(editorFontSize)
            )
            .frame(width: paperWidth, height: height)
        }
        .frame(width: paperWidth, height: height)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sidePanel: some View {
        Form {
            Section("文本格式") {
                RichTextToolbar(
                    controller: editorController,
                    columnsPerLine: columns,
                    fontSize: $editorFontSize
                )
            }

            Section("导入表格") {
                Text("导入 CSV/XLSX 后会按列自动创建可拖动占位框。正文也可手写 {{列名}}。打印走 GBK 文本，不用整页位图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("导入 Excel / CSV…") {
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

            if let sheet = spreadsheet, !sheet.headers.isEmpty {
                Section("添加占位框") {
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
                    Text("也可在正文插入 {{列名}} 令牌：")
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
                Section("占位框") {
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
                        Button("删除选中占位框", role: .destructive) {
                            if let id = selectedPlaceholderID {
                                deletePlaceholder(id: id)
                            }
                        }
                    }
                }
            }

            if let box = selectedPlaceholder, let sheet = spreadsheet {
                Section("序列内容 · \(box.bindingKey)") {
                    Text("点选一行可在编辑区预览该行；数值可直接修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(sheet.rows.indices), id: \.self) { rowIndex in
                        sequenceRowEditor(rowIndex: rowIndex, bindingKey: box.bindingKey)
                    }
                }
            } else if spreadsheet != nil {
                Section("序列内容") {
                    Text("点选画布上的占位框后，这里显示该列各行数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sheet = spreadsheet, !sheet.rows.isEmpty {
                        Picker("预览行", selection: $selectedRowIndex) {
                            ForEach(Array(sheet.rows.indices), id: \.self) { i in
                                Text("第 \(i + 1) 行").tag(i)
                            }
                        }
                    }
                }
            }

            Section("模板") {
                Button("存为模板…") {
                    saveName = "序列打印 \(Date().formatted(date: .abbreviated, time: .shortened))"
                    showSaveSheet = true
                }
                .disabled(attributedText.length == 0 && placeholders.isEmpty)
                Button("载入模板…") {
                    savedTemplates = templateStore.loadAll()
                    showLoadSheet = true
                }
            }

            Section("打印") {
                Button(isPrinting ? "打印中…" : "打印当前") {
                    Task { await printCurrent() }
                }
                .disabled(isPrinting || isSequencePrinting || appState.settings.selectedPrinterName == nil)
                Button(isSequencePrinting ? "打印中…" : "打印序列") {
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
                "值",
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
                Text("请先在「设置」中选择 CUPS 打印机")
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
            Button("清空") { clearContent() }
            Button("预览") {
                Task { await previewCurrent() }
            }
            Button(isPrinting ? "打印中..." : "打印当前") {
                Task { await printCurrent() }
            }
            .disabled(isPrinting || appState.settings.selectedPrinterName == nil)
            Button(isSequencePrinting ? "打印中…" : "打印序列") {
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
            Text("存为模板").font(.headline)
            TextField("模板名称", text: $saveName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { showSaveSheet = false }
                Button("保存") {
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
            Text("载入模板").font(.headline)
            if savedTemplates.isEmpty {
                Text("暂无已存模板")
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
                Button("关闭") { showLoadSheet = false }
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
        frame = frame.clamped(to: CGSize(width: paperWidth, height: 720))
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
    }

    private func loadSavedContent() {
        guard let saved = draftStore.load(), saved.length > 0 else { return }
        attributedText = saved
    }

    private func clearContent() {
        attributedText = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
        placeholders = []
        selectedPlaceholderID = nil
        selectedRowIndex = 0
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
            let created = ensurePlaceholders(for: table.headers)
            importInfo = "来自 \(url.lastPathComponent)"
            message = "已导入 \(table.rows.count) 行 · \(table.headers.count) 列 · 新建占位框 \(created)"
        } catch {
            appState.lastError = error.localizedDescription
            importInfo = error.localizedDescription
            message = error.localizedDescription
        }
    }

    /// Create one draggable box per column header (skip keys that already have a box).
    @discardableResult
    private func ensurePlaceholders(for headers: [String]) -> Int {
        let existing = Set(placeholders.map(\.bindingKey))
        var created = 0
        for (i, header) in headers.enumerated() {
            let name = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !existing.contains(name) else { continue }
            addPlaceholder(bindingKey: name, staggerIndex: placeholders.count + i)
            created += 1
        }
        if let first = placeholders.first {
            selectedPlaceholderID = first.id
        }
        return created
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
        let image = RichTextPrintRenderer.renderImage(
            attributedString: composed,
            config: appState.settings.printerConfig
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

        // One CUPS job: each row as a bit-image page with a cut after every ticket.
        // Native GBK text garbled on page 2+ on this POS-80; raster avoids Chinese mode.
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
        let payload = RichTextPrintRenderer.renderSequenceESCPOS(pages: pages, config: config)
        let previewImage = RichTextPrintRenderer.renderImage(
            attributedString: pages[0],
            config: config
        )
        let firstRaster = BarcodeGenerator.rasterizeWithPNG(
            previewImage,
            maxWidth: config.dotsPerLine
        )
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
            renderMode: .raster,
            usedNativeText: false,
            usedRaster: true,
            dpi: 203,
            printableWidthDots: config.dotsPerLine,
            printerModelHint: "POS-80 sequence raster pages"
        )

        sequenceProgress = "正在打印序列…"
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
            editorFontSize: editorFontSize
        )
        templateStore.save(document: doc, body: attributedText)
        message = "已保存模板「\(name)」"
    }

    private func loadTemplate(_ doc: SpreadsheetSequenceDocument, body: NSAttributedString) {
        documentID = doc.id
        attributedText = body
        placeholders = doc.placeholders
        editorFontSize = doc.editorFontSize
        selectedPlaceholderID = nil
        draftStore.save(body)
        templateStore.saveDraftPlaceholders(placeholders)
        message = "已载入「\(doc.name)」"
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
        let artifacts = RichTextPrintRenderer.buildArtifacts(
            attributedString: content,
            config: config,
            sourceText: content.string,
            attributedRTFD: rtfd
        )

        let statusPollingWasActive = appState.gmailSync.isRunning
        if let record = await appState.runDiagnosticPrint(
            artifacts: artifacts,
            statusPollingWasActive: statusPollingWasActive
        ) {
            if record.transportError == nil {
                message = "已发送到打印机"
            } else {
                message = "打印失败: \(record.transportError ?? "")"
            }
        }
    }
}
