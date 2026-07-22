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

    private let store = QuickPrintStore()
    private let mediaStore = QuickPrintMediaStore()
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
        .navigationTitle(L10n.ui("快速打印"))
        .onAppear {
            loadSavedContent()
            loadDraftMedia()
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
            Button(L10n.ui("存为模板")) { saveAsTemplate() }
                .disabled(attributedText.length == 0)
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

        let statusPollingWasActive = appState.gmailSync.isRunning
        if let record = await appState.runDiagnosticPrint(
            artifacts: artifacts,
            statusPollingWasActive: statusPollingWasActive
        ) {
            if record.transportError == nil {
                if autoNumber.enabled {
                    autoNumber.advanceAfterPrint(count: count)
                    persistDraftMedia()
                }
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
