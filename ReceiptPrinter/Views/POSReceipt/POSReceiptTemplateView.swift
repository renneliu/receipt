import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct POSReceiptTemplateView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: POSReceiptSession

    @State private var selectedElementId: UUID?
    @State private var newName = "新POS模板"
    @State private var excelStatus = ""
    @State private var previewPayload: PreviewPayload?
    @State private var liveCanvasImage: NSImage?
    @State private var liveCanvasHeight: CGFloat = 480
    @State private var liveRefreshTask: Task<Void, Never>?
    /// Skip full raster while the user is dragging/resizing chrome (ink catches up on release).
    @State private var liveRefreshSuspended = false
    @State private var renameTarget: POSReceiptTemplate?
    @State private var renameText = ""
    private static let fontSizeChoices: [CGFloat] = [10, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48]

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    private var templateBinding: Binding<POSReceiptTemplate>? {
        guard session.editingTemplate != nil else { return nil }
        return Binding(
            get: { session.editingTemplate! },
            set: { session.editingTemplate = $0 }
        )
    }

    var body: some View {
        HSplitView {
            libraryColumn
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            if templateBinding != nil {
                designerColumn
                    .frame(minWidth: 360)
                inspectorColumn
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            } else {
                ContentUnavailableView("选择或新建模板", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
        .onChange(of: session.editingTemplate) { _, _ in
            scheduleLiveCanvasRefresh()
        }
        .onChange(of: session.logoImages) { _, _ in
            scheduleLiveCanvasRefresh()
        }
        .onChange(of: session.backgroundImage) { _, _ in
            scheduleLiveCanvasRefresh()
        }
        .onAppear { scheduleLiveCanvasRefresh() }
        .alert("重命名模板", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("确定") { commitRename() }
        } message: {
            Text("输入新的模板名称")
        }
    }

    // MARK: - Library

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模板").font(.headline)
            HStack {
                TextField("名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("新建") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    session.createTemplate(named: name.isEmpty ? "新POS模板" : name)
                }
            }
            List(selection: Binding(
                get: { session.editingTemplate?.id },
                set: { id in
                    guard let id, let t = session.templates.first(where: { $0.id == id }) else { return }
                    session.beginEditing(t)
                    selectedElementId = nil
                }
            )) {
                ForEach(session.templates) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.name)
                            if session.settings.activeTemplateId == t.id {
                                Text("使用中").font(.caption2).foregroundStyle(.tint)
                            }
                        }
                        Spacer()
                    }
                    .tag(t.id)
                    .contextMenu {
                        Button("重命名") {
                            renameTarget = t
                            renameText = t.name
                        }
                        Button("复制") {
                            _ = session.duplicateTemplate(t)
                            selectedElementId = nil
                            excelStatus = "已复制为「\(session.editingTemplate?.name ?? "")」"
                        }
                        Button("设为当前使用") { session.selectTemplate(t.id) }
                        Button("删除", role: .destructive) { session.deleteTemplate(t) }
                    }
                }
            }

            if session.editingTemplate != nil {
                Button("设为当前使用") {
                    if let id = session.editingTemplate?.id {
                        session.selectTemplate(id)
                    }
                }
                .disabled(session.settings.activeTemplateId == session.editingTemplate?.id)
                Button("保存模板") { session.persistEditingTemplate() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("预览打印效果") { previewTemplate() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Text("使用示例条目预览成票效果")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            excelSection
        }
        .padding(8)
    }

    private var excelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Excel（本模板）").font(.headline)
            if let t = session.editingTemplate {
                Text(t.excelDisplayName ?? "未绑定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack {
                    Button("上传/更换") { pickExcel() }
                    Button("更新") { refreshExcel() }
                        .disabled(t.excelBookmarkData == nil)
                    Button("清除") { clearExcel() }
                        .disabled(t.excelBookmarkData == nil)
                }

                if !t.excelCachedHeaders.isEmpty {
                    columnPicker("编号列", selection: Binding(
                        get: { session.editingTemplate?.excelColumnMap.codeHeader },
                        set: { session.editingTemplate?.excelColumnMap.codeHeader = $0 }
                    ), headers: t.excelCachedHeaders)
                    columnPicker("项目列", selection: Binding(
                        get: { session.editingTemplate?.excelColumnMap.nameHeader },
                        set: { session.editingTemplate?.excelColumnMap.nameHeader = $0 }
                    ), headers: t.excelCachedHeaders)
                    columnPicker("数量列", selection: Binding(
                        get: { session.editingTemplate?.excelColumnMap.quantityHeader },
                        set: { session.editingTemplate?.excelColumnMap.quantityHeader = $0 }
                    ), headers: t.excelCachedHeaders)
                    columnPicker("金额列", selection: Binding(
                        get: { session.editingTemplate?.excelColumnMap.amountHeader },
                        set: { session.editingTemplate?.excelColumnMap.amountHeader = $0 }
                    ), headers: t.excelCachedHeaders)
                }

                if let count = session.excelRowCount {
                    Text("行数：\(count)").font(.caption).foregroundStyle(.secondary)
                }
                if !excelStatus.isEmpty {
                    Text(excelStatus).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("先选择模板").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func columnPicker(_ title: String, selection: Binding<String?>, headers: [String]) -> some View {
        Picker(title, selection: Binding(
            get: { selection.wrappedValue ?? "" },
            set: { selection.wrappedValue = $0.isEmpty ? nil : $0 }
        )) {
            Text("（未映射）").tag("")
            ForEach(headers, id: \.self) { h in
                Text(h).tag(h)
            }
        }
    }

    // MARK: - Designer

    private var designerColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolBar
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    canvas
                        .padding(16)
                }
                .onChange(of: selectedElementId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .padding(8)
    }

    private var toolBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("背景图") { pickBackground() }
                Button("Logo") { pickLogo() }
                Button("文字框") { addTextBox() }
                Button("日期") { addDate() }
                Button("时间") { addTime() }
                Button("自动编号") { addAutoNumber() }
            }
            HStack(spacing: 8) {
                Button("项目位") { addField(.name) }
                Button("添加横线") { addDivider(dashed: false) }
                Button("添加虚线") { addDivider(dashed: true) }
            }
            HStack(spacing: 8) {
                Button("数量小计") { addField(.quantitySubtotal) }
                Button("金额小计") { addField(.amountSubtotal) }
                Button("附加费") { addField(.surcharge) }
                Button("金额合计") { addField(.amountTotal) }
                Button("总计") { addField(.itemCount) }
            }
            HStack(spacing: 8) {
                if let t = session.editingTemplate {
                    Toggle("参考线网格", isOn: Binding(
                        get: { session.editingTemplate?.gridEnabled ?? t.gridEnabled },
                        set: { session.editingTemplate?.gridEnabled = $0 }
                    ))
                }
                Spacer()
                Button("预览") { previewTemplate() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }

    private var canvas: some View {
        Group {
            if let t = session.editingTemplate {
                let paperW = t.paperSize.width
                let inkH = liveCanvasImage.map { img in
                    img.size.height * (paperW / max(img.size.width, 1))
                } ?? liveCanvasHeight
                let paperH = max(t.canvasHeight, inkH)
                let paper = CGSize(width: paperW, height: paperH)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: paper.width, height: paper.height)
                        .shadow(radius: 2)

                    if let live = liveCanvasImage {
                        Image(nsImage: live)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: paper.width, height: inkH)
                            .position(x: paper.width / 2, y: inkH / 2)
                            .allowsHitTesting(false)
                    } else if let bg = session.backgroundImage {
                        Image(nsImage: bg)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(t.backgroundScalePercent / 100)
                            .frame(width: paper.width, height: paper.height)
                            .opacity(0.85)
                            .allowsHitTesting(false)
                    }

                    // Above underlay so guides cover the full paper (live preview is opaque white).
                    if t.gridEnabled {
                        POSGridBackground(size: paper, step: max(16, t.gridSize))
                    }

                    ForEach(t.elements.sorted(by: { $0.zIndex < $1.zIndex })) { el in
                        elementOverlay(el, paper: paper, chromeOnly: liveCanvasImage != nil)
                            .id(el.id)
                    }
                }
                .frame(width: paper.width, height: paper.height)
                .clipped()
                .onTapGesture { selectedElementId = nil }
            }
        }
    }

    private func setCanvasGestureActive(_ active: Bool) {
        liveRefreshSuspended = active
        if active {
            liveRefreshTask?.cancel()
            liveRefreshTask = nil
        } else {
            scheduleLiveCanvasRefresh(immediate: true)
        }
    }

    private func scheduleLiveCanvasRefresh(immediate: Bool = false) {
        if liveRefreshSuspended { return }
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 280_000_000)
            }
            guard !Task.isCancelled else { return }
            guard !liveRefreshSuspended else { return }
            refreshLiveCanvas()
        }
    }

    private func refreshLiveCanvas() {
        guard let t = session.editingTemplate else {
            liveCanvasImage = nil
            return
        }
        let result = POSReceiptPrintComposer.compose(
            template: t,
            items: sampleLineItems(for: t),
            surcharge: t.defaultSurcharge,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig,
            ticketAutoNumber: t.elements.first(where: { $0.kind == .autoNumber })?.autoNumberStart,
            expandFooterShift: false
        )
        let img = result.previewImage
        // Map printer-dot bitmap onto paper points without distorting aspect ratio.
        let scale = t.paperSize.width / max(img.size.width, 1)
        let inkHeight = img.size.height * scale
        liveCanvasImage = img
        liveCanvasHeight = max(t.canvasHeight, inkHeight)
    }

    @ViewBuilder
    private func elementOverlay(_ el: POSReceiptElement, paper: CGSize, chromeOnly: Bool) -> some View {
        let binding = Binding<SequencePlaceholderFrame>(
            get: {
                session.editingTemplate?.elements.first(where: { $0.id == el.id })?.frame
                    ?? el.frame
            },
            set: { newFrame in
                updateElement(id: el.id) { elem in
                    if elem.isLocked {
                        var kept = newFrame
                        kept.x = elem.frame.x
                        kept.y = elem.frame.y
                        elem.frame = kept
                    } else {
                        elem.frame = newFrame
                    }
                }
            }
        )
        let selected = Binding(
            get: { selectedElementId == el.id },
            set: { if $0 { selectedElementId = el.id } }
        )
        let gridOn = session.editingTemplate?.gridEnabled ?? true
        let gridSize = max(16, session.editingTemplate?.gridSize ?? 20)

        switch el.kind {
        case .logo:
            if let img = session.logoImages[el.id] {
                LogoBoxOverlay(
                    title: "Logo",
                    image: img,
                    frame: binding,
                    isSelected: selected,
                    paperSize: paper,
                    onFrameChanged: {
                        syncLogoScaleFromFrame(id: el.id)
                        scheduleLiveCanvasRefresh(immediate: true)
                    },
                    onInteractionChanged: setCanvasGestureActive,
                    onDelete: {
                        selectedElementId = nil
                        guard var t = session.editingTemplate else { return }
                        t.elements.removeAll { $0.id == el.id }
                        session.editingTemplate = t
                        session.logoImages.removeValue(forKey: el.id)
                    },
                    chromeOnly: chromeOnly,
                    isLocked: el.isLocked
                )
            } else {
                POSElementBoxOverlay(
                    frame: binding,
                    isSelected: selected,
                    title: "Logo",
                    previewText: "无图",
                    fontSize: 12,
                    paperSize: paper,
                    gridEnabled: gridOn,
                    gridSize: gridSize,
                    accent: .orange,
                    chromeOnly: false,
                    isLocked: el.isLocked,
                    onFrameChanged: { scheduleLiveCanvasRefresh(immediate: true) },
                    onInteractionChanged: setCanvasGestureActive
                )
            }

        default:
            POSElementBoxOverlay(
                frame: binding,
                isSelected: selected,
                title: elementTitle(el),
                previewText: elementPreview(el),
                fontSize: el.fontSize,
                textAlignment: el.alignment,
                paperSize: paper,
                gridEnabled: gridOn,
                gridSize: gridSize,
                accent: accent(for: el),
                chromeOnly: chromeOnly,
                isLocked: el.isLocked,
                onFrameChanged: {
                    if el.fieldKind == .name || el.fieldKind?.isLineField == true {
                        reflowLineFieldsAfterNameWidthChange()
                    }
                    scheduleLiveCanvasRefresh(immediate: true)
                },
                onInteractionChanged: setCanvasGestureActive
            )
        }
    }

    private func applyNameOrElementWidth(id: UUID, width: CGFloat, isName: Bool) {
        updateElement(id: id) { $0.frame.width = width }
        if isName {
            reflowLineFieldsAfterNameWidthChange()
        }
        scheduleLiveCanvasRefresh(immediate: true)
    }

    private func reflowLineFieldsAfterNameWidthChange() {
        guard var t = session.editingTemplate else { return }
        session.alignLineFieldsToNameRow(&t)
        session.editingTemplate = t
        session.syncEditingIntoTemplates()
    }

    private func elementTitle(_ el: POSReceiptElement) -> String {
        let custom = el.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        switch el.kind {
        case .textBox: return "文字"
        case .fieldPlaceholder: return el.fieldKind?.displayName ?? "字段"
        case .date: return "日期"
        case .time: return "时间"
        case .autoNumber: return el.autoNumberAsBarcode ? "编号条码" : "自动编号"
        case .logo: return "Logo"
        case .divider: return el.isDashed ? "虚线" : "横线"
        }
    }

    private func elementPreview(_ el: POSReceiptElement) -> String {
        switch el.kind {
        case .textBox: return el.content.isEmpty ? "文字" : el.content
        case .fieldPlaceholder:
            switch el.fieldKind {
            case .quantitySubtotal: return "1"
            case .amountSubtotal: return "1.00"
            case .surcharge: return session.editingTemplate?.defaultSurcharge.isEmpty == false
                ? (session.editingTemplate?.defaultSurcharge ?? "0")
                : "0.00"
            case .amountTotal: return "1.00"
            case .itemCount: return "1"
            case .code: return "1"
            case .name: return "示例"
            case .quantity: return "1"
            case .amount: return "1.00"
            case .none: return "?"
            }
        case .date: return el.dateFormat.format()
        case .time:
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: Date())
        case .autoNumber: return el.autoNumberStart
        case .logo: return ""
        case .divider: return el.isDashed ? "- - - - - - - -" : "————————"
        }
    }

    private func accent(for el: POSReceiptElement) -> Color {
        switch el.kind {
        case .fieldPlaceholder:
            return el.fieldKind?.isSummaryField == true ? .green : .blue
        case .autoNumber: return .purple
        case .date, .time: return .teal
        case .divider: return .secondary
        default: return .gray
        }
    }

    // MARK: - Inspector

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let t = session.editingTemplate {
                    Text("模板属性").font(.headline)

                    Toggle("启用编号", isOn: Binding(
                        get: { session.editingTemplate?.enableCode ?? t.enableCode },
                        set: { session.editingTemplate?.enableCode = $0; syncToggles() }
                    ))
                    Toggle("启用数量", isOn: Binding(
                        get: { session.editingTemplate?.enableQuantity ?? t.enableQuantity },
                        set: { session.editingTemplate?.enableQuantity = $0; syncToggles() }
                    ))
                    Toggle("启用金额", isOn: Binding(
                        get: { session.editingTemplate?.enableAmount ?? t.enableAmount },
                        set: { session.editingTemplate?.enableAmount = $0; syncToggles() }
                    ))

                    if showsSurchargeDefaultControl {
                        labeled("附加费默认值") {
                            TextField("0", text: Binding(
                                get: { session.editingTemplate?.defaultSurcharge ?? t.defaultSurcharge },
                                set: { session.editingTemplate?.defaultSurcharge = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    if session.backgroundImage != nil {
                        labeled("背景缩放 %") {
                            Slider(value: Binding(
                                get: { session.editingTemplate?.backgroundScalePercent ?? t.backgroundScalePercent },
                                set: { session.editingTemplate?.backgroundScalePercent = $0 }
                            ), in: 10...400, step: 5)
                        }
                    }

                    labeled("画布高度") {
                        Slider(value: Binding(
                            get: { session.editingTemplate?.canvasHeight ?? t.canvasHeight },
                            set: { session.editingTemplate?.canvasHeight = $0 }
                        ), in: 300...1200, step: 20)
                    }

                    Divider()
                    if let id = selectedElementId,
                       session.editingTemplate?.elements.contains(where: { $0.id == id }) == true {
                        elementInspector(elementId: id)
                    } else {
                        Text("从画布或下方列表选中元素以编辑属性").foregroundStyle(.secondary).font(.caption)
                    }

                    Divider()
                    elementListSection
                }
            }
            .padding()
        }
    }

    private var elementListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("元素列表").font(.headline)
            let elements = (session.editingTemplate?.elements ?? [])
                .sorted(by: { $0.zIndex < $1.zIndex })
            if elements.isEmpty {
                Text("暂无元素").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(elements) { el in
                    Button {
                        selectedElementId = el.id
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(accent(for: el))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(elementTitle(el))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text("(\(Int(el.frame.x)), \(Int(el.frame.y)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedElementId == el.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selectedElementId == el.id ? Color.accentColor.opacity(0.12) : .clear)
                    )
                }
            }
        }
    }

    /// Mutate one element via whole-template reassignment (optional nested writes don't publish).
    private func updateElement(id: UUID, _ body: (inout POSReceiptElement) -> Void) {
        guard var t = session.editingTemplate,
              let idx = t.elements.firstIndex(where: { $0.id == id }) else { return }
        body(&t.elements[idx])
        session.editingTemplate = t
    }

    private func duplicateElementWithStyle(id: UUID) {
        guard var t = session.editingTemplate,
              let source = t.elements.first(where: { $0.id == id }) else { return }
        if source.kind == .fieldPlaceholder, source.fieldKind == .name {
            excelStatus = "项目名称占位符不可复制"
            return
        }
        if source.kind == .fieldPlaceholder, let kind = source.fieldKind, kind.isSummaryField,
           t.hasElement(field: kind) {
            // Allow style-preserving copy even for unique summary fields — second instance for layout.
        }
        var copy = source
        let oldId = copy.id
        copy.id = UUID()
        copy.frame.x += 16
        copy.frame.y += 16
        copy.isLocked = false
        let baseName = elementTitle(source)
        if copy.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.displayName = "\(baseName) 副本"
        } else {
            copy.displayName = "\(copy.displayName) 副本"
        }
        if copy.kind == .logo, let img = session.logoImages[oldId] {
            session.logoImages[copy.id] = img
        }
        let maxZ = t.elements.map(\.zIndex).max() ?? 0
        copy.zIndex = maxZ + 1
        t.elements.append(copy)
        session.editingTemplate = t
        selectedElementId = copy.id
        excelStatus = "已复制「\(elementTitle(copy))」（含样式）"
        scheduleLiveCanvasRefresh(immediate: true)
    }

    private func elementValue<T>(id: UUID, _ keyPath: KeyPath<POSReceiptElement, T>, default defaultValue: T) -> T {
        session.editingTemplate?.elements.first(where: { $0.id == id })?[keyPath: keyPath] ?? defaultValue
    }

    @ViewBuilder
    private func elementInspector(elementId: UUID) -> some View {
        if let el = session.editingTemplate?.elements.first(where: { $0.id == elementId }) {
            Text("元素：\(elementTitle(el))").font(.headline)

            labeled("显示名称") {
                TextField("可选，便于列表识别", text: Binding(
                    get: { elementValue(id: elementId, \.displayName, default: "") },
                    set: { newValue in updateElement(id: elementId) { $0.displayName = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("带样式复制") {
                    duplicateElementWithStyle(id: elementId)
                }
                .help("复制为新元素，保留字号/粗体/对齐/尺寸等样式")
            }

            Toggle(isOn: Binding(
                get: { elementValue(id: elementId, \.isLocked, default: false) },
                set: { newValue in updateElement(id: elementId) { $0.isLocked = newValue } }
            )) {
                Label(el.isLocked ? "已锁定位置" : "锁定位置", systemImage: el.isLocked ? "lock.fill" : "lock.open")
            }

            if el.allowsTicketSection {
                labeled("区域") {
                    Picker("", selection: Binding(
                        get: { elementValue(id: elementId, \.ticketSection, default: .header) },
                        set: { newValue in updateElement(id: elementId) { $0.ticketSection = newValue } }
                    )) {
                        ForEach(POSTicketSection.allCases) { section in
                            Text(section.displayName).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("条目增多时：头部保持原位，尾部随列表下移")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            labeled("位置与大小") {
                let locked = el.isLocked
                let paper = session.editingTemplate?.paperSize ?? CGSize(width: 302, height: 480)
                HStack(spacing: 8) {
                    numericField(
                        "X",
                        value: el.frame.x,
                        enabled: !locked,
                        range: 0...(paper.width - 8),
                        step: 1
                    ) { x in
                        updateElement(id: elementId) { $0.frame.x = x }
                    }
                    numericField(
                        "Y",
                        value: el.frame.y,
                        enabled: !locked,
                        range: 0...(paper.height + 400),
                        step: 1
                    ) { y in
                        updateElement(id: elementId) { $0.frame.y = y }
                    }
                }
                HStack(spacing: 8) {
                    numericField(
                        el.fieldKind == .name ? "宽（换行）" : "宽",
                        value: el.frame.width,
                        range: 36...max(36, paper.width),
                        step: 4
                    ) { w in
                        applyNameOrElementWidth(id: elementId, width: max(36, w), isName: el.fieldKind == .name)
                    }
                    numericField(
                        "高",
                        value: el.frame.height,
                        range: 22...800,
                        step: 1
                    ) { h in
                        updateElement(id: elementId) { $0.frame.height = max(22, h) }
                    }
                }
                if el.fieldKind == .name {
                    Text("加宽「项目」会压缩数量/金额列；总宽不超过纸面。拖右下角或改「宽」即可。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(locked ? "已锁定：不可拖动或改 X/Y" : "单位：点（与预览纸面一致）；箭头可微调")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if el.kind != .divider && el.kind != .logo {
                labeled("大小") {
                    fontSizeCombo(elementId: elementId, current: el.fontSize)
                }
                Toggle("粗体", isOn: Binding(
                    get: { elementValue(id: elementId, \.isBold, default: false) },
                    set: { newValue in updateElement(id: elementId) { $0.isBold = newValue } }
                ))
                labeled("对齐") {
                    Picker("", selection: Binding(
                        get: { elementValue(id: elementId, \.alignment, default: 0) },
                        set: { newValue in updateElement(id: elementId) { $0.alignment = newValue } }
                    )) {
                        Text("左对齐").tag(0)
                        Text("居中").tag(1)
                        Text("右对齐").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            if el.kind == .logo {
                labeled("缩放 %") {
                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: Binding(
                                get: { elementValue(id: elementId, \.logoScalePercent, default: 100) },
                                set: { setLogoScalePercent(id: elementId, percent: $0) }
                            ),
                            format: .number.precision(.fractionLength(0))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: Binding(
                                get: { elementValue(id: elementId, \.logoScalePercent, default: 100) },
                                set: { setLogoScalePercent(id: elementId, percent: $0) }
                            ),
                            in: SequenceLogoItem.minScalePercent...SequenceLogoItem.maxScalePercent,
                            step: 5
                        )
                        .labelsHidden()
                    }
                    Text("相对导入时基准尺寸缩放，中心点保持不动")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if el.kind == .divider {
                Toggle("虚线", isOn: Binding(
                    get: { elementValue(id: elementId, \.isDashed, default: false) },
                    set: { newValue in updateElement(id: elementId) { $0.isDashed = newValue } }
                ))
                Text("调整「宽」可改变横线打印长度")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if el.kind == .textBox {
                TextField("文字内容", text: Binding(
                    get: { elementValue(id: elementId, \.content, default: "") },
                    set: { newValue in updateElement(id: elementId) { $0.content = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
            }

            if el.kind == .date {
                Picker("日期格式", selection: Binding(
                    get: { elementValue(id: elementId, \.dateFormat, default: .ymdDash) },
                    set: { newValue in updateElement(id: elementId) { $0.dateFormat = newValue } }
                )) {
                    ForEach(POSDateFormatStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            if el.kind == .autoNumber {
                TextField("起始编号", text: Binding(
                    get: { elementValue(id: elementId, \.autoNumberStart, default: "01") },
                    set: { newValue in updateElement(id: elementId) { $0.autoNumberStart = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
                Toggle("转换为条码", isOn: Binding(
                    get: { elementValue(id: elementId, \.autoNumberAsBarcode, default: false) },
                    set: { newValue in updateElement(id: elementId) { $0.autoNumberAsBarcode = newValue } }
                ))
            }

            Button("删除元素", role: .destructive) {
                if el.kind == .fieldPlaceholder, el.fieldKind == .name {
                    excelStatus = "项目名称占位符不可删除"
                    return
                }
                let idToDelete = el.id
                let kind = el.kind
                // Clear selection first so stale bindings don't fire after remove.
                selectedElementId = nil
                guard var t = session.editingTemplate else { return }
                t.elements.removeAll { $0.id == idToDelete }
                session.editingTemplate = t
                if kind == .logo {
                    session.logoImages.removeValue(forKey: idToDelete)
                }
            }
        }
    }

    private func numericField(
        _ label: String,
        value: CGFloat,
        enabled: Bool = true,
        range: ClosedRange<CGFloat> = 0...2000,
        step: CGFloat = 1,
        onCommit: @escaping (CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(
                    label,
                    text: Binding(
                        get: { String(Int(value.rounded())) },
                        set: { text in
                            guard enabled else { return }
                            if let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
                                let clamped = min(range.upperBound, max(range.lowerBound, CGFloat(parsed)))
                                onCommit(clamped)
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
                .frame(maxWidth: .infinity)

                Stepper(
                    "",
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            guard enabled else { return }
                            let clamped = min(range.upperBound, max(range.lowerBound, newValue.rounded()))
                            onCommit(clamped)
                        }
                    ),
                    in: range,
                    step: step
                )
                .labelsHidden()
                .disabled(!enabled)
                .fixedSize()
            }
        }
    }

    private func fontSizeCombo(elementId: UUID, current: CGFloat) -> some View {
        let presets = Self.fontSizeChoices
        return HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: {
                    if let match = presets.first(where: { abs($0 - current) < 0.5 }) {
                        return match
                    }
                    return current
                },
                set: { newValue in
                    updateElement(id: elementId) { $0.fontSize = min(72, max(8, newValue)) }
                }
            )) {
                ForEach(presets, id: \.self) { size in
                    Text("\(Int(size))").tag(size)
                }
                if presets.first(where: { abs($0 - current) < 0.5 }) == nil {
                    Text("\(Int(current.rounded()))").tag(current)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            TextField(
                "大小",
                text: Binding(
                    get: { String(Int(current.rounded())) },
                    set: { text in
                        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
                            updateElement(id: elementId) {
                                $0.fontSize = CGFloat(min(72, max(8, parsed)))
                            }
                        }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
        }
    }

    private var selectedCanvasElement: POSReceiptElement? {
        guard let id = selectedElementId else { return nil }
        return session.editingTemplate?.elements.first(where: { $0.id == id })
    }

    private var showsSurchargeDefaultControl: Bool {
        selectedCanvasElement?.fieldKind == .surcharge
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renameTarget = nil
            return
        }
        var updated = target
        updated.name = name
        updated.touch()
        session.store.saveMeta(updated)
        session.reloadTemplates()
        if session.editingTemplate?.id == target.id {
            session.editingTemplate?.name = name
            session.syncEditingIntoTemplates()
        }
        renameTarget = nil
        excelStatus = "已重命名为「\(name)」"
    }

    private func setLogoScalePercent(id: UUID, percent: Double) {
        guard var t = session.editingTemplate,
              let idx = t.elements.firstIndex(where: { $0.id == id }),
              t.elements[idx].kind == .logo else { return }
        let p = min(SequenceLogoItem.maxScalePercent, max(SequenceLogoItem.minScalePercent, percent.rounded()))
        var el = t.elements[idx]
        let baseW = max(1, el.logoBaseWidth)
        let baseH = max(1, el.logoBaseHeight)
        let cx = el.frame.x + el.frame.width / 2
        let cy = el.frame.y + el.frame.height / 2
        let w = max(36, baseW * p / 100)
        let h = max(24, baseH * p / 100)
        el.logoScalePercent = p
        el.frame = SequencePlaceholderFrame(
            x: cx - w / 2,
            y: cy - h / 2,
            width: w,
            height: h
        ).clamped(to: t.paperSize, minSize: CGSize(width: 36, height: 24))
        t.elements[idx] = el
        session.editingTemplate = t
        scheduleLiveCanvasRefresh(immediate: true)
    }

    private func syncLogoScaleFromFrame(id: UUID) {
        guard var t = session.editingTemplate,
              let idx = t.elements.firstIndex(where: { $0.id == id }),
              t.elements[idx].kind == .logo else { return }
        var el = t.elements[idx]
        let baseW = max(1, el.logoBaseWidth)
        let p = min(
            SequenceLogoItem.maxScalePercent,
            max(SequenceLogoItem.minScalePercent, (Double(el.frame.width / baseW) * 100).rounded())
        )
        el.logoScalePercent = p
        let w = max(36, baseW * p / 100)
        let h = max(24, el.logoBaseHeight * p / 100)
        el.frame.width = w
        el.frame.height = h
        el.frame = el.frame.clamped(to: t.paperSize, minSize: CGSize(width: 36, height: 24))
        t.elements[idx] = el
        session.editingTemplate = t
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Actions

    /// Fixed designer sample — one row, style-only placeholders (not main-page cart data).
    private func sampleLineItems(for template: POSReceiptTemplate) -> [POSLineItem] {
        [
            POSLineItem(
                code: template.enableCode ? "1" : "",
                name: "示例",
                quantity: template.enableQuantity ? "1" : "",
                amount: template.enableAmount ? "1.00" : ""
            )
        ]
    }

    private func previewTemplate() {
        guard let t = session.editingTemplate else { return }
        let autoNumber = t.elements.first(where: { $0.kind == .autoNumber })?.autoNumberStart
        let result = POSReceiptPrintComposer.compose(
            template: t,
            items: sampleLineItems(for: t),
            surcharge: t.defaultSurcharge,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig,
            ticketAutoNumber: autoNumber
        )
        previewPayload = PreviewPayload(image: result.previewImage)
        excelStatus = "已生成打印预览（示例数据）"
    }

    private func syncToggles() {
        guard var t = session.editingTemplate else { return }
        session.syncFieldPlaceholders(&t)
        session.editingTemplate = t
    }

    private func addField(_ kind: POSFieldKind) {
        guard var t = session.editingTemplate else { return }
        if t.hasElement(field: kind) {
            excelStatus = "已存在「\(kind.displayName)」"
            return
        }
        let y: CGFloat = kind.isSummaryField ? 200 : 80
        let frame = SequencePlaceholderFrame(x: 12, y: y, width: kind.isSummaryField ? 120 : 160, height: 28)
        let nameY = t.elements.first(where: { $0.fieldKind == .name })?.frame.y ?? 80
        let el = POSReceiptElement(
            kind: .fieldPlaceholder,
            frame: frame,
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1,
            fieldKind: kind,
            ticketSection: POSReceiptElement.defaultTicketSection(
                kind: .fieldPlaceholder,
                fieldKind: kind,
                frame: frame,
                nameRowY: nameY
            )
        )
        t.elements.append(el)
        session.editingTemplate = t
        selectedElementId = el.id
    }

    private func addTextBox() {
        guard var t = session.editingTemplate else { return }
        let el = POSReceiptElement(
            kind: .textBox,
            frame: SequencePlaceholderFrame(x: 12, y: 20, width: 160, height: 28),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1,
            content: "文本"
        )
        t.elements.append(el)
        session.editingTemplate = t
        selectedElementId = el.id
    }

    private func addDivider(dashed: Bool) {
        guard var t = session.editingTemplate else { return }
        let paperW = t.paperSize.width
        let el = POSReceiptElement(
            kind: .divider,
            frame: SequencePlaceholderFrame(x: 12, y: 120, width: max(80, paperW - 24), height: 22),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1,
            isDashed: dashed
        )
        t.elements.append(el)
        session.editingTemplate = t
        selectedElementId = el.id
    }

    private func addDate() {
        guard var t = session.editingTemplate else { return }
        let el = POSReceiptElement(
            kind: .date,
            frame: SequencePlaceholderFrame(x: 12, y: 20, width: 140, height: 28),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1
        )
        t.elements.append(el)
        session.editingTemplate = t
        selectedElementId = el.id
    }

    private func addTime() {
        guard var t = session.editingTemplate else { return }
        let el = POSReceiptElement(
            kind: .time,
            frame: SequencePlaceholderFrame(x: 160, y: 20, width: 100, height: 28),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1
        )
        t.elements.append(el)
        session.editingTemplate = t
        selectedElementId = el.id
    }

    private func addAutoNumber() {
        guard var t = session.editingTemplate else { return }
        if t.elements.contains(where: { $0.kind == .autoNumber }) {
            excelStatus = "已存在自动编号"
            return
        }
        let el = POSReceiptElement(
            kind: .autoNumber,
            frame: SequencePlaceholderFrame(x: 200, y: 20, width: 96, height: 36),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1,
            autoNumberStart: "01"
        )
        t.elements.append(el)
        session.editingTemplate = t
        selectedElementId = el.id
    }

    private func pickBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        session.backgroundImage = ImagePreprocessor.toBinaryBlackWhite(img)
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        guard var t = session.editingTemplate else { return }
        let mono = ImagePreprocessor.toBinaryBlackWhite(img)
        let id = UUID()
        let size = mono.size
        let paper = t.paperSize
        let item = SequenceLogoItem.makeDefault(
            id: id,
            imageFilename: POSReceiptTemplateStore.logoFilename(for: id),
            imageSize: size,
            paperWidth: paper.width,
            paperSize: paper,
            staggerIndex: session.logoImages.count,
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1
        )
        var el = POSReceiptElement(
            kind: .logo,
            frame: item.frame,
            zIndex: item.zIndex,
            imageFilename: item.imageFilename,
            logoScalePercent: item.scalePercent,
            logoBaseWidth: item.baseWidth,
            logoBaseHeight: item.baseHeight
        )
        el.id = id
        t.elements.append(el)
        session.editingTemplate = t
        var logos = session.logoImages
        logos[id] = mono
        session.logoImages = logos
        selectedElementId = id
    }

    private func pickExcel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "csv") ?? .commaSeparatedText,
            UTType(filenameExtension: "tsv") ?? .tabSeparatedText,
            .commaSeparatedText
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try POSExcelLookupService.makeBookmark(from: url)
            let table = try SpreadsheetImportService.load(from: url)
            session.editingTemplate?.excelBookmarkData = bookmark
            session.editingTemplate?.excelDisplayName = url.lastPathComponent
            session.editingTemplate?.excelCachedHeaders = table.headers
            session.excelRowCount = table.rows.count
            excelStatus = "已绑定 \(url.lastPathComponent)，\(table.rows.count) 行"
            if let t = session.editingTemplate {
                session.store.saveMeta(t)
                session.reloadTemplates()
                if let updated = session.templates.first(where: { $0.id == t.id }) {
                    session.editingTemplate = updated
                    session.reloadExcelCatalog(for: updated)
                }
            }
        } catch {
            excelStatus = error.localizedDescription
        }
    }

    private func refreshExcel() {
        guard let t = session.editingTemplate else { return }
        do {
            let table = try POSExcelLookupService.loadTable(for: t)
            session.editingTemplate?.excelCachedHeaders = table.headers
            session.excelRowCount = table.rows.count
            excelStatus = "已更新，\(table.rows.count) 行"
            if let updated = session.editingTemplate {
                session.store.saveMeta(updated)
                session.reloadTemplates()
                session.reloadExcelCatalog(for: updated)
            }
        } catch {
            excelStatus = error.localizedDescription
        }
    }

    private func clearExcel() {
        session.editingTemplate?.excelBookmarkData = nil
        session.editingTemplate?.excelDisplayName = nil
        session.editingTemplate?.excelCachedHeaders = []
        session.editingTemplate?.excelColumnMap = POSExcelColumnMap()
        session.excelRowCount = nil
        excelStatus = "已清除 Excel"
        if let t = session.editingTemplate {
            session.store.saveMeta(t)
            session.reloadTemplates()
            session.reloadExcelCatalog(for: t)
        }
    }
}

private struct POSGridBackground: View {
    var size: CGSize
    var step: CGFloat

    var body: some View {
        Canvas { context, _ in
            let minor = Color.secondary.opacity(0.28)
            let major = Color.secondary.opacity(0.45)
            let majorEvery = 4
            var i = 0
            var x: CGFloat = 0
            while x <= size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let isMajor = i % majorEvery == 0
                context.stroke(path, with: .color(isMajor ? major : minor), lineWidth: isMajor ? 1 : 0.6)
                x += step
                i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                let isMajor = i % majorEvery == 0
                context.stroke(path, with: .color(isMajor ? major : minor), lineWidth: isMajor ? 1 : 0.6)
                y += step
                i += 1
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
