import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MovieTicketMainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: MovieTicketSession

    @State private var titleMode: TitleMode = .local
    @State private var durationMode: DurationMode = .local
    @State private var isPrinting = false
    @State private var showHistory = false
    @State private var previewPayload: PreviewPayload?
    @State private var tmdbResults: [MovieSearchResult] = []
    @State private var showTMDBSheet = false
    @State private var isSearchingTMDB = false
    @State private var showRulePicker = false
    @State private var pendingPDFURL: URL?
    @State private var matchedRules: [MovieTicketPDFRule] = []
    /// Bottom template gallery page (0-based).
    @State private var templatePage: Int = 0

    private static let templatesPerPage = 8

    private enum TitleMode: String, CaseIterable, Identifiable {
        case local = "本地输入"
        case online = "联网搜索"
        var id: String { rawValue }
    }

    private enum DurationMode: String, CaseIterable, Identifiable {
        case local = "本地输入"
        case online = "联网核查"
        var id: String { rawValue }
    }

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    private var template: MovieTicketTemplate? {
        if let editing = session.editingTemplate,
           editing.id == session.settings.activeTemplateId || editing.id == session.activeTemplate?.id {
            return editing
        }
        return session.activeTemplate
    }

    var body: some View {
        GeometryReader { geo in
            HSplitView {
                formColumn
                    .frame(minWidth: 300, idealWidth: 360)

                previewColumn
                    .frame(minWidth: 280)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(8)
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
        .sheet(isPresented: $showHistory) { historySheet }
        .sheet(isPresented: $showTMDBSheet) { tmdbSheet }
        .confirmationDialog("未能自动识别影院，请选择 PDF 识别规则", isPresented: $showRulePicker, titleVisibility: .visible) {
            ForEach(matchedRules.isEmpty ? session.pdfRules : matchedRules) { rule in
                Button(rule.name) {
                    if let url = pendingPDFURL {
                        applyPDF(url: url, rule: rule)
                    }
                }
            }
            Button("手动填写", role: .cancel) {
                pendingPDFURL = nil
                session.message = "请手动填写影票信息"
            }
        }
    }

    // MARK: - Form

    private var formColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                templatePicker

                Group {
                    Text("影片名称").font(.headline)
                    Picker("", selection: $titleMode) {
                        ForEach(TitleMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("影片名称", text: $session.draft.movieTitle)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if titleMode == .online {
                            Button(isSearchingTMDB ? "搜索中…" : "联网搜索") {
                                Task { await searchTMDBTitle() }
                            }
                            .disabled(session.draft.movieTitle.trimmingCharacters(in: .whitespaces).isEmpty || isSearchingTMDB)
                        }
                        Button("导入 PDF 订单") { importPDF() }
                    }
                }

                Group {
                    Text("影片时长（分钟）").font(.headline)
                    Picker("", selection: $durationMode) {
                        ForEach(DurationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("分钟", value: $session.draft.movieDurationMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        if durationMode == .online {
                            Button(isSearchingTMDB ? "核查中…" : "联网核查时长") {
                                Task { await searchTMDBTitle(forDurationOnly: true) }
                            }
                            .disabled(session.draft.movieTitle.trimmingCharacters(in: .whitespaces).isEmpty || isSearchingTMDB)
                        }
                    }
                }

                Group {
                    Text("广告时长").font(.headline)
                    HStack {
                        TextField("分钟", value: $session.draft.adDurationMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        ForEach([0, 5, 10, 15, 20], id: \.self) { m in
                            Button(m == 0 ? "无" : "\(m)分钟") {
                                session.draft.adDurationMinutes = m
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Group {
                    Text("座位区域").font(.headline)
                    Picker("", selection: $session.draft.seatModeUnallocated) {
                        Text("无特定座位").tag(true)
                        Text("指定座位").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !session.draft.seatModeUnallocated {
                        TextField("座位（如 G12）", text: $session.draft.seatArea)
                            .textFieldStyle(.roundedBorder)
                    } else if let label = template?.unallocatedSeatLabel {
                        Text("票面显示：\(label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                labeled("流水号") {
                    TextField("订单/流水号", text: $session.draft.serialNumber)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("日期") {
                    DatePicker("", selection: $session.draft.showDate, displayedComponents: .date)
                        .labelsHidden()
                }
                labeled("开始时间") {
                    DatePicker("", selection: $session.draft.showStartTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                labeled("票型") {
                    TextField("Adult / Child…", text: $session.draft.ticketType)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("影厅") {
                    TextField("影厅", text: $session.draft.hall)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("票价") {
                    TextField("28.00", text: $session.draft.ticketPrice)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("推算结束时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(endTimeText)
                        .monospacedDigit()
                }

                if !session.message.isEmpty {
                    Text(session.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Group {
                    Text("切纸位置").font(.headline)
                    HStack(spacing: 10) {
                        Stepper(
                            "切纸前走纸 \(cutFeedLines) 行",
                            value: Binding(
                                get: { cutFeedLines },
                                set: { setCutFeedLines($0) }
                            ),
                            in: 0...40
                        )
                        Button("恢复默认") {
                            setCutFeedLines(appState.settings.printerConfig.feedLinesBeforeCut)
                        }
                        .controlSize(.small)
                    }
                    Text("控制打印结束后到切刀之间的空白；越小越省纸，过小可能裁到票面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("预览") { previewTicket() }
                        .disabled(template == nil || isPrinting)
                    Button(isPrinting ? "打印中…" : "打印") {
                        Task { await printTicket() }
                    }
                    .disabled(template == nil || isPrinting)
                    Button("填入真票示例") {
                        if template?.usesIMAXSydneyLayout == true {
                            session.draft = .imaxSydneySample()
                        } else {
                            session.draft = .ritzMatrixSample()
                        }
                    }
                    Button("打印记录") { showHistory = true }
                    Button("清空草稿") { session.resetDraft() }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前使用模板").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { session.settings.activeTemplateId ?? session.templates.first?.id },
                set: { if let id = $0 { session.selectTemplate(id) } }
            )) {
                ForEach(session.templates) { t in
                    Text(t.name).tag(Optional(t.id))
                }
            }
            .labelsHidden()
        }
    }

    private var cutFeedLines: Int {
        template?.resolvedFeedLinesBeforeCut(config: appState.settings.printerConfig)
            ?? appState.settings.printerConfig.feedLinesBeforeCut
    }

    private func setCutFeedLines(_ value: Int) {
        let clamped = max(0, min(40, value))
        guard let id = template?.id else { return }
        session.updateTemplateMeta(id: id) { $0.feedLinesBeforeCut = clamped }
    }

    private var endTimeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d, yyyy h:mm a"
        return f.string(from: session.draft.showEndTime)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Preview column (top: preview · bottom: template gallery)

    private var templatePageCount: Int {
        max(1, Int(ceil(Double(session.templates.count) / Double(Self.templatesPerPage))))
    }

    private var pagedTemplates: [MovieTicketTemplate] {
        let start = templatePage * Self.templatesPerPage
        return Array(session.templates.dropFirst(start).prefix(Self.templatesPerPage))
    }

    private var previewColumn: some View {
        VSplitView {
            previewPane
                .frame(minHeight: 220)
            templateGalleryPane
                .frame(minHeight: 160)
        }
        .onAppear { clampTemplatePage() }
        .onChange(of: session.templates.count) { _, _ in clampTemplatePage() }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览").font(.headline)
            if let image = livePreviewImage() {
                ScrollView {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 302)
                        .background(Color.white)
                        .border(Color.secondary.opacity(0.3))
                }
            } else {
                Text("请先选择或创建模板")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var templateGalleryPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模板选择").font(.headline)
                Spacer()
                Text("第 \(templatePage + 1) / \(templatePageCount) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    templatePage = max(0, templatePage - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(templatePage <= 0)
                .help("上一页")
                Button {
                    templatePage = min(templatePageCount - 1, templatePage + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(templatePage >= templatePageCount - 1)
                .help("下一页")
            }

            if session.templates.isEmpty {
                Text("暂无模板。请到「模板」页新建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                let columns = [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ]
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(pagedTemplates) { t in
                            templateCard(t)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func templateCard(_ t: MovieTicketTemplate) -> some View {
        let selected = (session.settings.activeTemplateId ?? session.templates.first?.id) == t.id
        return Button {
            session.selectTemplate(t.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "ticket.fill" : "ticket")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(t.name)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        selected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func clampTemplatePage() {
        templatePage = min(max(0, templatePage), templatePageCount - 1)
    }

    private func livePreviewImage() -> NSImage? {
        guard let t = template else { return nil }
        let result = MovieTicketPrintComposer.compose(
            template: t,
            draft: session.draft,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig
        )
        return result.previewImage
    }

    // MARK: - Actions

    private func previewTicket() {
        guard let image = livePreviewImage() else {
            session.message = "无法生成预览"
            return
        }
        previewPayload = PreviewPayload(image: image)
    }

    private func printTicket() async {
        guard let t = template else {
            session.message = "请先选择模板"
            return
        }
        guard appState.settings.selectedPrinterName != nil else {
            appState.lastError = "请先在设置中选择打印机"
            return
        }
        isPrinting = true
        defer { isPrinting = false }
        let draftSnapshot = session.draft
        let result = MovieTicketPrintComposer.compose(
            template: t,
            draft: draftSnapshot,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig
        )
        let statusPollingWasActive = appState.gmailSync.isRunning
        if let record = await appState.runDiagnosticPrint(
            artifacts: result.artifacts,
            statusPollingWasActive: statusPollingWasActive
        ) {
            if record.transportError == nil {
                let png = result.artifacts.pngData
                session.recordSuccessfulPrint(template: t, draft: draftSnapshot, previewPNG: png)
                session.resetDraft()
                session.message = "已发送到打印机"
            } else {
                session.message = "打印失败: \(record.transportError ?? "")"
            }
        }
    }

    private func searchTMDBTitle(forDurationOnly: Bool = false) async {
        isSearchingTMDB = true
        defer { isSearchingTMDB = false }
        do {
            let provider = TMDBMovieMetadataProvider(settings: appState.settings)
            let results = try await provider.search(title: session.draft.movieTitle)
            tmdbResults = results
            if results.isEmpty {
                session.message = "未找到匹配影片"
            } else if forDurationOnly, results.count == 1 {
                session.draft.movieDurationMinutes = results[0].runtimeMinutes
                session.message = "已填入时长 \(results[0].runtimeMinutes) 分钟"
            } else {
                showTMDBSheet = true
            }
        } catch {
            session.message = error.localizedDescription
        }
    }

    private func importPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Prefer the rule linked to the current template when present.
            if let ruleId = session.activeTemplate?.pdfRuleId,
               let linked = session.pdfRules.first(where: { $0.id == ruleId }),
               !linked.regions.isEmpty {
                applyPDF(url: url, rule: linked)
                return
            }

            let text = try MovieTicketPDFRecognitionService.extractPlainText(from: url)
            let hits = MovieTicketPDFRecognitionService.matchRules(text: text, rules: session.pdfRules)
            if hits.count == 1 {
                applyPDF(url: url, rule: hits[0])
            } else if hits.isEmpty {
                pendingPDFURL = url
                matchedRules = session.pdfRules
                showRulePicker = true
                session.message = "未匹配检测关键字，请手动选择规则"
            } else {
                pendingPDFURL = url
                matchedRules = hits
                showRulePicker = true
            }
        } catch {
            session.message = error.localizedDescription
        }
    }

    private func applyPDF(url: URL, rule: MovieTicketPDFRule) {
        pendingPDFURL = nil
        if let tid = rule.linkedTemplateId {
            session.selectTemplate(tid)
        }
        let fields = MovieTicketPDFRecognitionService.extractAllFields(from: url, rule: rule)
        MovieTicketPDFRecognitionService.apply(fields: fields, to: &session.draft)
        let missing: [String] = [
            session.draft.movieTitle.isEmpty ? "影片名称" : nil,
            session.draft.serialNumber.isEmpty ? "流水号" : nil,
            session.draft.ticketType.isEmpty ? "票型" : nil,
            session.draft.hall.isEmpty ? "影厅" : nil
        ].compactMap { $0 }
        if missing.isEmpty {
            session.message = "已按「\(rule.name)」识别并填入"
        } else if fields.isEmpty {
            session.message = "未能识别（请确认规则已框选，且关键字段尽量使用「识别关键词」）"
        } else {
            session.message = "已部分识别；请补全：\(missing.joined(separator: "、"))"
        }
    }

    private var tmdbSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择影片").font(.title2.weight(.semibold))
            List(tmdbResults) { item in
                Button {
                    session.draft.movieTitle = item.title
                    session.draft.movieDurationMinutes = item.runtimeDurationOrZero
                    showTMDBSheet = false
                    session.message = "已选择 \(item.title)（\(item.runtimeMinutes) 分钟）"
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text("\(item.year) · \(item.runtimeMinutes) 分钟")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            Button("关闭") { showTMDBSheet = false }
        }
        .padding()
        .frame(width: 420, height: 480)
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("打印记录").font(.title2.weight(.semibold))
                Spacer()
                Button("清理全部", role: .destructive) {
                    session.clearHistory()
                }
                .disabled(session.printHistory.isEmpty)
                Button("关闭") { showHistory = false }
            }
            if session.printHistory.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.printHistory) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.summary).fontWeight(.semibold)
                                Spacer()
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(record.templateName).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("载入") {
                                    session.loadHistory(record)
                                    showHistory = false
                                }
                                Button("重新打印") {
                                    session.loadHistory(record)
                                    showHistory = false
                                    Task { await printTicket() }
                                }
                                Button("导出 PDF") { exportHistoryPDF(record) }
                                Button("删除", role: .destructive) {
                                    session.deleteHistory(record.id)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .frame(width: 520, height: 520)
    }

    private func exportHistoryPDF(_ record: MovieTicketPrintHistoryRecord) {
        guard let image = NSImage(data: record.previewPNG) else {
            session.message = "无法导出：预览图缺失"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "影票-\(record.summary)-\(Int(record.createdAt.timeIntervalSince1970)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let page = PDFPage(image: image) else {
            session.message = "无法创建 PDF"
            return
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        if doc.write(to: url) {
            session.message = "已导出 PDF"
        } else {
            session.message = "写入 PDF 失败"
        }
    }
}

private extension MovieSearchResult {
    var runtimeDurationOrZero: Int { runtimeMinutes }
}
