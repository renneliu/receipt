import AppKit
import SwiftUI

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

    private let store = QuickPrintStore()
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
                            editorFontSize: CGFloat(editorFontSize),
                            onTextViewReady: { textView in
                                editorController.textView = textView
                            }
                        )
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
            Section("文本格式") {
                RichTextToolbar(
                    controller: editorController,
                    columnsPerLine: columns,
                    fontSize: $editorFontSize
                )
            }

            Section("走纸 / 切纸") {
                HStack {
                    Text("走纸行数")
                    TextField(value: $feedLines, format: .number, prompt: Text("6")) {
                        EmptyView()
                    }
                    .labelsHidden()
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
    }

    private func syncEditorToState() {
        if let tv = editorController.textView {
            attributedText = tv.attributedString()
        }
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

    private func feedPaper() async {
        guard let printer = appState.settings.selectedPrinterName else {
            message = "未选择打印机，无法走纸"
            return
        }
        message = "走纸中…"
        let data = ESCPOSBuilder(config: appState.settings.printerConfig)
            .initialize()
            .align(.left)
            .feedPaperAction(lines: feedLines)
            .build()
        // Serialize via PrintController so feed cannot race a following print job.
        let config = PrintController.Config(
            printerName: printer,
            connectionType: "USB raw via CUPS `lp`",
            statusPollingWasActive: false,
            clearStuckJobsFirst: false
        )
        let record = await appState.printController.printRawOnce(
            config: config,
            payload: data,
            sourceLabel: "feed:\(feedLines)",
            renderMode: .nativeText
        )
        appState.ingest(record)
        if let err = record.transportError {
            appState.lastError = err
            message = err
        } else {
            message = "已走纸 \(feedLines) 行"
        }
    }

    private func cutPaper() async {
        guard let printer = appState.settings.selectedPrinterName else {
            message = "未选择打印机，无法切纸"
            return
        }
        message = "切纸中…"
        let feed = max(appState.settings.printerConfig.feedLinesBeforeCut, 12)
        let data = ESCPOSBuilder(config: appState.settings.printerConfig)
            .initialize()
            .align(.left)
            .cutPaperAction(feedLines: feed)
            .build()
        let config = PrintController.Config(
            printerName: printer,
            connectionType: "USB raw via CUPS `lp`",
            statusPollingWasActive: false,
            clearStuckJobsFirst: false
        )
        let record = await appState.printController.printRawOnce(
            config: config,
            payload: data,
            sourceLabel: "cut:\(feed)",
            renderMode: .nativeText
        )
        appState.ingest(record)
        if let err = record.transportError {
            appState.lastError = err
            message = err
        } else {
            message = "已切纸"
        }
    }
}
