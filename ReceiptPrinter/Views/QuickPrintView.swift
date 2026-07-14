import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickPrintTextBox: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sampleValue: String = ""
}

/// Holds a rendered preview bitmap so `.sheet(item:)` receives the image by value
/// (avoids SwiftUI presenting with a stale nil `previewImage`).
struct QuickPrintPreviewPayload: Identifiable {
    let id = UUID()
    let image: NSImage
}

struct QuickPrintView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var editorController = RichTextEditorController()
    @State private var attributedText = NSAttributedString(
        string: "",
        attributes: AttributedTextView.defaultTypingAttributes()
    )
    @State private var isPrinting = false
    @State private var message = ""
    @State private var previewPayload: QuickPrintPreviewPayload?
    @State private var feedLines = 6
    @State private var editorFontSize: Double = AttributedTextView.defaultFontSize
    @State private var textBoxes: [QuickPrintTextBox] = [
        QuickPrintTextBox(name: "姓名", sampleValue: "张三"),
        QuickPrintTextBox(name: "编号", sampleValue: "001")
    ]
    @State private var spreadsheet: SpreadsheetTable?
    @State private var importInfo = ""
    @State private var isSequencePrinting = false
    @State private var sequenceProgress = ""

    private let store = QuickPrintStore()
    private var columns: Int { appState.settings.printerConfig.columnsPerLine }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                RichTextToolbar(
                    controller: editorController,
                    columnsPerLine: columns,
                    fontSize: $editorFontSize
                )

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
        .navigationTitle("快速打印")
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
            Section("文本框（占位符）") {
                Text("在正文插入 {{名称}}，导入表格后可按行序列打印。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach($textBoxes) { $box in
                    HStack {
                        TextField("名称", text: $box.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("示例", text: $box.sampleValue)
                            .textFieldStyle(.roundedBorder)
                        Button("插入") {
                            let name = box.name.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            editorController.insertPlaceholder(fieldName: name)
                            syncEditorToState()
                        }
                        Button(role: .destructive) {
                            textBoxes.removeAll { $0.id == box.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加文本框") {
                    let n = textBoxes.count + 1
                    textBoxes.append(QuickPrintTextBox(name: "字段\(n)", sampleValue: ""))
                }
                Button("用示例值预览合并") {
                    previewMergedSample()
                }
            }

            Section("Excel / 表格序列打印") {
                Button("导入 Excel / CSV…") {
                    importSpreadsheet()
                }
                if let sheet = spreadsheet {
                    Text("已导入 \(sheet.rows.count) 行 · \(sheet.headers.count) 列")
                        .font(.caption)
                    Text(sheet.headers.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button(isSequencePrinting ? "打印中…" : "序列打印全部行") {
                        Task { await sequencePrintAll() }
                    }
                    .disabled(isSequencePrinting || appState.settings.selectedPrinterName == nil || sheet.isEmpty)
                }
                if !importInfo.isEmpty {
                    Text(importInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !sequenceProgress.isEmpty {
                    Text(sequenceProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("走纸 / 切纸") {
                HStack {
                    Text("走纸行数")
                    TextField("6", value: $feedLines, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .onChange(of: feedLines) { _, value in
                            feedLines = min(40, max(1, value))
                        }
                    Text("行")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("走纸") {
                        Task { await feedPaper() }
                    }
                    .disabled(appState.settings.selectedPrinterName == nil)
                    Button("切纸") {
                        Task { await cutPaper() }
                    }
                    .disabled(appState.settings.selectedPrinterName == nil)
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
            Button("存为模板") { saveAsTemplate() }
                .disabled(attributedText.length == 0)
            Button("预览") {
                syncEditorToState()
                let image = RichTextPrintRenderer.renderImage(
                    attributedString: attributedText,
                    config: appState.settings.printerConfig
                )
                previewPayload = QuickPrintPreviewPayload(image: image)
            }
            Button(isPrinting ? "打印中..." : "打印") {
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
        // Drop the old built-in sample that used to ship as the default draft.
        let plain = saved.string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plain == "Hello 测试小票\n\nReceiptPrinter 快速打印"
            || plain == "Hello 测试小票\nReceiptPrinter 快速打印" {
            store.clear()
            attributedText = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
            return
        }
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

    private func sampleMergeValues() -> [String: String] {
        var values: [String: String] = [:]
        for box in textBoxes {
            let key = box.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = box.sampleValue
        }
        return values
    }

    private func previewMergedSample() {
        let merged = QuickPrintMerge.apply(attributedText, values: sampleMergeValues())
        let image = RichTextPrintRenderer.renderImage(
            attributedString: merged,
            config: appState.settings.printerConfig
        )
        previewPayload = QuickPrintPreviewPayload(image: image)
    }

    private func saveAsTemplate() {
        let plain = attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }
        var template = ReceiptTemplate(name: "快速打印 \(Date().formatted(date: .abbreviated, time: .shortened))")
        template.blocks = [
            TemplateBlock(type: .text, content: plain, align: .left, size: .double)
        ]
        template.defaultData = [:]
        appState.saveTemplate(template)
        message = "已保存为模板「\(template.name)」"
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
            // Auto-create text boxes for headers missing in textBoxes
            let existing = Set(textBoxes.map { $0.name })
            for header in table.headers where !header.isEmpty && !existing.contains(header) {
                let sample = table.rows.first.flatMap { row in
                    guard let i = table.headers.firstIndex(of: header), row.indices.contains(i) else { return nil }
                    return row[i]
                } ?? ""
                textBoxes.append(QuickPrintTextBox(name: header, sampleValue: sample))
            }
            message = "已导入 \(table.rows.count) 行"
        } catch {
            appState.lastError = error.localizedDescription
            importInfo = error.localizedDescription
        }
    }

    private func sequencePrintAll() async {
        guard let sheet = spreadsheet, !sheet.isEmpty else { return }
        guard appState.settings.selectedPrinterName != nil else { return }
        isSequencePrinting = true
        defer { isSequencePrinting = false }

        for (index, row) in sheet.rows.enumerated() {
            sequenceProgress = "正在打印 \(index + 1)/\(sheet.rows.count)"
            var values: [String: String] = [:]
            for (colIndex, header) in sheet.headers.enumerated() {
                let key = header.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                values[key] = colIndex < row.count ? row[colIndex] : ""
            }
            // Also fill text box names that match headers
            let merged = QuickPrintMerge.apply(attributedText, values: values)
            await printDocument(merged, cut: true)
            if index < sheet.rows.count - 1 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        sequenceProgress = "序列打印完成：\(sheet.rows.count) 张"
        message = sequenceProgress
    }

    private func printDocument(_ content: NSAttributedString, cut: Bool = true) async {
        guard appState.settings.selectedPrinterName != nil else { return }
        isPrinting = true
        defer { isPrinting = false }
        var config = appState.settings.printerConfig
        config.cutPaper = cut

        // Capture EVERY stage once, off the render step, then transmit exactly one job.
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

    private func feedPaper() async {
        guard let printer = appState.settings.selectedPrinterName else {
            message = "未选择打印机，无法走纸"
            return
        }
        // LF-based advance — ESC-d-only jobs accepted by CUPS but no visible motion on this POS-80.
        let data = ESCPOSBuilder(config: appState.settings.printerConfig)
            .initialize()
            .align(.left)
            .feedPaperAction(lines: feedLines)
            .build()
        do {
            try appState.printService.printRaw(
                printerName: printer,
                data: data,
                clearStuckJobsFirst: true
            )
            message = "走纸中…"
            let idle = await appState.printService.waitUntilIdle(printerName: printer, timeoutSeconds: 25)
            if idle {
                message = "已走纸 \(feedLines) 行"
            } else {
                appState.printService.clearQueue(printerName: printer)
                message = "走纸超时，已清理打印队列，请再试一次"
            }
        } catch {
            appState.lastError = error.localizedDescription
            message = error.localizedDescription
        }
    }

    private func cutPaper() async {
        guard let printer = appState.settings.selectedPrinterName else {
            message = "未选择打印机，无法切纸"
            return
        }
        let feed = max(appState.settings.printerConfig.feedLinesBeforeCut, 12)
        let data = ESCPOSBuilder(config: appState.settings.printerConfig)
            .initialize()
            .align(.left)
            .cutPaperAction(feedLines: feed)
            .build()
        do {
            try appState.printService.printRaw(
                printerName: printer,
                data: data,
                clearStuckJobsFirst: true
            )
            message = "切纸中…"
            let idle = await appState.printService.waitUntilIdle(printerName: printer, timeoutSeconds: 25)
            if idle {
                message = "已切纸"
            } else {
                appState.printService.clearQueue(printerName: printer)
                message = "切纸超时，已清理打印队列，请再试一次"
            }
        } catch {
            appState.lastError = error.localizedDescription
            message = error.localizedDescription
        }
    }
}
