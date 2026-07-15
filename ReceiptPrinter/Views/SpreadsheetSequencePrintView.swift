import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dedicated page for Excel / CSV row-sequence printing with `{{列名}}` merge.
struct SpreadsheetSequencePrintView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var editorController = RichTextEditorController()
    @State private var attributedText = NSAttributedString(
        string: "",
        attributes: AttributedTextView.defaultTypingAttributes()
    )
    @State private var isPrinting = false
    @State private var message = ""
    @State private var previewPayload: QuickPrintPreviewPayload?
    @State private var editorFontSize: Double = AttributedTextView.defaultFontSize
    @State private var spreadsheet: SpreadsheetTable?
    @State private var importInfo = ""
    @State private var isSequencePrinting = false
    @State private var sequenceProgress = ""

    private let store = QuickPrintStore(filename: "spreadsheet-sequence-draft.rtfd")
    private var columns: Int { appState.settings.printerConfig.columnsPerLine }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    HStack {
                        Spacer(minLength: 0)
                        AttributedTextView(
                            attributedString: $attributedText,
                            printerConfig: appState.settings.printerConfig,
                            editorFontSize: CGFloat(editorFontSize)
                        ) { textView in
                            editorController.textView = textView
                        }
                        .frame(
                            width: AttributedTextView.editorPaperWidth(
                                config: appState.settings.printerConfig,
                                fontSize: CGFloat(editorFontSize)
                            )
                        )
                        .frame(maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
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
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        }
        .navigationTitle("Excel表格序列打印")
        .onAppear { loadSavedContent() }
        .onChange(of: attributedText) { _, newValue in
            store.save(newValue)
        }
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
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
                Text("正文写好带 {{列名}} 的模板后，按表格每一行合并并连续打印。")
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
                Section("插入列占位符") {
                    FlowLayout(spacing: 6) {
                        ForEach(sheet.headers, id: \.self) { header in
                            let name = header.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                Button(name) {
                                    editorController.insertPlaceholder(fieldName: name)
                                    syncEditorToState()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    Button("用首行预览合并") {
                        previewFirstRow()
                    }
                    .disabled(sheet.isEmpty)
                }
            }

            Section("序列打印") {
                Button(isSequencePrinting ? "打印中…" : "序列打印全部行") {
                    Task { await sequencePrintAll() }
                }
                .disabled(
                    isSequencePrinting
                        || appState.settings.selectedPrinterName == nil
                        || spreadsheet?.isEmpty != false
                        || attributedText.length == 0
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
                syncEditorToState()
                let image = RichTextPrintRenderer.renderImage(
                    attributedString: attributedText,
                    config: appState.settings.printerConfig
                )
                previewPayload = QuickPrintPreviewPayload(image: image)
            }
            Button(isPrinting ? "打印中..." : "打印当前") {
                syncEditorToState()
                Task { await printDocument(attributedText) }
            }
            .disabled(isPrinting || appState.settings.selectedPrinterName == nil)
        }
        .padding()
        .background(.bar)
    }

    private func loadSavedContent() {
        guard let saved = store.load(), saved.length > 0 else { return }
        attributedText = saved
    }

    private func clearContent() {
        attributedText = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
        store.clear()
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
            UTType(filenameExtension: "csv") ?? .commaSeparatedText
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let table = try SpreadsheetImportService.load(from: url)
            spreadsheet = table
            importInfo = "来自 \(url.lastPathComponent)"
            message = "已导入 \(table.rows.count) 行"
        } catch {
            appState.lastError = error.localizedDescription
            importInfo = error.localizedDescription
        }
    }

    private func previewFirstRow() {
        guard let sheet = spreadsheet, let row = sheet.rows.first else { return }
        let values = mergeValues(headers: sheet.headers, row: row)
        let merged = QuickPrintMerge.apply(attributedText, values: values)
        let image = RichTextPrintRenderer.renderImage(
            attributedString: merged,
            config: appState.settings.printerConfig
        )
        previewPayload = QuickPrintPreviewPayload(image: image)
    }

    private func sequencePrintAll() async {
        guard let sheet = spreadsheet, !sheet.isEmpty else { return }
        guard appState.settings.selectedPrinterName != nil else { return }
        syncEditorToState()
        isSequencePrinting = true
        defer { isSequencePrinting = false }

        for (index, row) in sheet.rows.enumerated() {
            sequenceProgress = "正在打印 \(index + 1)/\(sheet.rows.count)"
            let values = mergeValues(headers: sheet.headers, row: row)
            let merged = QuickPrintMerge.apply(attributedText, values: values)
            await printDocument(merged, cut: true)
            if index < sheet.rows.count - 1 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        sequenceProgress = "序列打印完成：\(sheet.rows.count) 张"
        message = sequenceProgress
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
