import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MovieTicketMainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: MovieTicketSession
    @Environment(\.appLanguage) private var language

    @State private var titleMode: TitleMode = .local
    @State private var durationMode: DurationMode = .local
    @State private var isPrinting = false
    @State private var showHistory = false
    @State private var previewPayload: PreviewPayload?
    @State private var tmdbResults: [MovieSearchResult] = []
    @State private var showTMDBSheet = false
    @State private var isSearchingTMDB = false
    /// Separate search string for TMDB duration/rating verify (does not rewrite ticket title).
    @State private var tmdbQuery: String = ""
    @State private var tmdbAlertMessage: String?
    @State private var tmdbSheetPurpose: TMDBSheetPurpose = .pickTitle
    @State private var showRulePicker = false
    @State private var pendingPDFURL: URL?
    @State private var matchedRules: [MovieTicketPDFRule] = []
    /// Bottom template gallery page (0-based).
    @State private var templatePage: Int = 0

    private var effectiveTMDBQuery: String {
        let q = tmdbQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return q }
        return Self.cleanedTitleForTMDBSearch(session.draft.movieTitle)
    }

    private static let templatesPerPage = 8
    /// Quick picks for ticket type (print label); field remains freely editable.
    private static let ticketTypePresets = ["Adult", "Child", "Senior", "Concession"]

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

    /// What a TMDB sheet pick should update (title stays unless `.pickTitle`).
    private enum TMDBSheetPurpose {
        case pickTitle
        case fillDuration
        case fillRating
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

    /// QR/barcode elements that need a custom payload field on the main form.
    private var customCodeElements: [MovieTicketElement] {
        (template?.elements ?? [])
            .filter(\.usesCustomCodePayload)
            .sorted { $0.zIndex < $1.zIndex }
    }

    private func customCodeFieldTitle(_ el: MovieTicketElement) -> String {
        let custom = el.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        switch el.fieldKind {
        case .qrCode: return L10n.ui("二维码内容")
        case .barcode: return L10n.ui("条码内容")
        default: return L10n.ui("扫码内容")
        }
    }

    private func customCodeBinding(for id: UUID) -> Binding<String> {
        let key = id.uuidString
        return Binding(
            get: { session.draft.customCodePayloads[key] ?? "" },
            set: { session.draft.customCodePayloads[key] = $0 }
        )
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
        .alert(L10n.ui("TMDB 核查"), isPresented: Binding(
            get: { tmdbAlertMessage != nil },
            set: { if !$0 { tmdbAlertMessage = nil } }
        )) {
            Button(L10n.ui("好"), role: .cancel) { tmdbAlertMessage = nil }
        } message: {
            Text(tmdbAlertMessage ?? "")
        }
        .confirmationDialog(L10n.ui("未能自动识别影院，请选择 PDF 识别规则"), isPresented: $showRulePicker, titleVisibility: .visible) {
            ForEach(matchedRules.isEmpty ? session.pdfRules : matchedRules) { rule in
                Button(rule.name) {
                    if let url = pendingPDFURL {
                        applyPDF(url: url, rule: rule)
                    }
                }
            }
            Button(L10n.ui("手动填写"), role: .cancel) {
                pendingPDFURL = nil
                session.message = L10n.ui("请手动填写影票信息")
            }
        }
    }

    // MARK: - Form

    private var formColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                templatePicker

                Group {
                    Text(L10n.ui("影片名称")).font(.headline)
                    Picker("", selection: $titleMode) {
                        ForEach(TitleMode.allCases) { Text(L10n.ui($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(L10n.ui("影片名称"), text: $session.draft.movieTitle)
                        .textFieldStyle(.roundedBorder)
                    Toggle(L10n.ui("打印时附加分级（如 The Bride! (M)）"), isOn: $session.draft.printContentRating)
                    if session.draft.printContentRating {
                        TextField(L10n.ui("核查用英文片名（可改，不影响小票片名）"), text: $tmdbQuery)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { syncTMDBQueryFromTicketTitleIfNeeded(force: tmdbQuery.isEmpty) }
                            .onSubmit { submitTMDBVerify(purpose: .fillRating) }
                        HStack {
                            TextField(L10n.ui("分级（如 MA15+）"), text: $session.draft.contentRating)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 160)
                            Button(isSearchingTMDB ? L10n.ui("核查中…") : L10n.ui("联网核查分级")) {
                                submitTMDBVerify(purpose: .fillRating)
                            }
                            .disabled(effectiveTMDBQuery.isEmpty || isSearchingTMDB)
                        }
                        Text(L10n.ui("核查逻辑与时长相同：清洗英文片名后选片；只填分级，不改小票片名。打开开关后才会印成「片名 (分级)」。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !session.draft.contentRating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let mapped = MovieTicketRatingPrintMapping.printLabel(
                                for: session.draft.contentRating,
                                mappings: session.settings.ratingPrintMappings
                            )
                            Text("\(L10n.ui("票面分级："))\(mapped)　\(L10n.ui("打印预览："))\(session.draft.printedMovieTitle(using: session.settings.ratingPrintMappings))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        DisclosureGroup(L10n.ui("票面分级映射（核查原文 → 票面写法）")) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.settings.ratingPrintMappings.enumerated()), id: \.element.id) { index, _ in
                                    HStack(spacing: 6) {
                                        TextField(L10n.ui("原文"), text: ratingMappingBinding(index, keyPath: \.source))
                                            .textFieldStyle(.roundedBorder)
                                        Text("→")
                                            .foregroundStyle(.secondary)
                                        TextField(L10n.ui("票面"), text: ratingMappingBinding(index, keyPath: \.printAs))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 72)
                                        Button(role: .destructive) {
                                            session.settings.ratingPrintMappings.remove(at: index)
                                            session.settings.save()
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                HStack {
                                    Button(L10n.ui("添加映射")) {
                                        session.settings.ratingPrintMappings.append(
                                            MovieTicketRatingPrintMapping(source: "", printAs: "")
                                        )
                                        session.settings.save()
                                    }
                                    .controlSize(.small)
                                    Button(L10n.ui("恢复默认")) {
                                        session.settings.ratingPrintMappings = MovieTicketRatingPrintMapping.defaults
                                        session.settings.save()
                                    }
                                    .controlSize(.small)
                                }
                                Text(L10n.ui("例如 MA15+ → MA15。核查仍保存原文；打开开关后票面用右侧写法。"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                    }
                    HStack {
                        if titleMode == .online {
                            Button(isSearchingTMDB ? L10n.ui("搜索中…") : L10n.ui("联网搜索")) {
                                syncTMDBQueryFromTicketTitleIfNeeded(force: tmdbQuery.isEmpty)
                                Task { await searchTMDBTitle(purpose: .pickTitle) }
                            }
                            .disabled(effectiveTMDBQuery.isEmpty || isSearchingTMDB)
                        }
                        Button(L10n.ui("导入 PDF 订单")) { importPDF() }
                    }
                }

                Group {
                    Text(L10n.ui("影片时长（分钟）")).font(.headline)
                    Picker("", selection: $durationMode) {
                        ForEach(DurationMode.allCases) { Text(L10n.ui($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: durationMode) { _, mode in
                        if mode == .online {
                            syncTMDBQueryFromTicketTitleIfNeeded(force: true)
                        }
                    }
                    if durationMode == .online {
                        TextField(L10n.ui("核查用英文片名（可改，不影响小票片名）"), text: $tmdbQuery)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { syncTMDBQueryFromTicketTitleIfNeeded(force: true) }
                            .onChange(of: session.draft.movieTitle) { _, _ in
                                syncTMDBQueryFromTicketTitleIfNeeded(force: true)
                            }
                            .onSubmit { submitTMDBVerify(purpose: .fillDuration) }
                        Text(L10n.ui("自动去掉括号/(35mm)等与汉字，只留英文搜索；确认结果只改时长，不改小票片名。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField(L10n.ui("分钟"), value: $session.draft.movieDurationMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        if durationMode == .online {
                            Button(isSearchingTMDB ? L10n.ui("核查中…") : L10n.ui("联网核查时长")) {
                                submitTMDBVerify(purpose: .fillDuration)
                            }
                            .disabled(effectiveTMDBQuery.isEmpty || isSearchingTMDB)
                        }
                    }
                }

                Group {
                    Text(L10n.ui("广告时长")).font(.headline)
                    HStack {
                        TextField(L10n.ui("分钟"), value: $session.draft.adDurationMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        ForEach([0, 5, 10, 15, 20], id: \.self) { m in
                            Button(m == 0 ? L10n.ui("无") : "\(m) \(L10n.ui("分钟"))") {
                                session.draft.adDurationMinutes = m
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Group {
                    Text(L10n.ui("票张数")).font(.headline)
                    HStack(spacing: 8) {
                        ForEach(1...4, id: \.self) { n in
                            Button("\(n) \(L10n.ui("张"))") {
                                session.draft.setTicketCount(n)
                            }
                            .buttonStyle(.bordered)
                            .tint(session.draft.ticketCount == n ? Color.accentColor : nil)
                            .controlSize(.small)
                        }
                        TextField(
                            L10n.ui("张数"),
                            value: Binding(
                                get: { session.draft.ticketCount },
                                set: { session.draft.setTicketCount($0) }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        Text(L10n.ui("张"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(ticketCountHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Group {
                    Text(L10n.ui("座位区域")).font(.headline)
                    Picker("", selection: Binding(
                        get: { session.draft.seatModeUnallocated },
                        set: { unallocated in
                            session.draft.seatModeUnallocated = unallocated
                            session.draft.syncSeatArrays()
                        }
                    )) {
                        Text(L10n.ui("无特定座位")).tag(true)
                        Text(L10n.ui("指定座位")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !session.draft.seatModeUnallocated {
                        ForEach(0..<session.draft.ticketCount, id: \.self) { index in
                            TextField(
                                session.draft.ticketCount > 1
                                    ? (L10n.current == .chinese
                                       ? "第 \(index + 1) 张座位（如 G12）"
                                       : "Seat \(index + 1) (e.g. G12)")
                                    : L10n.ui("座位（如 G12）"),
                                text: seatBinding(at: index)
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                    } else if let label = template?.unallocatedSeatLabel {
                        Text("\(L10n.ui("票面显示："))\(label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                labeled(L10n.ui("流水号")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L10n.ui("订单/流水号（不含 /001）"), text: serialBaseBinding)
                            .textFieldStyle(.roundedBorder)
                        if !session.draft.serialBase.isEmpty {
                            Text("条码/流水将打印为：\(serialPreviewList)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                ForEach(customCodeElements) { el in
                    labeled(customCodeFieldTitle(el)) {
                        TextField(
                            L10n.ui("扫码内容"),
                            text: customCodeBinding(for: el.id)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                labeled(L10n.ui("日期")) {
                    DatePicker("", selection: $session.draft.showDate, displayedComponents: .date)
                        .labelsHidden()
                }
                labeled(L10n.ui("开始时间")) {
                    DatePicker("", selection: $session.draft.showStartTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                labeled(L10n.ui("票型")) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Adult / Child…", text: $session.draft.ticketType)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 6) {
                            ForEach(Self.ticketTypePresets, id: \.self) { option in
                                Button(option) {
                                    session.draft.ticketType = option
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(
                                    session.draft.ticketType
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .caseInsensitiveCompare(option) == .orderedSame
                                        ? Color.accentColor
                                        : Color.secondary
                                )
                            }
                        }
                    }
                }
                labeled(L10n.ui("影厅")) {
                    TextField(L10n.ui("影厅"), text: $session.draft.hall)
                        .textFieldStyle(.roundedBorder)
                }
                labeled(L10n.ui("票价")) {
                    TextField("28.00", text: $session.draft.ticketPrice)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.ui("推算结束时间"))
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
                    Text(L10n.ui("切纸位置")).font(.headline)
                    HStack(spacing: 10) {
                        Stepper(
                            "\(L10n.ui("切纸前走纸")) \(cutFeedLines) \(L10n.ui("行"))",
                            value: Binding(
                                get: { cutFeedLines },
                                set: { setCutFeedLines($0) }
                            ),
                            in: 0...40
                        )
                        Button(L10n.ui("恢复默认")) {
                            setCutFeedLines(appState.settings.printerConfig.feedLinesBeforeCut)
                        }
                        .controlSize(.small)
                    }
                    Text(L10n.ui("控制打印结束后到切刀之间的空白；越小越省纸，过小可能裁到票面。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(L10n.ui("预览")) { previewTicket() }
                        .disabled(template == nil || isPrinting)
                    Button(isPrinting ? L10n.ui("打印中…") : L10n.ui("打印 (⌘↩)")) {
                        Task { await printTicket() }
                    }
                    .disabled(template == nil || isPrinting)
                    .keyboardShortcut(.return, modifiers: .command)
                    Button(L10n.ui("填入真票示例")) {
                        if template?.usesIMAXSydneyLayout == true {
                            session.draft = .imaxSydneySample()
                        } else {
                            session.draft = .ritzMatrixSample()
                        }
                    }
                    Button(L10n.ui("打印记录")) { showHistory = true }
                    Button(L10n.ui("清空草稿")) { session.resetDraft() }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.ui("当前使用模板", language)).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { session.settings.activeTemplateId ?? session.templates.first?.id },
                set: { if let id = $0 { session.selectTemplate(id) } }
            )) {
                ForEach(session.templates) { t in
                    let shown = L10n.ui(t.name, language)
                    Text(shown).tag(Optional(t.id))
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
            Text(L10n.ui("预览")).font(.headline)
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
                Text(L10n.ui("请先选择或创建模板"))
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
                Text(L10n.ui("模板选择")).font(.headline)
                Spacer()
                Text(
                    L10n.current == .chinese
                        ? "第 \(templatePage + 1) / \(templatePageCount) 页"
                        : "Page \(templatePage + 1) / \(templatePageCount)"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    templatePage = max(0, templatePage - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(templatePage <= 0)
                .help(L10n.ui("上一页"))
                Button {
                    templatePage = min(templatePageCount - 1, templatePage + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(templatePage >= templatePageCount - 1)
                .help(L10n.ui("下一页"))
            }

            if session.templates.isEmpty {
                Text(L10n.ui("暂无模板。请到「模板」页新建。"))
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
                Text(L10n.ui(t.name, language))
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

    private var ticketCountHint: String {
        let n = session.draft.ticketCount
        if n <= 1 {
            return L10n.ui("将打印 1 张票，流水号/条码后缀为 /001")
        }
        let suffix = String(format: "%03d", n)
        return "\(L10n.ui("将依次打印")) \(n) \(L10n.ui("张票（/001 … /"))\(suffix)\(L10n.ui("）；指定座位时每张票使用对应座位"))"
    }

    private var serialPreviewList: String {
        (0..<session.draft.ticketCount)
            .map { session.draft.serialForTicket(at: $0) }
            .joined(separator: "、")
    }

    private var serialBaseBinding: Binding<String> {
        Binding(
            get: { session.draft.serialBase },
            set: { session.draft.serialNumber = MovieTicketDraft.serialBase(from: $0) }
        )
    }

    private func seatBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                // Do not mutate draft in Binding.get — that retriggers @Published and freezes UI.
                guard session.draft.seatAreas.indices.contains(index) else { return "" }
                return session.draft.seatAreas[index]
            },
            set: { newValue in
                session.draft.syncSeatArrays()
                guard session.draft.seatAreas.indices.contains(index) else { return }
                session.draft.seatAreas[index] = newValue
                if index == 0 { session.draft.seatArea = newValue }
            }
        )
    }

    private func livePreviewImage() -> NSImage? {
        guard let t = template else { return nil }
        // Preview the first ticket ( /001 + first seat ).
        let result = MovieTicketPrintComposer.compose(
            template: t,
            draft: session.draft.draftForTicket(at: 0),
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig
        )
        return result.previewImage
    }

    // MARK: - Actions

    private func previewTicket() {
        guard let image = livePreviewImage() else {
            session.message = L10n.ui("无法生成预览")
            return
        }
        previewPayload = PreviewPayload(image: image)
    }

    private func printTicket() async {
        guard let t = template else {
            session.message = L10n.ui("请先选择模板")
            return
        }
        guard appState.settings.selectedPrinterName != nil else {
            appState.lastError = L10n.ui("请先在设置中选择打印机")
            return
        }
        isPrinting = true
        defer { isPrinting = false }

        var working = session.draft
        working.syncSeatArrays()
        working.serialNumber = working.serialBase
        let count = working.ticketCount
        let statusPollingWasActive = false
        var printed = 0
        var lastError: String?

        for index in 0..<count {
            let ticketDraft = working.draftForTicket(at: index)
            let result = MovieTicketPrintComposer.compose(
                template: t,
                draft: ticketDraft,
                backgroundImage: session.backgroundImage,
                logoImages: session.logoImages,
                config: appState.settings.printerConfig
            )
            if let record = await appState.runDiagnosticPrint(
                artifacts: result.artifacts,
                statusPollingWasActive: statusPollingWasActive && index == 0
            ) {
                if record.transportError == nil {
                    session.recordSuccessfulPrint(
                        template: t,
                        draft: ticketDraft,
                        previewPNG: result.artifacts.pngData
                    )
                    printed += 1
                } else {
                    lastError = record.transportError
                    break
                }
            } else {
                lastError = L10n.ui("打印中断")
                break
            }
        }

        if printed == count {
            session.resetDraft()
            session.message = count == 1
                ? L10n.ui("已发送到打印机")
                : "已依次打印 \(printed) 张票"
        } else if printed > 0 {
            session.message = "已打印 \(printed)/\(count) 张后失败：\(lastError ?? "")"
        } else {
            session.message = "打印失败: \(lastError ?? "")"
        }
    }

    private func ratingMappingBinding(
        _ index: Int,
        keyPath: WritableKeyPath<MovieTicketRatingPrintMapping, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard session.settings.ratingPrintMappings.indices.contains(index) else { return "" }
                return session.settings.ratingPrintMappings[index][keyPath: keyPath]
            },
            set: { newValue in
                guard session.settings.ratingPrintMappings.indices.contains(index) else { return }
                session.settings.ratingPrintMappings[index][keyPath: keyPath] = newValue
                session.settings.save()
            }
        )
    }

    private func submitTMDBVerify(purpose: TMDBSheetPurpose) {
        syncTMDBQueryFromTicketTitleIfNeeded(force: tmdbQuery.isEmpty)
        guard !effectiveTMDBQuery.isEmpty, !isSearchingTMDB else { return }
        Task { await searchTMDBTitle(purpose: purpose) }
    }

    private func syncTMDBQueryFromTicketTitleIfNeeded(force: Bool) {
        let cleaned = Self.cleanedTitleForTMDBSearch(session.draft.movieTitle)
        guard force || tmdbQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        tmdbQuery = cleaned
    }

    /// Strip brackets, film-gauge markers (35mm/70mm), and CJK — keep Latin/digits for TMDB.
    private static func cleanedTitleForTMDBSearch(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(
            of: #"[\(\（\[][^\)\）\]]*[\)\）\]]"#,
            with: " ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?i)\b\d+\s*mm\b"#,
            with: " ",
            options: .regularExpression
        )
        s = String(s.unicodeScalars.filter { scalar in
            !(scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        })
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchTMDBTitle(purpose: TMDBSheetPurpose = .pickTitle) async {
        isSearchingTMDB = true
        defer { isSearchingTMDB = false }
        let query = effectiveTMDBQuery
        guard !query.isEmpty else {
            tmdbAlertMessage = L10n.ui("请先填写核查用片名")
            return
        }
        guard appState.settings.tmdbAPIKeyStored else {
            tmdbAlertMessage = L10n.ui("请先在设置中配置 TMDB API Key")
            return
        }
        do {
            let provider = TMDBMovieMetadataProvider(settings: appState.settings)
            let results = try await provider.search(title: query)
            tmdbResults = results
            if results.isEmpty {
                let msg = L10n.ui("未找到匹配影片")
                tmdbAlertMessage = msg
                session.message = msg
            } else {
                tmdbSheetPurpose = purpose
                showTMDBSheet = true
                switch purpose {
                case .pickTitle:
                    session.message = "请选择匹配的影片（\(results.count) 条）"
                case .fillDuration:
                    session.message = "请选择匹配的影片以填入时长（\(results.count) 条）；小票片名保持不变"
                case .fillRating:
                    session.message = "请选择匹配的影片以填入分级（\(results.count) 条）；小票片名保持不变"
                }
            }
        } catch {
            tmdbAlertMessage = error.localizedDescription
            session.message = error.localizedDescription
        }
    }

    private func importPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let linkedRule: MovieTicketPDFRule? = {
                guard let ruleId = session.activeTemplate?.pdfRuleId else { return nil }
                return session.pdfRules.first(where: { $0.id == ruleId && !$0.regions.isEmpty })
            }()

            // Keywords decide cinema/rule first so importing an IMAX PDF while on Ritz
            // switches templates. Linked rule is only a no-keyword fallback.
            let text = try MovieTicketPDFRecognitionService.extractPlainText(from: url)
            let hits = MovieTicketPDFRecognitionService.matchRules(text: text, rules: session.pdfRules)
            if hits.count == 1 {
                applyPDF(url: url, rule: hits[0])
            } else if hits.isEmpty, let linked = linkedRule {
                applyPDF(url: url, rule: linked)
            } else if hits.isEmpty {
                pendingPDFURL = url
                matchedRules = session.pdfRules
                showRulePicker = true
                session.message = L10n.ui("未匹配检测关键字，请手动选择规则")
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
        MovieTicketPDFRecognitionService.apply(fields: fields, to: &session.draft, rule: rule)
        // Keep serial as base; ticket index suffixes (/001…) come from 票张数.
        session.draft.serialNumber = MovieTicketDraft.serialBase(from: session.draft.serialNumber)
        if !session.draft.seatArea.isEmpty {
            session.draft.seatAreas = [session.draft.seatArea]
        }
        session.draft.syncSeatArrays()
        let missing: [String] = [
            session.draft.movieTitle.isEmpty ? L10n.ui("影片名称") : nil,
            session.draft.serialNumber.isEmpty ? L10n.ui("流水号") : nil,
            session.draft.ticketType.isEmpty ? L10n.ui("票型") : nil,
            session.draft.hall.isEmpty ? L10n.ui("影厅") : nil
        ].compactMap { $0 }
        if missing.isEmpty {
            session.message = "已按「\(rule.name)」识别并填入"
        } else if fields.isEmpty {
            session.message = L10n.ui("未能识别（请确认规则已框选，且关键字段尽量使用「识别关键词」）")
        } else {
            session.message = "已部分识别；请补全：\(missing.joined(separator: "、"))"
        }
    }

    private var tmdbSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tmdbSheetHeader).font(.title2.weight(.semibold))
            Text(tmdbSheetSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            List(tmdbResults) { item in
                Button {
                    applyTMDBPick(item)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if let original = item.originalTitle, original != item.title, !original.isEmpty {
                                Text(original)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(tmdbResultMetaLine(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            Button(L10n.ui("关闭")) { showTMDBSheet = false }
        }
        .padding()
        .frame(width: 420, height: 480)
    }

    private var tmdbSheetHeader: String {
        switch tmdbSheetPurpose {
        case .pickTitle: return L10n.ui("选择影片")
        case .fillDuration: return L10n.ui("选择影片以填入时长")
        case .fillRating: return L10n.ui("选择影片以填入分级")
        }
    }

    private var tmdbSheetSubtitle: String {
        switch tmdbSheetPurpose {
        case .pickTitle:
            return L10n.ui("点选一条以填入片名与时长")
        case .fillDuration:
            return L10n.ui("确认后只更新时长，不改小票片名")
        case .fillRating:
            return L10n.ui("确认后只更新分级，不改小票片名")
        }
    }

    private func tmdbResultMetaLine(_ item: MovieSearchResult) -> String {
        var parts: [String] = [item.year]
        if item.runtimeMinutes > 0 {
            parts.append("\(item.runtimeMinutes) \(L10n.ui("分钟"))")
        } else {
            parts.append(L10n.ui("片长未知"))
        }
        if let cert = item.certification?.trimmingCharacters(in: .whitespacesAndNewlines), !cert.isEmpty {
            parts.append(cert)
        }
        return parts.joined(separator: " · ")
    }

    private func applyTMDBPick(_ item: MovieSearchResult) {
        switch tmdbSheetPurpose {
        case .fillDuration:
            if item.runtimeMinutes > 0 {
                session.draft.movieDurationMinutes = item.runtimeMinutes
            }
            tmdbQuery = Self.cleanedTitleForTMDBSearch(item.originalTitle ?? item.title)
            showTMDBSheet = false
            session.message = item.runtimeMinutes > 0
                ? "已填入时长 \(item.runtimeMinutes) 分钟（小票片名未改）"
                : L10n.ui("已选择匹配项但暂无片长，请手动填写（小票片名未改）")
        case .fillRating:
            let cert = item.certification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cert.isEmpty {
                session.draft.contentRating = cert
            }
            tmdbQuery = Self.cleanedTitleForTMDBSearch(item.originalTitle ?? item.title)
            showTMDBSheet = false
            if cert.isEmpty {
                session.message = L10n.ui("已选择匹配项但暂无分级，请手动填写（小票片名未改）")
            } else {
                session.message = "已填入分级 \(cert)（小票片名未改）"
            }
        case .pickTitle:
            session.draft.movieTitle = item.title
            tmdbQuery = Self.cleanedTitleForTMDBSearch(item.originalTitle ?? item.title)
            if item.runtimeMinutes > 0 {
                session.draft.movieDurationMinutes = item.runtimeMinutes
            }
            if let cert = item.certification?.trimmingCharacters(in: .whitespacesAndNewlines), !cert.isEmpty {
                session.draft.contentRating = cert
            }
            showTMDBSheet = false
            session.message = item.runtimeMinutes > 0
                ? "已选择 \(item.title)（\(item.runtimeMinutes) 分钟）"
                : "已选择 \(item.title)"
        }
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.ui("打印记录")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.ui("清理全部"), role: .destructive) {
                    session.clearHistory()
                }
                .disabled(session.printHistory.isEmpty)
                Button(L10n.ui("关闭")) { showHistory = false }
            }
            if session.printHistory.isEmpty {
                Text(L10n.ui("暂无记录")).foregroundStyle(.secondary)
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
                                Button(L10n.ui("载入")) {
                                    session.loadHistory(record)
                                    showHistory = false
                                }
                                Button(L10n.ui("重新打印")) {
                                    session.loadHistory(record)
                                    showHistory = false
                                    Task { await printTicket() }
                                }
                                Button(L10n.ui("导出 PDF")) { exportHistoryPDF(record) }
                                Button(L10n.ui("删除"), role: .destructive) {
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
            session.message = L10n.ui("无法导出：预览图缺失")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "影票-\(record.summary)-\(Int(record.createdAt.timeIntervalSince1970)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let page = PDFPage(image: image) else {
            session.message = L10n.ui("无法创建 PDF")
            return
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        if doc.write(to: url) {
            session.message = L10n.ui("已导出 PDF")
        } else {
            session.message = L10n.ui("写入 PDF 失败")
        }
    }
}

private extension MovieSearchResult {
    var runtimeDurationOrZero: Int { runtimeMinutes }
}
