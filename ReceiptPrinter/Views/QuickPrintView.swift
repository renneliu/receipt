import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    @State private var backgroundImage: NSImage?
    @State private var backgroundScalePercent: Double = 100
    @State private var logos: [SequenceLogoItem] = []
    @State private var logoImages: [UUID: NSImage] = [:]
    @State private var selectedLogoID: UUID?
    @State private var autoNumber = QuickPrintAutoNumber()
    @State private var autoNumberSelected = false
    @State private var liveEditorHeight: CGFloat = 0
    @State private var showHistory = false
    @State private var printHistory: [ModulePrintHistoryRecord] = []
    @State private var showLoadTemplateSheet = false
    @State private var showSaveTemplateSheet = false
    @State private var saveTemplateName = ""
    @State private var savedQuickTemplates: [(document: QuickPrintTemplateDocument, body: NSAttributedString)] = []
    @State private var renamingTemplateId: UUID?
    @State private var renameTemplateText = ""
    @State private var showLoadDraftSheet = false

    private let store = QuickPrintStore()
    private let mediaStore = QuickPrintMediaStore()
    private let templateStore = QuickPrintTemplateStore()
    private let historyKind = "quickPrint"
    private let draftModule = "quickPrint"
    private let paperCanvasMinHeight: CGFloat = 480

    private var columns: Int { appState.settings.printerConfig.columnsPerLine }

    private var paperWidth: CGFloat {
        AttributedTextView.editorPaperWidth(
            config: appState.settings.printerConfig,
            fontSize: CGFloat(editorFontSize)
        )
    }

    private var documentHeight: CGFloat {
        let fontSize = CGFloat(editorFontSize)
        let softWrapH = AttributedTextView.measureEditorHeight(
            attributedString: attributedText,
            config: appState.settings.printerConfig,
            fontSize: fontSize
        )
        let logoBottom = logos.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let numberBottom = autoNumber.enabled
            ? autoNumber.frame.y + autoNumber.frame.height
            : 0
        let overlayBottom = max(logoBottom, numberBottom)
        return max(
            paperCanvasMinHeight,
            softWrapH,
            liveEditorHeight,
            overlayBottom + 40
        )
    }

    private var canvasSize: CGSize {
        CGSize(width: paperWidth, height: documentHeight)
    }

    private var pageMediaBase: RichTextPrintRenderer.SequencePageMedia {
        let layers = logos
            .sorted { $0.zIndex < $1.zIndex }
            .compactMap { item -> RichTextPrintRenderer.SequenceLogoLayer? in
                guard let image = logoImages[item.id] else { return nil }
                return .init(image: image, frame: item.frame)
            }
        var media = RichTextPrintRenderer.SequencePageMedia(
            background: backgroundImage,
            backgroundScalePercent: backgroundScalePercent,
            logos: layers,
            textOverlays: [],
            canvasSize: canvasSize
        )
        if autoNumber.enabled {
            media.textOverlays = [
                .init(
                    text: autoNumber.formattedValue(offset: 0),
                    frame: autoNumber.frame,
                    fontSize: autoNumber.fontSize
                )
            ]
        }
        return media
    }

    private var needsCompositePrint: Bool {
        backgroundImage != nil || !logos.isEmpty || autoNumber.enabled
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
        // Title owned by MainView (keep-alive stack).
        .onAppear {
            loadSavedContent()
            loadDraftMedia()
            printHistory = ModulePrintHistoryStore.loadAll(kind: historyKind)
        }
        .onChange(of: attributedText) { _, newValue in
            store.save(newValue)
        }
        .onChange(of: logos) { _, _ in persistDraftMedia() }
        .onChange(of: backgroundScalePercent) { _, _ in persistDraftMedia() }
        .onChange(of: autoNumber) { _, _ in persistDraftMedia() }
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
        .sheet(isPresented: $showHistory) {
            modulePrintHistorySheet
        }
        .sheet(isPresented: $showLoadTemplateSheet) {
            loadQuickTemplateSheet
        }
        .sheet(isPresented: $showSaveTemplateSheet) {
            NamePromptSheet(
                title: L10n.ui("存为模板"),
                nameLabel: L10n.ui("模板名称"),
                name: $saveTemplateName,
                onCancel: { showSaveTemplateSheet = false },
                onSave: {
                    saveAsTemplateConfirmed()
                    showSaveTemplateSheet = false
                }
            )
        }
        .sheet(isPresented: $showLoadDraftSheet) {
            NamedDraftPickerSheet(
                title: L10n.ui("读取草稿"),
                module: draftModule,
                onLoad: { draft in
                    loadNamedDraft(draft)
                    showLoadDraftSheet = false
                },
                onClose: { showLoadDraftSheet = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .receiptPrinterPersistWorkingDrafts)) { _ in
            saveDraftExplicitly(showMessage: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .receiptPrinterClearWorkingContent)) { _ in
            clearContent()
        }
    }

    private var paperCanvas: some View {
        let height = documentHeight
        return ScrollView(.vertical, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                if let bg = backgroundImage {
                    let fitted = RichTextPrintRenderer.fitCenterRect(
                        imageSize: bg.size,
                        in: NSRect(x: 0, y: 0, width: paperWidth, height: height)
                    )
                    let p = max(
                        SequenceLogoItem.minScalePercent,
                        min(SequenceLogoItem.maxScalePercent, backgroundScalePercent)
                    ) / 100
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
                                            autoNumberSelected = false
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

                if autoNumber.enabled {
                    AutoNumberBoxOverlay(
                        frame: Binding(
                            get: { autoNumber.frame },
                            set: {
                                autoNumber.frame = $0.clamped(
                                    to: canvasSize,
                                    minSize: CGSize(width: 36, height: 22)
                                )
                            }
                        ),
                        isSelected: Binding(
                            get: { autoNumberSelected },
                            set: { selected in
                                autoNumberSelected = selected
                                if selected { selectedLogoID = nil }
                            }
                        ),
                        previewText: autoNumber.formattedValue(offset: 0),
                        fontSize: autoNumber.fontSize,
                        paperSize: canvasSize,
                        onFrameChanged: { persistDraftMedia() }
                    )
                    .frame(width: paperWidth, height: height)
                }
            }
            .frame(width: paperWidth, height: height)
            .background(Color.white)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

            Section(L10n.ui("版面图片")) {
                Text(L10n.ui("背景在文字下方（等比居中，可用百分比缩放）；彩色 Logo/背景导入时自动转为黑白。可添加多个 Logo。"))
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
                    pickImage { img in addLogo(img) }
                }
                if !logos.isEmpty {
                    ForEach(Array(logos.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button {
                                    selectedLogoID = item.id
                                    autoNumberSelected = false
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
                                .fill(Color.secondary.opacity(0.08))
                        )
                    }
                }
            }

            Section(L10n.ui("自动编号")) {
                Toggle(L10n.ui("启用自动编号"), isOn: Binding(
                    get: { autoNumber.enabled },
                    set: { on in
                        autoNumber.enabled = on
                        if on {
                            autoNumber.frame = autoNumber.frame.clamped(
                                to: canvasSize,
                                minSize: CGSize(width: 36, height: 22)
                            )
                            autoNumberSelected = true
                            selectedLogoID = nil
                        } else {
                            autoNumberSelected = false
                        }
                    }
                ))
                Text(L10n.ui("开启后可在画布上拖动编号框；每次打印后起始值自动增加（打印 N 张则 +N）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if autoNumber.enabled {
                    HStack {
                        Text(L10n.ui("起始值"))
                        TextField("01", text: $autoNumber.startValue)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                    Picker(L10n.ui("字号"), selection: Binding(
                        get: { autoNumber.fontSize },
                        set: { autoNumber.fontSize = $0 }
                    )) {
                        ForEach(QuickPrintAutoNumber.fontSizeChoices, id: \.self) { size in
                            Text("\(Int(size)) pt").tag(size)
                        }
                    }
                    HStack {
                        Text(L10n.ui("批量张数"))
                        TextField(
                            "",
                            value: Binding(
                                get: { autoNumber.batchCount },
                                set: {
                                    autoNumber.batchCount = max(1, $0)
                                    autoNumber.clampBatch()
                                }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        Text(L10n.ui("张/次"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text("本次预览: \(autoNumber.formattedValue(offset: 0))"
                        + (autoNumber.batchCount > 1
                            ? " … \(autoNumber.formattedValue(offset: autoNumber.batchCount - 1))"
                            : ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.ui("走纸 / 切纸")) {
                HStack {
                    Text(L10n.ui("走纸行数"))
                    TextField(value: $feedLines, format: .number, prompt: Text("6")) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onChange(of: feedLines) { _, value in
                        feedLines = min(40, max(1, value))
                    }
                    Text(L10n.ui("行"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button(L10n.ui("走纸")) {
                        Task { await feedPaper() }
                    }
                    .disabled(appState.settings.selectedPrinterName == nil)
                    Button(L10n.ui("切纸")) {
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
            Button(L10n.ui("读取草稿")) {
                showLoadDraftSheet = true
            }
            Button(L10n.ui("保存草稿")) {
                saveNamedDraft()
            }
            Button(L10n.ui("打印记录")) { showHistory = true }
            Button(L10n.ui("载入模板")) {
                showLoadTemplateSheet = true
            }
            Button(L10n.ui("存为模板")) {
                syncEditorToState()
                saveTemplateName = "快速打印 \(Date().formatted(date: .abbreviated, time: .shortened))"
                showSaveTemplateSheet = true
            }
            .disabled(attributedText.length == 0 && logos.isEmpty && backgroundImage == nil)
            Button(L10n.ui("预览")) {
                syncEditorToState()
                let image = RichTextPrintRenderer.renderSequencePageImage(
                    attributedString: attributedText,
                    config: appState.settings.printerConfig,
                    media: pageMediaBase
                )
                previewPayload = QuickPrintPreviewPayload(image: image)
            }
            Button(isPrinting ? L10n.ui("打印中...") : printButtonTitle) {
                syncEditorToState()
                Task { await printDocument() }
            }
            .disabled(isPrinting || appState.settings.selectedPrinterName == nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(.bar)
    }

    private var loadQuickTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.ui("载入模板")).font(.headline)
                Spacer()
                Button(L10n.ui("刷新")) { reloadQuickTemplates() }
            }
            if savedQuickTemplates.isEmpty {
                Text(L10n.ui("暂无已存模板"))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(savedQuickTemplates, id: \.document.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if renamingTemplateId == item.document.id {
                                HStack {
                                    TextField(L10n.ui("模板名称"), text: $renameTemplateText)
                                        .textFieldStyle(.roundedBorder)
                                    Button(L10n.ui("保存")) {
                                        templateStore.rename(id: item.document.id, to: renameTemplateText)
                                        renamingTemplateId = nil
                                        reloadQuickTemplates()
                                    }
                                    .disabled(renameTemplateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button(L10n.ui("取消")) { renamingTemplateId = nil }
                                }
                            } else {
                                HStack {
                                    Text(item.document.name).font(.headline)
                                    Spacer()
                                    Text(item.document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            let preview = item.body.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(
                                "Logo \(item.document.logos.count)"
                                    + " · "
                                    + (preview.isEmpty ? L10n.ui("（空白）") : String(preview.prefix(80)))
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            HStack {
                                Button(L10n.ui("载入")) {
                                    loadQuickTemplate(item.document, body: item.body)
                                    showLoadTemplateSheet = false
                                }
                                Button(L10n.ui("改名")) {
                                    renamingTemplateId = item.document.id
                                    renameTemplateText = item.document.name
                                }
                                Spacer()
                                Button(L10n.ui("删除"), role: .destructive) {
                                    templateStore.delete(id: item.document.id)
                                    reloadQuickTemplates()
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button(L10n.ui("关闭")) { showLoadTemplateSheet = false }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .onAppear { reloadQuickTemplates() }
    }

    private func reloadQuickTemplates() {
        savedQuickTemplates = templateStore.loadAll()
    }

    private var modulePrintHistorySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.ui("打印记录")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.ui("清理全部"), role: .destructive) {
                    ModulePrintHistoryStore.clear(kind: historyKind)
                    printHistory = []
                }
                .disabled(printHistory.isEmpty)
                Button(L10n.ui("关闭")) { showHistory = false }
                    .keyboardShortcut(.cancelAction)
            }
            if printHistory.isEmpty {
                ContentUnavailableView(
                    L10n.ui("暂无记录"),
                    systemImage: "clock",
                    description: Text(L10n.ui("成功打印后会自动保存在此"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(printHistory) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.summary).font(.headline).lineLimit(1)
                                Spacer()
                                Text(record.createdAtText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(record.plainText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            HStack {
                                Button(L10n.ui("载入内容")) {
                                    loadHistory(record)
                                    showHistory = false
                                }
                                Spacer()
                                Button(L10n.ui("删除"), role: .destructive) {
                                    ModulePrintHistoryStore.delete(id: record.id, kind: historyKind)
                                    printHistory = ModulePrintHistoryStore.loadAll(kind: historyKind)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }

    private var printButtonTitle: String {
        if autoNumber.enabled, autoNumber.batchCount > 1 {
            return "\(L10n.ui("打印")) \(autoNumber.batchCount) \(L10n.ui("张")) (⌘↩)"
        }
        return L10n.ui("打印 (⌘↩)")
    }

    // MARK: - Persistence

    private func loadSavedContent() {
        guard let saved = store.load(), saved.length > 0 else { return }
        let plain = saved.string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plain == L10n.ui("Hello 测试小票\n\nReceiptPrinter 快速打印")
            || plain == L10n.ui("Hello 测试小票\nReceiptPrinter 快速打印") {
            store.clear()
            attributedText = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
            return
        }
        attributedText = saved
    }

    private func loadDraftMedia() {
        let meta = mediaStore.loadMeta()
        logos = meta.logos
        logoImages = mediaStore.loadLogoImages(items: logos)
        backgroundImage = mediaStore.loadBackgroundImage()
        backgroundScalePercent = min(
            SequenceLogoItem.maxScalePercent,
            max(SequenceLogoItem.minScalePercent, meta.backgroundScalePercent)
        )
        if backgroundImage == nil { backgroundScalePercent = 100 }
        logos.removeAll { logoImages[$0.id] == nil }
        autoNumber = meta.autoNumber
        autoNumber.clampBatch()
        autoNumber.clampFontSize()
        if !QuickPrintAutoNumber.fontSizeChoices.contains(autoNumber.fontSize) {
            autoNumber.fontSize = QuickPrintAutoNumber.fontSizeChoices.min(by: {
                abs($0 - autoNumber.fontSize) < abs($1 - autoNumber.fontSize)
            }) ?? AttributedTextView.defaultFontSize
        }
        if selectedLogoID.map({ logoImages[$0] == nil }) == true {
            selectedLogoID = nil
        }
    }

    private func persistDraftMedia() {
        let pairs = logos.compactMap { item -> (item: SequenceLogoItem, image: NSImage)? in
            guard let image = logoImages[item.id] else { return nil }
            return (item, image)
        }
        mediaStore.save(
            logos: pairs,
            backgroundImage: backgroundImage,
            backgroundScalePercent: backgroundScalePercent,
            autoNumber: autoNumber
        )
    }

    private func saveDraftExplicitly(showMessage: Bool) {
        syncEditorToState()
        store.save(attributedText)
        persistDraftMedia()
        if showMessage {
            message = L10n.ui("草稿已保存")
        }
    }

    private func saveNamedDraft() {
        syncEditorToState()
        let name = "草稿 \(Date().formatted(date: .abbreviated, time: .shortened))"
        let pairs = logos.compactMap { item -> (item: SequenceLogoItem, image: NSImage)? in
            guard let image = logoImages[item.id] else { return nil }
            return (item, image)
        }
        let preview = attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = NamedWorkingDraftStore.saveQuickDraft(
            name: name,
            previewText: preview,
            body: attributedText,
            logos: pairs,
            backgroundImage: backgroundImage,
            backgroundScalePercent: backgroundScalePercent,
            autoNumber: autoNumber
        )
        store.save(attributedText)
        persistDraftMedia()
        message = L10n.ui("草稿已保存")
    }

    private func loadNamedDraft(_ draft: NamedWorkingDraft) {
        let body = NamedWorkingDraftStore.loadBody(module: draftModule, id: draft.id)
        attributedText = body
        let assets = NamedWorkingDraftStore.loadQuickDraftAssets(id: draft.id)
        logos = assets.meta.logos
        logoImages = assets.logoImages
        backgroundImage = assets.background
        backgroundScalePercent = assets.meta.backgroundScalePercent
        autoNumber = assets.meta.autoNumber
        store.save(attributedText)
        persistDraftMedia()
        message = L10n.ui("已读取草稿")
    }

    private func loadQuickTemplate(_ doc: QuickPrintTemplateDocument, body: NSAttributedString) {
        attributedText = body
        logos = doc.logos
        logoImages = templateStore.loadLogoImages(document: doc)
        backgroundImage = templateStore.loadBackground(document: doc)
        backgroundScalePercent = backgroundImage == nil ? 100 : doc.backgroundScalePercent
        autoNumber = doc.autoNumber
        editorFontSize = doc.editorFontSize
        store.save(attributedText)
        persistDraftMedia()
        message = "\(L10n.ui("已载入模板"))「\(doc.name)」"
    }

    private func loadHistory(_ record: ModulePrintHistoryRecord) {
        if let data = record.rtfdData,
           let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
           ), attr.length > 0 {
            attributedText = attr
        } else {
            attributedText = NSAttributedString(
                string: record.plainText,
                attributes: AttributedTextView.defaultTypingAttributes()
            )
        }
        store.save(attributedText)
        message = L10n.ui("已载入历史内容")
    }

    private func recordPrintHistory(previewPNG: Data) {
        let plain = attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String = {
            let first = plain.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            if first.isEmpty { return L10n.ui("（无文字）") }
            return first.count > 40 ? String(first.prefix(40)) + "…" : first
        }()
        let rtfd = try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let record = ModulePrintHistoryRecord(
            kind: historyKind,
            summary: summary,
            plainText: plain,
            rtfdData: rtfd,
            previewPNG: previewPNG
        )
        ModulePrintHistoryStore.append(record, kind: historyKind)
        printHistory = ModulePrintHistoryStore.loadAll(kind: historyKind)
    }

    private func clearContent() {
        attributedText = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
        backgroundImage = nil
        backgroundScalePercent = 100
        logos = []
        logoImages = [:]
        selectedLogoID = nil
        autoNumber = QuickPrintAutoNumber()
        autoNumberSelected = false
        store.clear()
        mediaStore.clear()
        message = ""
    }

    private func syncEditorToState() {
        if let tv = editorController.textView {
            attributedText = tv.attributedString()
        }
    }

    // MARK: - Logos / background

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
        autoNumberSelected = false
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
        autoNumberSelected = false
        persistDraftMedia()
    }

    private func removeLogo(id: UUID) {
        logos.removeAll { $0.id == id }
        logoImages.removeValue(forKey: id)
        if selectedLogoID == id { selectedLogoID = nil }
        persistDraftMedia()
    }

    // MARK: - Print / preview helpers

    private func saveAsTemplateConfirmed() {
        syncEditorToState()
        let name = saveTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let pairs = logos.compactMap { item -> (item: SequenceLogoItem, image: NSImage)? in
            guard let image = logoImages[item.id] else { return nil }
            return (item, image)
        }
        let doc = QuickPrintTemplateDocument(
            name: name,
            paperWidthMM: appState.settings.printerConfig.paperWidthMM,
            editorFontSize: editorFontSize,
            backgroundScalePercent: backgroundImage == nil ? 100 : backgroundScalePercent,
            logos: logos,
            autoNumber: autoNumber
        )
        templateStore.save(
            document: doc,
            body: attributedText,
            logos: pairs,
            backgroundImage: backgroundImage,
            autoNumber: autoNumber
        )
        message = "已保存为模板「\(name)」"
    }

    private func printDocument() async {
        guard appState.settings.selectedPrinterName != nil else { return }
        isPrinting = true
        defer { isPrinting = false }

        var config = appState.settings.printerConfig
        config.cutPaper = true

        let count = autoNumber.enabled
            ? max(1, min(QuickPrintAutoNumber.maxBatch, autoNumber.batchCount))
            : 1
        let pages = Array(repeating: attributedText, count: count)
        let baseMedia = pageMediaBase
        var pageOverlays: [[RichTextPrintRenderer.SequenceTextOverlay]]?
        if autoNumber.enabled {
            pageOverlays = (0..<count).map { offset in
                [
                    .init(
                        text: autoNumber.formattedValue(offset: offset),
                        frame: autoNumber.frame,
                        fontSize: autoNumber.fontSize
                    )
                ]
            }
        }

        let rtfd = try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )

        let artifacts: PrintArtifacts
        if needsCompositePrint {
            let previewMedia: RichTextPrintRenderer.SequencePageMedia = {
                var m = baseMedia
                if let first = pageOverlays?.first {
                    m.textOverlays = first
                }
                return m
            }()
            let image = RichTextPrintRenderer.renderSequencePageImage(
                attributedString: attributedText,
                config: config,
                media: previewMedia
            )
            let payload = RichTextPrintRenderer.renderSequenceESCPOS(
                pages: pages,
                config: config,
                media: baseMedia,
                pageTextOverlays: pageOverlays,
                editorFontSize: CGFloat(editorFontSize),
                paperWidthPoints: paperWidth
            )
            let pngData = image.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            } ?? Data()
            let numbers = (0..<count).map { autoNumber.enabled ? autoNumber.formattedValue(offset: $0) : "" }
            let hasImages = baseMedia.hasImageMedia
            artifacts = PrintArtifacts(
                sourceText: numbers.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
                    + "\n" + attributedText.string,
                attributedRTFD: rtfd,
                pngData: pngData,
                rasterData: Data(),
                payload: payload,
                imagePixelWidth: Int(image.size.width),
                imagePixelHeight: Int(image.size.height),
                rasterWidthBytes: 0,
                rasterHeight: 0,
                headerXL: 0,
                headerXH: 0,
                headerYL: 0,
                headerYH: 0,
                expectedRasterBytes: 0,
                renderMode: .nativeText,
                usedNativeText: true,
                usedRaster: hasImages,
                dpi: 203,
                printableWidthDots: config.dotsPerLine,
                printerModelHint: hasImages
                    ? "POS-80 quick print native GBK + media strip"
                    : "POS-80 quick print native GBK (auto-number in text)"
            )
        } else {
            artifacts = RichTextPrintRenderer.buildArtifacts(
                attributedString: attributedText,
                config: config,
                sourceText: attributedText.string,
                attributedRTFD: rtfd
            )
        }

        if let record = await appState.runDiagnosticPrint(
            artifacts: artifacts,
            statusPollingWasActive: false
        ) {
            if record.transportError == nil {
                if autoNumber.enabled {
                    autoNumber.advanceAfterPrint(count: count)
                    persistDraftMedia()
                }
                recordPrintHistory(previewPNG: artifacts.pngData)
                message = count > 1 ? "已发送 \(count) 张到打印机" : L10n.ui("已发送到打印机")
            } else {
                message = "打印失败: \(record.transportError ?? "")"
            }
        }
    }

    private func feedPaper() async {
        guard let printer = appState.settings.selectedPrinterName else {
            message = L10n.ui("未选择打印机，无法走纸")
            return
        }
        message = L10n.ui("走纸中…")
        let data = ESCPOSBuilder(config: appState.settings.printerConfig)
            .initialize()
            .align(.left)
            .feedPaperAction(lines: feedLines)
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
            message = L10n.ui("未选择打印机，无法切纸")
            return
        }
        message = L10n.ui("切纸中…")
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
            message = L10n.ui("已切纸")
        }
    }
}
