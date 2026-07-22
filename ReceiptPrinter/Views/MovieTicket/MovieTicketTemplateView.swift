import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MovieTicketTemplateView: View {
    @EnvironmentObject private var session: MovieTicketSession
    @EnvironmentObject private var appState: AppState

    @State private var selectedElementIds: Set<UUID> = []
    /// Last clicked / focused element (inspector target when a single item is selected).
    @State private var lastSelectedId: UUID?
    /// Anchor for ⇧ range selection in the element list / canvas.
    @State private var selectionAnchorId: UUID?
    @State private var groupDragOrigins: [UUID: SequencePlaceholderFrame] = [:]
    /// Nudge step (points) for the multi-select arrow toolbar.
    @State private var nudgeStep: CGFloat = 1
    @State private var canvasGestureActive = false
    @State private var status: String = ""
    @State private var editingRule: MovieTicketPDFRule?
    @State private var pdfPageSize: CGSize = CGSize(width: 612, height: 792)
    @State private var pdfPageImage: NSImage?
    @State private var showPDFRegionEditor = false
    @State private var showPrintPreview = false
    @State private var printPreviewImage: NSImage?
    @State private var testResults: [String] = []
    /// Bumped after PDF editor closes so the designer canvas remounts (sheet teardown breaks gestures).
    @State private var canvasEpoch: Int = 0
    /// Designer view zoom (1.0 = actual paper points). Default 2× for easier editing on 80mm tickets.
    @State private var displayScale: CGFloat = 2
    /// Snapshots of `editingTemplate` for 撤销 (one entry per gesture / inspector edit).
    @State private var undoStack: [MovieTicketTemplate] = []
    @State private var undoPushedForGesture = false
    @State private var confirmFactoryReset = false
    @State private var confirmDeleteTemplate = false
    @State private var showUnsavedDialog = false
    @State private var pendingLeaveAction: (() -> Void)?

    private static let zoomMin: CGFloat = 0.5
    private static let zoomMax: CGFloat = 4
    private static let zoomStep: CGFloat = 0.25
    private static let maxUndo = 50

    private var templateBinding: Binding<MovieTicketTemplate?> {
        Binding(
            get: { session.editingTemplate },
            set: { session.editingTemplate = $0 }
        )
    }

    var body: some View {
        Group {
            if showPDFRegionEditor {
                // Full-pane swap — NOT .sheet. SwiftUI sheets on macOS leave the designer
                // canvas unable to receive drag gestures until the view hierarchy remounts
                // (e.g. switching main/template tabs).
                pdfRegionEditorSheetContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    designerColumn
                        .frame(minWidth: 420)
                        .id("designer-\(canvasEpoch)")
                    inspectorColumn
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                }
                .padding(8)
            }
        }
        .onAppear {
            if session.editingTemplate == nil, let t = session.activeTemplate {
                session.beginEditing(t)
                undoStack = []
            }
            syncPlaceholderSizesToPrint(recordUndo: false)
            session.markEditingClean()
        }
        .onChange(of: showPDFRegionEditor) { _, isOpen in
            canvasGestureActive = false
            if !isOpen {
                canvasEpoch += 1
                restoreKeyWindow()
            }
        }
        .onChange(of: session.editingTemplate?.id) { _, _ in
            undoStack = []
            undoPushedForGesture = false
            clearSelection()
        }
        .sheet(isPresented: $showPrintPreview) {
            printPreviewSheet
        }
        .confirmationDialog(
            L10n.ui("恢复此模板的出厂布局？当前画布将被替换（可用撤销找回）。"),
            isPresented: $confirmFactoryReset,
            titleVisibility: .visible
        ) {
            Button(L10n.ui("恢复默认布局"), role: .destructive) { resetToFactoryLayout() }
            Button(L10n.ui("取消"), role: .cancel) {}
        }
        .confirmationDialog(
            deleteTemplateMessage,
            isPresented: $confirmDeleteTemplate,
            titleVisibility: .visible
        ) {
            Button(L10n.ui("删除模板"), role: .destructive) { performDeleteTemplate() }
            Button(L10n.ui("取消"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.ui("模板有未保存的更改，是否保存？"),
            isPresented: $showUnsavedDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.ui("保存")) {
                session.saveEditingTemplate()
                status = session.message
                let action = pendingLeaveAction
                pendingLeaveAction = nil
                action?()
            }
            Button(L10n.ui("不保存"), role: .destructive) {
                session.discardEditingChanges()
                undoStack = []
                clearSelection()
                let action = pendingLeaveAction
                pendingLeaveAction = nil
                action?()
            }
            Button(L10n.ui("取消"), role: .cancel) {
                pendingLeaveAction = nil
            }
        }
    }

    // MARK: - Designer

    private var designerColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            templateChrome
            toolBar
            Text(session.editingTemplate?.usesIMAXSydneyLayout == true
                 ? L10n.ui("IMAX：Y 控制行序；票型+票价同行，左右位置跟画布 X。列表 ⌘/⇧ 多选。")
                 : L10n.ui("列表支持 ⌘加减选 / ⇧连选；多选后可用方向键微调；拖拽可批量移动。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if selectedElementIds.count > 1 {
                selectionNudgeBar
            }
            ScrollView([.vertical, .horizontal]) {
                canvas
                    .scaleEffect(displayScale, anchor: .topLeading)
                    .frame(
                        width: (session.editingTemplate?.paperSize.width ?? 302) * displayScale,
                        height: (session.editingTemplate?.canvasHeight ?? 560) * displayScale,
                        alignment: .topLeading
                    )
                    .padding(16)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var templateChrome: some View {
        HStack {
            if let t = session.editingTemplate {
                TextField(L10n.ui("模板名称"), text: Binding(
                    get: { t.name },
                    set: { newValue in
                        var copy = t
                        copy.name = newValue
                        session.editingTemplate = copy
                        session.markEditingDirty()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            }
            Button(L10n.ui("新建模板")) {
                requestLeaveEditing {
                    session.createTemplate()
                    undoStack = []
                    clearSelection()
                    status = L10n.ui("已新建空白模板（请从工具栏添加字段）")
                }
            }
            Button(L10n.ui("复制模板")) {
                if let copied = session.duplicateTemplate() {
                    undoStack = []
                    clearSelection()
                    status = "已复制为「\(copied.name)」"
                }
            }
            .disabled(session.editingTemplate == nil)
            .help(L10n.ui("复制当前模板，名称形如 原名(1)"))
            Button(L10n.ui("保存")) {
                session.saveEditingTemplate()
                status = session.message.isEmpty ? L10n.ui("模板已保存") : session.message
            }
            Button(L10n.ui("撤销")) { performUndo() }
                .disabled(undoStack.isEmpty)
                .help(L10n.ui("撤回上一步画布或属性修改"))
            Button(L10n.ui("默认布局")) { confirmFactoryReset = true }
                .disabled(session.editingTemplate == nil)
                .help(L10n.ui("恢复为应用生成的原始布局"))
            Button(L10n.ui("删除模板"), role: .destructive) {
                confirmDeleteTemplate = true
            }
            .disabled(session.editingTemplate == nil)
            .help(L10n.ui("删除当前模板（需确认）"))
            Spacer()
            Picker(
                "选用 (\(session.templates.count))",
                selection: Binding(
                    get: { session.settings.activeTemplateId },
                    set: { newId in
                        guard let id = newId else { return }
                        guard id != session.editingTemplate?.id else { return }
                        requestLeaveEditing {
                            session.selectTemplate(id)
                            if let t = session.templates.first(where: { $0.id == id }) {
                                session.beginEditing(t)
                                undoStack = []
                                clearSelection()
                            }
                        }
                    }
                )
            ) {
                ForEach(session.templates) { t in
                    Text(t.name).tag(Optional(t.id))
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 160, maxWidth: 240)
            .help(session.templates.map(\.name).joined(separator: "、"))
        }
    }

    private var toolBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(L10n.ui("文字框")) { addTextBox() }
                Button(L10n.ui("当前日期")) { addCurrentDate() }
                Button(L10n.ui("当前时间")) { addCurrentTime() }
                ForEach([MovieTicketFieldKind.movieTitle, .showDate, .startTime, .endTime, .timeRange], id: \.self) { k in
                    Button(k.displayName) { addField(k) }
                }
            }
            HStack(spacing: 6) {
                ForEach([MovieTicketFieldKind.seatArea, .ticketPrice, .ticketType, .serialNumber, .hall, .qrCode, .barcode], id: \.self) { k in
                    Button(k.displayName) { addField(k) }
                }
            }
            HStack {
                Toggle(L10n.ui("参考网格"), isOn: Binding(
                    get: { session.editingTemplate?.gridEnabled ?? true },
                    set: { v in
                        session.editingTemplate?.gridEnabled = v
                        session.markEditingDirty()
                    }
                ))
                Button(L10n.ui("背景图")) { pickBackground() }
                Button(L10n.ui("清除背景")) { session.setBackground(nil) }
                Button("Logo") { pickLogo() }
                Button(L10n.ui("对齐打印尺寸")) {
                    syncPlaceholderSizesToPrint(recordUndo: true)
                    status = L10n.ui("已按打印字高对齐占位框")
                }
                Button(L10n.ui("打印预览")) { openPrintPreview() }
                Spacer(minLength: 8)
                zoomControls
            }
        }
        .controlSize(.small)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Text(L10n.ui("视图")).font(.caption).foregroundStyle(.secondary)
            Button {
                setZoom(displayScale - Self.zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(displayScale <= Self.zoomMin + 0.001)
            .help(L10n.ui("缩小"))

            Text("\(Int((displayScale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40)

            Button {
                setZoom(displayScale + Self.zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(displayScale >= Self.zoomMax - 0.001)
            .help(L10n.ui("放大"))

            Button("50%") { setZoom(0.5) }
            Button("100%") { setZoom(1) }
            Button("200%") { setZoom(2) }
            Button(L10n.ui("适应")) { fitZoomToVisible() }
                .help(L10n.ui("按当前可视区域大致适配纸宽"))
        }
    }

    private func setZoom(_ value: CGFloat) {
        displayScale = min(Self.zoomMax, max(Self.zoomMin, (value * 100).rounded() / 100))
    }

    /// Fit paper width into a typical designer column (~400pt usable).
    private func fitZoomToVisible() {
        let paperW = session.editingTemplate?.paperSize.width ?? 302
        let targetVisible: CGFloat = 400
        setZoom(targetVisible / max(paperW, 1))
    }

    private var canvas: some View {
        let paperW = session.editingTemplate?.paperSize.width ?? 302
        let paperH = session.editingTemplate?.canvasHeight ?? 560
        let paper = CGSize(width: paperW, height: paperH)
        let gridOn = session.editingTemplate?.gridEnabled ?? true
        let gridSize = session.editingTemplate?.gridSize ?? 20
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: paper.width, height: paper.height)
            Rectangle()
                .fill(Color.white)
                .frame(width: paper.width, height: paper.height)
            if gridOn {
                MovieTicketGridBackground(size: paper, step: gridSize)
            }
            ForEach(session.editingTemplate?.elements.sorted(by: { $0.zIndex < $1.zIndex }) ?? []) { el in
                elementOverlay(el, paper: paper)
                    .id(el.id)
            }
        }
        .frame(width: paper.width, height: paper.height)
        .clipped()
        .border(Color.secondary.opacity(0.4))
        .onTapGesture { clearSelection() }
    }

    private var printPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.ui("打印预览")).font(.headline)
                Spacer()
                Button(L10n.ui("刷新")) { regeneratePrintPreview() }
                Button(L10n.ui("关闭")) { showPrintPreview = false }
                    .keyboardShortcut(.cancelAction)
            }
            Text(L10n.ui("按 ESC/POS 内置 Font A + 放大倍率模拟的真实打印序列（与发往打印机的指令一致）。左侧画布仅为占位符。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                if let img = printPreviewImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 420)
                        .border(Color.secondary.opacity(0.35))
                        .padding(8)
                } else {
                    ProgressView(L10n.ui("生成预览…"))
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 560)
    }

    private func elementOverlay(_ el: MovieTicketElement, paper: CGSize) -> some View {
        let binding = Binding<SequencePlaceholderFrame>(
            get: {
                session.editingTemplate?.elements.first(where: { $0.id == el.id })?.frame
                    ?? el.frame
            },
            set: { newFrame in
                updateElement(id: el.id, recordUndo: false) { $0.frame = newFrame }
            }
        )
        let selected = Binding<Bool>(
            get: { selectedElementIds.contains(el.id) },
            set: { if $0 { selectElement(el.id, additive: false) } }
        )
        let gridOn = session.editingTemplate?.gridEnabled ?? true
        let gridSize = session.editingTemplate?.gridSize ?? 20
        let config = appState.settings.printerConfig
        let minH = MovieTicketPrintMetrics.lineHeightPoints(
            heightScale: 1, paperWidth: paper.width, dotsPerLine: config.dotsPerLine
        )

        if el.kind == .logo {
            if let img = session.logoImages[el.id] {
                return AnyView(
                    LogoBoxOverlay(
                        title: "Logo",
                        image: img,
                        frame: binding,
                        isSelected: selected,
                        paperSize: paper,
                        onFrameChanged: {
                            syncLogoScaleFromFrame(id: el.id)
                        },
                        onInteractionChanged: { active in
                            noteCanvasInteraction(active)
                        },
                        onDelete: {
                            pushUndoSnapshot()
                            removeFromSelection(el.id)
                            guard var t = session.editingTemplate else { return }
                            t.elements.removeAll { $0.id == el.id }
                            session.editingTemplate = t
                            session.logoImages.removeValue(forKey: el.id)
                            session.markEditingDirty()
                        },
                        chromeOnly: false,
                        isLocked: el.isLocked,
                        onSelectRequest: { _ in
                            selectElementWithModifiers(el.id)
                        },
                        onTranslateChanged: { translation in
                            applyGroupTranslate(
                                anchorId: el.id,
                                translation: translation,
                                paper: paper,
                                gridEnabled: gridOn,
                                gridSize: gridSize
                            )
                        },
                        onTranslateEnded: {
                            endGroupTranslate()
                            syncLogoScaleFromFrame(id: el.id)
                        }
                    )
                )
            }
            return AnyView(
                MovieTicketElementBoxOverlay(
                    frame: binding,
                    isSelected: selected,
                    title: "Logo",
                    previewText: "[Logo]",
                    fontSize: 12,
                    textAlignment: 1,
                    paperSize: paper,
                    gridEnabled: gridOn,
                    gridSize: gridSize,
                    accent: .orange,
                    chromeOnly: false,
                    placeholderMode: true,
                    isLocked: el.isLocked,
                    minSize: CGSize(width: 36, height: minH),
                    onInteractionChanged: { active in
                        noteCanvasInteraction(active)
                    },
                    onSelectRequest: { _ in
                        selectElementWithModifiers(el.id)
                    },
                    onTranslateChanged: { translation in
                        applyGroupTranslate(
                            anchorId: el.id,
                            translation: translation,
                            paper: paper,
                            gridEnabled: gridOn,
                            gridSize: gridSize
                        )
                    },
                    onTranslateEnded: { endGroupTranslate() }
                )
            )
        }

        return AnyView(
            MovieTicketElementBoxOverlay(
                frame: binding,
                isSelected: selected,
                title: elementTitle(el),
                previewText: elementPlaceholderLabel(el),
                fontSize: el.fontSize,
                textAlignment: el.alignment,
                paperSize: paper,
                gridEnabled: gridOn,
                gridSize: gridSize,
                accent: accent(for: el),
                chromeOnly: false,
                placeholderMode: true,
                isLocked: el.isLocked,
                minSize: CGSize(width: 36, height: minH),
                onInteractionChanged: { active in
                    noteCanvasInteraction(active)
                },
                onSelectRequest: { _ in
                    selectElementWithModifiers(el.id)
                },
                onTranslateChanged: { translation in
                    applyGroupTranslate(
                        anchorId: el.id,
                        translation: translation,
                        paper: paper,
                        gridEnabled: gridOn,
                        gridSize: gridSize
                    )
                },
                onTranslateEnded: { endGroupTranslate() }
            )
        )
    }

    // MARK: - Inspector

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                templateProps
                Divider()
                if selectedElementIds.count > 1 {
                    multiSelectInspector
                } else if let id = lastSelectedId ?? selectedElementIds.first,
                          session.editingTemplate?.elements.contains(where: { $0.id == id }) == true {
                    elementInspector(elementId: id)
                } else {
                    Text(L10n.ui("从画布或下方列表选中元素以编辑属性；⌘点击可多选"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                elementListSection
                Divider()
                pdfRulesSection
            }
            .padding()
        }
    }

    private var templateProps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.ui("模板属性")).font(.headline)
            if session.editingTemplate != nil {
                labeled(L10n.ui("画布高度")) {
                    Slider(
                        value: Binding(
                            get: { Double(session.editingTemplate?.canvasHeight ?? 560) },
                            set: {
                                session.editingTemplate?.canvasHeight = CGFloat($0)
                                session.markEditingDirty()
                            }
                        ),
                        in: 300...1200,
                        step: 20
                    )
                }
                labeled(L10n.ui("无特定座位文案")) {
                    TextField("General Admission", text: Binding(
                        get: { session.editingTemplate?.unallocatedSeatLabel ?? "" },
                        set: {
                            session.editingTemplate?.unallocatedSeatLabel = $0
                            session.markEditingDirty()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                labeled(L10n.ui("切纸前走纸")) {
                    HStack(spacing: 8) {
                        Stepper(
                            "\(session.editingTemplate?.resolvedFeedLinesBeforeCut(config: appState.settings.printerConfig) ?? 0) \(L10n.ui("行"))",
                            value: Binding(
                                get: {
                                    session.editingTemplate?.resolvedFeedLinesBeforeCut(
                                        config: appState.settings.printerConfig
                                    ) ?? 0
                                },
                                set: { newValue in
                                    session.editingTemplate?.feedLinesBeforeCut =
                                        max(0, min(40, newValue))
                                    session.markEditingDirty()
                                }
                            ),
                            in: 0...40
                        )
                    }
                }
                Text(L10n.ui("打印结束后再走纸再切刀；数值越小票尾越短，过小可能裁到内容。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var multiSelectInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(L10n.ui("已选中")) \(selectedElementIds.count)\(L10n.ui("个元素"))").font(.headline)
            Text(L10n.ui("列表：⌘加减选 · ⇧连选；画布拖拽可批量移动。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            selectionNudgeControls
            Button(L10n.ui("删除选中"), role: .destructive) {
                deleteSelectedElements()
            }
        }
    }

    /// Compact bar above the canvas when multi-select is active.
    private var selectionNudgeBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(selectedElementIds.count)")
                .font(.caption.weight(.semibold))
            selectionNudgeControls
            Spacer(minLength: 0)
            Button(L10n.ui("清除选中")) { clearSelection() }
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var selectionNudgeControls: some View {
        HStack(spacing: 6) {
            Text(L10n.ui("微调")).font(.caption2).foregroundStyle(.secondary)
            Picker("", selection: $nudgeStep) {
                Text("1pt").tag(CGFloat(1))
                Text("5pt").tag(CGFloat(5))
                Text("10pt").tag(CGFloat(10))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
            .controlSize(.small)

            nudgeArrowButton("arrow.up", dx: 0, dy: -nudgeStep)
            nudgeArrowButton("arrow.down", dx: 0, dy: nudgeStep)
            nudgeArrowButton("arrow.left", dx: -nudgeStep, dy: 0)
            nudgeArrowButton("arrow.right", dx: nudgeStep, dy: 0)
        }
        .controlSize(.small)
    }

    private func nudgeArrowButton(_ systemName: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button {
            nudgeSelection(dx: dx, dy: dy)
        } label: {
            Image(systemName: systemName)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .help(L10n.ui("移动选中元素"))
    }

    private var elementListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.ui("元素列表")).font(.headline)
            Text(L10n.ui("⌘点击加减选 · ⇧点击连选"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            let elements = (session.editingTemplate?.elements ?? []).sorted(by: { $0.zIndex < $1.zIndex })
            if elements.isEmpty {
                Text(L10n.ui("暂无元素")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(elements) { el in
                    Button {
                        selectElementWithModifiers(el.id)
                    } label: {
                        HStack {
                            Circle().fill(accent(for: el)).frame(width: 8, height: 8)
                            Text(elementTitle(el)).lineLimit(1)
                            Spacer()
                            if selectedElementIds.contains(el.id) {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func elementInspector(elementId: UUID) -> some View {
        guard let el = session.editingTemplate?.elements.first(where: { $0.id == elementId }) else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                Text("\(L10n.ui("元素："))\(elementTitle(el))").font(.headline)
                labeled(L10n.ui("显示名称")) {
                    TextField(L10n.ui("可选"), text: Binding(
                        get: { elementValue(id: elementId, \.displayName, default: "") },
                        set: { v in updateElement(id: elementId) { $0.displayName = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                Toggle(L10n.ui("锁定位置"), isOn: Binding(
                    get: { elementValue(id: elementId, \.isLocked, default: false) },
                    set: { v in updateElement(id: elementId) { $0.isLocked = v } }
                ))
                HStack(alignment: .top, spacing: 12) {
                    labeled("X") {
                        NumericStepperField(
                            value: Double(el.frame.x),
                            range: 0...2000,
                            step: 1
                        ) { v in
                            updateElement(id: elementId) { $0.frame.x = CGFloat(v) }
                        }
                    }
                    labeled("Y") {
                        NumericStepperField(
                            value: Double(el.frame.y),
                            range: 0...4000,
                            step: 1
                        ) { v in
                            updateElement(id: elementId) { $0.frame.y = CGFloat(v) }
                        }
                    }
                }
                Text(L10n.ui("元素可重叠放置；重叠时打印不再插入额外空行，便于压缩行距。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if el.kind == .logo {
                    labeled(L10n.ui("缩放 %")) {
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
                        Text(L10n.ui("相对导入时基准尺寸缩放，中心点保持不动；彩色图导入时自动转黑白"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        labeled(L10n.ui("宽")) {
                            NumericField(value: Double(el.frame.width), range: 36...2000) { v in
                                updateElement(id: elementId) { $0.frame.width = CGFloat(v) }
                            }
                            .frame(width: 64)
                        }
                        labeled(L10n.ui("高")) {
                            NumericField(value: Double(el.frame.height), range: 12...2000) { v in
                                updateElement(id: elementId) { $0.frame.height = CGFloat(v) }
                            }
                            .frame(width: 64)
                        }
                    }
                    Text(L10n.ui("宽高可独立调整（非等比例）"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let isBarcodeOrQR = el.fieldKind == .barcode || el.fieldKind == .qrCode
                    if isBarcodeOrQR {
                        Text(el.fieldKind == .barcode
                             ? L10n.ui("条码高度由上方「高」控制，会随保存保留；与文字 1×/2×/3× 无关。")
                             : L10n.ui("二维码尺寸由宽高控制。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        // Built-in printer font only supports ×1/×2/×3 — expose as choices, not free numbers.
                        let printScale = MovieTicketRitzESCPOS.printScale(
                            fontSize: el.fontSize, boxHeight: el.frame.height
                        )
                        let paperW = session.editingTemplate?.paperSize.width ?? 302
                        let dots = appState.settings.printerConfig.dotsPerLine
                        labeled(L10n.ui("打印宽")) {
                            Picker("", selection: Binding(
                                get: { printScale.width },
                                set: { level in
                                    let fs: CGFloat = level <= 1 ? 11 : (level == 2 ? 14 : 20)
                                    updateElement(id: elementId) { el in
                                        el.fontSize = fs
                                        let scale = MovieTicketRitzESCPOS.printScale(
                                            fontSize: fs, boxHeight: el.frame.height
                                        )
                                        el.frame.height = MovieTicketPrintMetrics.lineHeightPoints(
                                            heightScale: scale.height,
                                            paperWidth: paperW,
                                            dotsPerLine: dots
                                        )
                                    }
                                }
                            )) {
                                Text("1×").tag(1)
                                Text("2×").tag(2)
                                Text("3×").tag(3)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        labeled(L10n.ui("打印高")) {
                            Picker("", selection: Binding(
                                get: { printScale.height },
                                set: { level in
                                    let h = max(level, printScale.width)
                                    let boxH = MovieTicketPrintMetrics.lineHeightPoints(
                                        heightScale: h, paperWidth: paperW, dotsPerLine: dots
                                    )
                                    updateElement(id: elementId) { $0.frame.height = boxH }
                                }
                            )) {
                                Text("1×").tag(1)
                                Text("2×").tag(2)
                                Text("3×").tag(3)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        Text("\(L10n.ui("内置字体仅 1×/2×/3×；占位框高=打印字高；当前")) \(printScale.width)×\(printScale.height)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !isBarcodeOrQR {
                        Toggle(L10n.ui("粗体"), isOn: Binding(
                            get: { elementValue(id: elementId, \.isBold, default: false) },
                            set: { v in updateElement(id: elementId) { $0.isBold = v } }
                        ))
                    }
                    labeled(L10n.ui("对齐")) {
                        Picker("", selection: Binding(
                            get: { elementValue(id: elementId, \.alignment, default: 0) },
                            set: { v in updateElement(id: elementId) { $0.alignment = v } }
                        )) {
                            Text(L10n.ui("左对齐")).tag(0)
                            Text(L10n.ui("居中")).tag(1)
                            Text(L10n.ui("右对齐")).tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if el.kind == .textBox || el.kind == .fieldPlaceholder || el.kind == .currentDate || el.kind == .currentTime {
                        Toggle(L10n.ui("反色 Invert"), isOn: Binding(
                            get: { elementValue(id: elementId, \.isInverted, default: false) },
                            set: { v in updateElement(id: elementId) { $0.isInverted = v } }
                        ))
                    }
                    if el.fieldKind == .movieTitle {
                        Toggle(L10n.ui("片名限制单行（超出隐藏）"), isOn: Binding(
                            get: {
                                session.editingTemplate?.elements
                                    .first(where: { $0.id == elementId })?.singleLineClip != false
                            },
                            set: { v in updateElement(id: elementId) { $0.singleLineClip = v } }
                        ))
                        Text(L10n.ui("开启后，片名只显示一行，超出元素框的部分不打印"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if el.fieldKind == .hall {
                        Picker(L10n.ui("影厅显示"), selection: Binding(
                            get: {
                                session.editingTemplate?.elements
                                    .first(where: { $0.id == elementId })?.hallDisplayMode
                                    ?? .cinemaNumber
                            },
                            set: { v in updateElement(id: elementId) { $0.hallDisplayMode = v } }
                        )) {
                            ForEach(MovieTicketHallDisplayMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        if (session.editingTemplate?.elements
                            .first(where: { $0.id == elementId })?.hallDisplayMode
                            ?? .cinemaNumber) == .customPrefix {
                            TextField(L10n.ui("数字前缀（如 Screen 或 C）"), text: Binding(
                                get: {
                                    session.editingTemplate?.elements
                                        .first(where: { $0.id == elementId })?.hallNumberPrefix ?? ""
                                },
                                set: { v in
                                    updateElement(id: elementId) {
                                        $0.hallNumberPrefix = v.isEmpty ? nil : v
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        Text(hallDisplayHelp(
                            session.editingTemplate?.elements
                                .first(where: { $0.id == elementId })?.hallDisplayMode
                                ?? .cinemaNumber
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if el.kind == .textBox {
                        TextField(L10n.ui("文字内容"), text: Binding(
                            get: { elementValue(id: elementId, \.content, default: "") },
                            set: { v in updateElement(id: elementId) { $0.content = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    if el.kind == .currentDate || el.fieldKind == .showDate {
                        Picker(L10n.ui("日期格式"), selection: Binding(
                            get: { elementValue(id: elementId, \.dateFormat, default: .eeeMMMd) },
                            set: { v in updateElement(id: elementId) { $0.dateFormat = v } }
                        )) {
                            ForEach(MovieTicketDateFormat.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    if el.kind == .currentTime || el.fieldKind == .startTime || el.fieldKind == .endTime {
                        Picker(L10n.ui("时间格式"), selection: Binding(
                            get: { elementValue(id: elementId, \.timeFormat, default: .hmma) },
                            set: { v in updateElement(id: elementId) { $0.timeFormat = v } }
                        )) {
                            ForEach(MovieTicketTimeFormat.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    if el.fieldKind == .timeRange {
                        Picker(L10n.ui("开始格式"), selection: Binding(
                            get: { elementValue(id: elementId, \.rangeStartFormat, default: .hmma) },
                            set: { v in updateElement(id: elementId) { $0.rangeStartFormat = v } }
                        )) {
                            ForEach(MovieTicketTimeFormat.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker(L10n.ui("结束格式"), selection: Binding(
                            get: { elementValue(id: elementId, \.rangeEndFormat, default: .hmma) },
                            set: { v in updateElement(id: elementId) { $0.rangeEndFormat = v } }
                        )) {
                            ForEach(MovieTicketTimeFormat.allCases) { Text($0.displayName).tag($0) }
                        }
                        TextField(L10n.ui("连接词"), text: Binding(
                            get: { elementValue(id: elementId, \.rangeConnector, default: " - ") },
                            set: { v in updateElement(id: elementId) { $0.rangeConnector = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                Button(L10n.ui("删除元素"), role: .destructive) {
                    pushUndoSnapshot()
                    removeFromSelection(elementId)
                    guard var t = session.editingTemplate else { return }
                    if el.kind == .logo {
                        session.logoImages.removeValue(forKey: elementId)
                    }
                    t.elements.removeAll { $0.id == elementId }
                    session.editingTemplate = t
                    session.markEditingDirty()
                }
            }
        )
    }

    // MARK: - PDF rules

    private var pdfRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.ui("PDF 识别规则")).font(.headline)
            Text(L10n.ui("每个模板只能链接一条规则。框选为相对坐标，可识别不同页面尺寸；跨尺寸请优先用「识别关键词」。"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button(L10n.ui("新建规则")) {
                var rule = MovieTicketPDFRule(name: L10n.ui("新规则"))
                if let tid = session.editingTemplate?.id {
                    rule.linkedTemplateId = tid
                }
                session.savePDFRule(rule)
                editingRule = session.pdfRules.first { $0.id == rule.id } ?? rule
                if let tid = session.editingTemplate?.id {
                    session.linkRule(rule.id, to: tid)
                }
                status = L10n.ui("已新建并链接规则")
            }

            ForEach(session.pdfRules) { rule in
                HStack(alignment: .center, spacing: 8) {
                    Button(rule.name) {
                        editingRule = rule
                        loadSamplePDF(for: rule)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if session.editingTemplate?.pdfRuleId == rule.id {
                        Text(L10n.ui("已链接"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                        Button(L10n.ui("取消链接")) {
                            if let tid = session.editingTemplate?.id {
                                session.unlinkRule(from: tid)
                                status = L10n.ui("已取消链接")
                            }
                        }
                        .controlSize(.small)
                    } else {
                        Button(L10n.ui("链接到当前模板")) {
                            if let tid = session.editingTemplate?.id {
                                session.linkRule(rule.id, to: tid)
                                status = "已链接规则「\(rule.name)」（原链接已替换）"
                            }
                        }
                        .controlSize(.small)
                    }
                    Button(L10n.ui("删"), role: .destructive) {
                        session.deletePDFRule(rule.id)
                        if editingRule?.id == rule.id {
                            editingRule = nil
                            pdfPageImage = nil
                        }
                    }
                    .controlSize(.small)
                }
            }

            if let rule = editingRule {
                Divider()
                Text("编辑：\(rule.name)").font(.subheadline.weight(.semibold))
                TextField(L10n.ui("规则名称"), text: Binding(
                    get: { editingRule?.name ?? "" },
                    set: { editingRule?.name = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                TextField(L10n.ui("检测关键字（逗号分隔，如 ritz）"), text: Binding(
                    get: { (editingRule?.detectorKeywords ?? []).joined(separator: ", ") },
                    set: { raw in
                        editingRule?.detectorKeywords = raw
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.ui("上传样板 PDF")) { pickSamplePDF() }
                    Button(L10n.ui("保存规则")) {
                        if let r = editingRule {
                            session.savePDFRule(r)
                            status = L10n.ui("规则已保存")
                        }
                    }
                }

                if pdfPageImage != nil {
                    Text("\(L10n.ui("已映射")) \(editingRule?.regions.count ?? 0) \(L10n.ui("个区域"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(editingRule?.regions ?? []) { region in
                        HStack {
                            Text(region.fieldKind.displayName)
                            Text(region.captureMode.displayName)
                                .foregroundStyle(.secondary)
                            if !region.extractSample.isEmpty {
                                Text("「\(region.extractSample)」")
                                    .foregroundStyle(.orange)
                            } else if region.extractKind != .entire {
                                Text(region.extractKind.displayName)
                                    .foregroundStyle(.orange)
                            }
                            if !region.valueMappings.isEmpty {
                                Text("映射×\(region.valueMappings.count)")
                                    .foregroundStyle(.purple)
                            }
                            Spacer()
                            Button(L10n.ui("改")) {
                                openPDFRegionEditor()
                            }
                            .controlSize(.small)
                            .help(L10n.ui("在 PDF 区域编辑器中修改此映射"))
                            Button(L10n.ui("删"), role: .destructive) {
                                editingRule?.regions.removeAll { $0.id == region.id }
                            }
                            .controlSize(.small)
                        }
                        .font(.caption)
                    }
            Button(L10n.ui("打开 PDF 区域编辑器…")) {
                openPDFRegionEditor()
            }
            .buttonStyle(.borderedProminent)
                    Button(L10n.ui("测试识别…")) { testRecognition() }
                    if !testResults.isEmpty {
                        ForEach(testResults, id: \.self) { line in
                            Text(line).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L10n.ui("请先上传样板 PDF，再打开区域编辑器框选。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func restoreKeyWindow() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let candidates = NSApp.windows.filter {
                $0.isVisible && $0.canBecomeKey && !($0 is NSPanel)
            }
            if let window = candidates.first {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(window.contentView)
            }
        }
    }

    @ViewBuilder
    private var pdfRegionEditorSheetContent: some View {
        if let image = pdfPageImage, editingRule != nil {
            MovieTicketPDFRegionEditorSheet(
                rule: Binding(
                    get: { editingRule! },
                    set: { editingRule = $0 }
                ),
                pageImage: image,
                pageSize: pdfPageSize,
                templateElements: session.editingTemplate?.elements ?? [],
                samplePDFURL: editingRule.flatMap { session.store.samplePDFURL(for: $0) },
                onSave: { updated in
                    var toSave = updated
                    toSave.recordSamplePageSize(pdfPageSize)
                    editingRule = toSave
                    session.savePDFRule(toSave)
                    status = "规则已保存（\(toSave.regions.count) 个区域）"
                },
                onDismiss: { closePDFRegionEditor() }
            )
        } else {
            VStack(spacing: 12) {
                Text(L10n.ui("无法打开 PDF 预览"))
                Button(L10n.ui("返回模板")) { closePDFRegionEditor() }
            }
            .padding()
        }
    }

    private func openPDFRegionEditor() {
        canvasGestureActive = false
        showPDFRegionEditor = true
    }

    private func closePDFRegionEditor() {
        showPDFRegionEditor = false
    }

    // MARK: - Helpers

    private var deleteTemplateMessage: String {
        let name = session.editingTemplate?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return L10n.ui("确定删除当前模板？此操作不可撤销。")
        }
        return "确定删除模板「\(name)」？此操作不可撤销。"
    }

    private func performDeleteTemplate() {
        guard let id = session.editingTemplate?.id else { return }
        let name = session.editingTemplate?.name ?? ""
        session.deleteTemplate(id)
        undoStack = []
        clearSelection()
        status = name.isEmpty ? L10n.ui("已删除模板") : "已删除模板「\(name)」"
    }

    private func hallDisplayHelp(_ mode: MovieTicketHallDisplayMode) -> String {
        switch mode {
        case .cinemaNumber:
            return L10n.ui("默认：从识别值提取数字，打印为 Cinema 1（如 Screen 2 → Cinema 2）")
        case .numberOnly:
            return L10n.ui("只打印数字部分（如 Screen 2 → 2）")
        case .customPrefix:
            return L10n.ui("数字前加自定义文字（如填 Screen 则打印 Screen 2）")
        case .asRecognized:
            return L10n.ui("直接使用主页/PDF 识别填入的原文（含规则映射与前后缀）")
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            content()
        }
    }

    private func elementTitle(_ el: MovieTicketElement) -> String {
        let custom = el.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        switch el.kind {
        case .textBox: return L10n.ui("文字")
        case .fieldPlaceholder: return el.fieldKind?.displayName ?? L10n.ui("字段")
        case .currentDate: return L10n.ui("当前日期")
        case .currentTime: return L10n.ui("当前时间")
        case .logo: return "Logo"
        }
    }

    /// Short label shown inside placeholder boxes (not a print-style preview).
    private func elementPlaceholderLabel(_ el: MovieTicketElement) -> String {
        "[\(elementTitle(el))]"
    }

    private func accent(for el: MovieTicketElement) -> Color {
        switch el.kind {
        case .fieldPlaceholder: return .blue
        case .textBox: return .purple
        case .currentDate, .currentTime: return .teal
        case .logo: return .orange
        }
    }

    private func elementValue<T>(id: UUID, _ keyPath: WritableKeyPath<MovieTicketElement, T>, default defaultValue: T) -> T {
        session.editingTemplate?.elements.first(where: { $0.id == id })?[keyPath: keyPath] ?? defaultValue
    }

    private func updateElement(
        id: UUID,
        recordUndo: Bool = true,
        _ body: (inout MovieTicketElement) -> Void
    ) {
        guard var t = session.editingTemplate,
              let idx = t.elements.firstIndex(where: { $0.id == id }) else { return }
        if recordUndo { pushUndoSnapshot() }
        body(&t.elements[idx])
        session.editingTemplate = t
        session.markEditingDirty()
    }

    private func orderedElementIds() -> [UUID] {
        (session.editingTemplate?.elements ?? [])
            .sorted(by: { $0.zIndex < $1.zIndex })
            .map(\.id)
    }

    /// Selection with macOS modifiers: ⌘ toggle, ⇧ range (from anchor), plain replace.
    private func selectElementWithModifiers(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        if shift {
            let ordered = orderedElementIds()
            let anchor = selectionAnchorId ?? lastSelectedId ?? id
            guard let a = ordered.firstIndex(of: anchor),
                  let b = ordered.firstIndex(of: id) else {
                selectElement(id, additive: command)
                return
            }
            let range = Set(ordered[min(a, b)...max(a, b)])
            if command {
                selectedElementIds.formUnion(range)
            } else {
                selectedElementIds = range
            }
            lastSelectedId = id
            return
        }

        if command {
            selectElement(id, additive: true)
            if selectionAnchorId == nil {
                selectionAnchorId = id
            }
            return
        }

        selectedElementIds = [id]
        lastSelectedId = id
        selectionAnchorId = id
    }

    private func selectElement(_ id: UUID, additive: Bool) {
        if additive {
            if selectedElementIds.contains(id) {
                selectedElementIds.remove(id)
                if lastSelectedId == id {
                    lastSelectedId = selectedElementIds.first
                }
            } else {
                selectedElementIds.insert(id)
                lastSelectedId = id
            }
        } else {
            selectedElementIds = [id]
            lastSelectedId = id
            selectionAnchorId = id
        }
    }

    private func clearSelection() {
        selectedElementIds = []
        lastSelectedId = nil
        selectionAnchorId = nil
        groupDragOrigins = [:]
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !selectedElementIds.isEmpty, var t = session.editingTemplate else { return }
        let paper = CGSize(width: t.paperSize.width, height: t.canvasHeight)
        var allowedDx = dx
        var allowedDy = dy
        for el in t.elements where selectedElementIds.contains(el.id) && !el.isLocked {
            allowedDx = min(allowedDx, paper.width - el.frame.width - el.frame.x)
            allowedDx = max(allowedDx, -el.frame.x)
            allowedDy = min(allowedDy, paper.height - el.frame.height - el.frame.y)
            allowedDy = max(allowedDy, -el.frame.y)
        }
        guard allowedDx != 0 || allowedDy != 0 else { return }
        pushUndoSnapshot()
        for i in t.elements.indices {
            guard selectedElementIds.contains(t.elements[i].id), !t.elements[i].isLocked else { continue }
            t.elements[i].frame.x += allowedDx
            t.elements[i].frame.y += allowedDy
        }
        session.editingTemplate = t
        session.markEditingDirty()
    }

    private func removeFromSelection(_ id: UUID) {
        selectedElementIds.remove(id)
        if lastSelectedId == id {
            lastSelectedId = selectedElementIds.first
        }
    }

    private func requestLeaveEditing(action: @escaping () -> Void) {
        if session.isEditingDirty {
            pendingLeaveAction = action
            showUnsavedDialog = true
        } else {
            action()
        }
    }

    private func applyGroupTranslate(
        anchorId: UUID,
        translation: CGSize,
        paper: CGSize,
        gridEnabled: Bool,
        gridSize: CGFloat
    ) {
        if groupDragOrigins.isEmpty {
            if !selectedElementIds.contains(anchorId) {
                selectElement(anchorId, additive: false)
            }
            let ids = selectedElementIds
            groupDragOrigins = Dictionary(uniqueKeysWithValues:
                (session.editingTemplate?.elements ?? [])
                    .filter { ids.contains($0.id) }
                    .map { ($0.id, $0.frame) }
            )
            if groupDragOrigins.isEmpty {
                if let frame = session.editingTemplate?.elements.first(where: { $0.id == anchorId })?.frame {
                    groupDragOrigins = [anchorId: frame]
                }
            }
        }
        guard !groupDragOrigins.isEmpty, var t = session.editingTemplate else { return }

        func snap(_ value: CGFloat) -> CGFloat {
            guard gridEnabled, gridSize > 0 else { return value }
            return (value / gridSize).rounded() * gridSize
        }

        let anchorOrigin = groupDragOrigins[anchorId]
            ?? groupDragOrigins[lastSelectedId ?? anchorId]
            ?? groupDragOrigins.values.first!
        let proposedDx = snap(anchorOrigin.x + translation.width) - anchorOrigin.x
        let proposedDy = snap(anchorOrigin.y + translation.height) - anchorOrigin.y

        var dx = proposedDx
        var dy = proposedDy
        for (id, origin) in groupDragOrigins {
            guard let el = t.elements.first(where: { $0.id == id }), !el.isLocked else { continue }
            dx = min(dx, paper.width - origin.width - origin.x)
            dx = max(dx, -origin.x)
            dy = min(dy, paper.height - origin.height - origin.y)
            dy = max(dy, -origin.y)
        }

        for i in t.elements.indices {
            let id = t.elements[i].id
            guard let origin = groupDragOrigins[id], !t.elements[i].isLocked else { continue }
            var next = origin
            next.x = origin.x + dx
            next.y = origin.y + dy
            t.elements[i].frame = next
        }
        session.editingTemplate = t
        session.markEditingDirty()
    }

    private func endGroupTranslate() {
        groupDragOrigins = [:]
    }

    private func deleteSelectedElements() {
        guard !selectedElementIds.isEmpty, var t = session.editingTemplate else { return }
        pushUndoSnapshot()
        let ids = selectedElementIds
        for id in ids {
            if t.elements.first(where: { $0.id == id })?.kind == .logo {
                session.logoImages.removeValue(forKey: id)
            }
        }
        t.elements.removeAll { ids.contains($0.id) }
        session.editingTemplate = t
        session.markEditingDirty()
        clearSelection()
        status = "已删除 \(ids.count) 个元素"
    }

    private func noteCanvasInteraction(_ active: Bool) {
        canvasGestureActive = active
        if active {
            if !undoPushedForGesture {
                pushUndoSnapshot()
                undoPushedForGesture = true
            }
        } else {
            undoPushedForGesture = false
        }
    }

    private func pushUndoSnapshot() {
        guard let t = session.editingTemplate else { return }
        if let last = undoStack.last, last == t { return }
        undoStack.append(t)
        if undoStack.count > Self.maxUndo {
            undoStack.removeFirst(undoStack.count - Self.maxUndo)
        }
    }

    private func performUndo() {
        guard let prev = undoStack.popLast() else { return }
        session.editingTemplate = prev
        session.markEditingDirty()
        selectedElementIds = selectedElementIds.filter { id in
            prev.elements.contains(where: { $0.id == id })
        }
        if let last = lastSelectedId,
           prev.elements.contains(where: { $0.id == last }) == false {
            lastSelectedId = selectedElementIds.first
        }
        status = L10n.ui("已撤销")
    }

    private func resetToFactoryLayout() {
        guard let current = session.editingTemplate else { return }
        pushUndoSnapshot()
        let oldLogoId = current.elements.first(where: { $0.kind == .logo })?.id
        let oldLogoImage = oldLogoId.flatMap { session.logoImages[$0] }
        let made = MovieTicketTemplate.factoryReset(preserving: current)
        var next = made.template
        if let newLogoId = made.logoElementId {
            if let oldLogoImage {
                session.logoImages[newLogoId] = oldLogoImage
            } else if let oldLogoId, let img = session.logoImages[oldLogoId] {
                session.logoImages[newLogoId] = img
            }
            if let oldLogoId, oldLogoId != newLogoId {
                session.logoImages.removeValue(forKey: oldLogoId)
            }
            // Keep on-disk filename if present on the previous logo element.
            if let oldLogoId,
               let oldEl = current.elements.first(where: { $0.id == oldLogoId }),
               let name = oldEl.imageFilename,
               let idx = next.elements.firstIndex(where: { $0.id == newLogoId }) {
                next.elements[idx].imageFilename = name
            }
        }
        session.editingTemplate = next
        session.markEditingDirty()
        clearSelection()
        status = L10n.ui("已恢复默认布局（可用撤销找回上一版）")
    }

    private func addField(_ kind: MovieTicketFieldKind) {
        guard var t = session.editingTemplate else { return }
        if t.hasElement(field: kind) {
            status = "已存在「\(kind.displayName)」"
            return
        }
        pushUndoSnapshot()
        let paperW = t.paperSize.width
        let dots = appState.settings.printerConfig.dotsPerLine
        let defaultH = MovieTicketPrintMetrics.lineHeightPoints(
            heightScale: 1, paperWidth: paperW, dotsPerLine: dots
        )
        let el = MovieTicketElement(
            kind: .fieldPlaceholder,
            frame: SequencePlaceholderFrame(
                x: 12,
                y: 200,
                width: kind == .barcode || kind == .qrCode ? 200 : 160,
                height: kind == .barcode || kind == .qrCode ? 56 : defaultH
            ),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1,
            fieldKind: kind
        )
        t.elements.append(el)
        session.editingTemplate = t
        session.markEditingDirty()
        selectElement(el.id, additive: false)
    }

    private func addTextBox() {
        guard var t = session.editingTemplate else { return }
        pushUndoSnapshot()
        let el = MovieTicketElement(
            kind: .textBox,
            frame: SequencePlaceholderFrame(x: 12, y: 20, width: 160, height: 28),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1,
            content: L10n.ui("文本")
        )
        t.elements.append(el)
        session.editingTemplate = t
        session.markEditingDirty()
        selectElement(el.id, additive: false)
    }

    private func addCurrentDate() {
        guard var t = session.editingTemplate else { return }
        pushUndoSnapshot()
        let el = MovieTicketElement(
            kind: .currentDate,
            frame: SequencePlaceholderFrame(x: 12, y: 400, width: 180, height: 24),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1
        )
        t.elements.append(el)
        session.editingTemplate = t
        session.markEditingDirty()
        selectElement(el.id, additive: false)
    }

    private func addCurrentTime() {
        guard var t = session.editingTemplate else { return }
        pushUndoSnapshot()
        let el = MovieTicketElement(
            kind: .currentTime,
            frame: SequencePlaceholderFrame(x: 200, y: 400, width: 90, height: 24),
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1
        )
        t.elements.append(el)
        session.editingTemplate = t
        session.markEditingDirty()
        selectElement(el.id, additive: false)
    }

    private func pickBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .png, .jpeg, .tiff, .gif, .bmp,
            UTType(filenameExtension: "webp") ?? .png
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        session.setBackground(ImagePreprocessor.toBinaryBlackWhite(img))
    }

    /// Same import path as 快速打印: pick image → B&W → `SequenceLogoItem.makeDefault` frame.
    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .png, .jpeg, .tiff, .gif, .bmp,
            UTType(filenameExtension: "webp") ?? .png
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        guard var t = session.editingTemplate else { return }
        let mono = ImagePreprocessor.toBinaryBlackWhite(img)
        let id = UUID()
        let paper = t.paperSize
        let item = SequenceLogoItem.makeDefault(
            id: id,
            imageFilename: MovieTicketTemplateStore.logoFilename(for: id),
            imageSize: mono.size,
            paperWidth: paper.width,
            paperSize: paper,
            staggerIndex: session.logoImages.count,
            zIndex: (t.elements.map(\.zIndex).max() ?? 0) + 1
        )
        var el = MovieTicketElement(
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
        session.logoImages[id] = mono
        session.markEditingDirty()
        selectElement(id, additive: false)
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

    private func pickSamplePDF() {
        guard let rule = editingRule else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        let result = panel.runModal()
        canvasGestureActive = false
        restoreKeyWindow()
        guard result == .OK, let url = panel.url else { return }
        if let name = session.store.importSamplePDF(from: url, for: rule.id) {
            editingRule?.samplePDFFilename = name
            loadSamplePDF(for: editingRule!)
            editingRule?.recordSamplePageSize(pdfPageSize)
            session.savePDFRule(editingRule!)
            status = L10n.ui("已上传样板 PDF（相对框选可应用于其它页面尺寸）")
            openPDFRegionEditor()
        }
    }

    private func loadSamplePDF(for rule: MovieTicketPDFRule) {
        guard let url = session.store.samplePDFURL(for: rule),
              let doc = PDFDocument(url: url) else {
            pdfPageImage = nil
            return
        }
        if let rendered = MovieTicketPDFPageRenderer.image(from: doc) {
            pdfPageImage = rendered.0
            pdfPageSize = rendered.1
        } else if let page = doc.page(at: 0) {
            pdfPageSize = MovieTicketPDFGeometry.displaySize(of: page)
            pdfPageImage = nil
        }

        // Record baseline size only; do NOT clear regions — relative rules must work across sizes.
        if var current = editingRule, current.id == rule.id,
           current.samplePageWidth == nil, pdfPageSize.width > 0 {
            current.recordSamplePageSize(pdfPageSize)
            editingRule = current
        }
    }

    private func testRecognition() {
        guard let rule = editingRule else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        let result = panel.runModal()
        canvasGestureActive = false
        restoreKeyWindow()
        guard result == .OK, let url = panel.url else { return }
        let fields = MovieTicketPDFRecognitionService.extractAllFields(from: url, rule: rule)
        if fields.isEmpty {
            testResults = [L10n.ui("未抽到文本。请确认是文字型 PDF，且框选区域正确。")]
        } else {
            testResults = fields.map { "\($0.key.displayName): \($0.value)" }
        }
    }

    /// Snap all placeholder box heights to the printer Font A / barcode block heights.
    private func syncPlaceholderSizesToPrint(recordUndo: Bool) {
        guard var t = session.editingTemplate else { return }
        if recordUndo { pushUndoSnapshot() }
        let config = appState.settings.printerConfig
        MovieTicketPrintMetrics.syncTemplateHeights(&t, config: config)
        session.editingTemplate = t
        if recordUndo { session.markEditingDirty() }
    }

    private func openPrintPreview() {
        showPrintPreview = true
        regeneratePrintPreview()
    }

    private func regeneratePrintPreview() {
        guard let t = session.editingTemplate else {
            printPreviewImage = nil
            return
        }
        let sample: MovieTicketDraft
        if t.usesIMAXSydneyLayout {
            sample = .imaxSydneySample()
        } else if t.usesRitzLayout {
            sample = .ritzMatrixSample()
        } else if t.elements.isEmpty {
            sample = .blank()
        } else {
            sample = .ritzMatrixSample()
        }
        let result = MovieTicketPrintComposer.compose(
            template: t,
            draft: sample,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig
        )
        printPreviewImage = result.previewImage
    }
}

// MARK: - Numeric input

/// Numeric text field that only writes back on Enter/blur, so typing (including
/// clearing the field) is not fought by live re-renders of the whole template.
private struct NumericField: View {
    var value: Double
    var range: ClosedRange<Double>? = nil
    var onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = format(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        guard let raw = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = format(value)
            return
        }
        let clamped = range.map { min($0.upperBound, max($0.lowerBound, raw)) } ?? raw
        onCommit(clamped)
        text = format(clamped)
    }

    private func format(_ d: Double) -> String { String(Int(d.rounded())) }
}

/// Number field + up/down steppers for fine-tuning frame coordinates.
private struct NumericStepperField: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var onCommit: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            NumericField(value: value, range: range, onCommit: onCommit)
                .frame(width: 56)
            Stepper(
                "",
                value: Binding(
                    get: { value },
                    set: { onCommit(min(range.upperBound, max(range.lowerBound, $0))) }
                ),
                in: range,
                step: step
            )
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

// MARK: - Grid / PDF page preview

private struct MovieTicketGridBackground: View {
    var size: CGSize
    var step: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
