import AppKit
import PDFKit
import SwiftUI

/// Pending region after a box-select, awaiting element / mode mapping.
struct MovieTicketPendingPDFRegion: Equatable {
    var rect: MovieTicketRelativeRect
    var previewText: String
}

/// Full-page PDF region editor: zoomable static page image + box-select (not text select).
struct MovieTicketPDFRegionEditorSheet: View {
    @Binding var rule: MovieTicketPDFRule
    let pageImage: NSImage
    let pageSize: CGSize
    let templateElements: [MovieTicketElement]
    let samplePDFURL: URL?
    var onSave: (MovieTicketPDFRule) -> Void
    var onDismiss: () -> Void

    @State private var zoom: CGFloat = 1.0
    @State private var pending: MovieTicketPendingPDFRegion?
    @State private var showMappingSheet = false
    @State private var editingRegionId: UUID?
    @State private var selectedRegionId: UUID?
    @State private var mapMode: MovieTicketPDFCaptureMode = .positionOnly
    @State private var mapKeywords: String = ""
    @State private var mapExtractSample: String = ""
    @State private var mapValueMappings: [MovieTicketPDFValueMapping] = []
    @State private var mapElementId: UUID?
    @State private var mapHint: String = ""
    /// When set, the next rubber-band maps directly to this template element (manual fallback).
    @State private var boxTargetElementId: UUID?
    @State private var status: String = L10n.ui("每个字段先点「自动识别」；失败后再「框选定位」")

    private static let zoomMin: CGFloat = 0.5
    private static let zoomMax: CGFloat = 3.0
    private static let baseWidth: CGFloat = 720

    private var displayWidth: CGFloat { Self.baseWidth * zoom }
    private var displayHeight: CGFloat {
        let ratio = pageSize.height / max(pageSize.width, 1)
        return displayWidth * ratio
    }

    private static let recognizerOrder: [MovieTicketFieldKind] = [
        .movieTitle, .showDate, .startTime, .timeRange, .hall,
        .seatArea, .ticketType, .ticketPrice, .serialNumber, .barcode, .qrCode
    ]

    private var mappableElements: [MovieTicketElement] {
        // One recognizer row per field kind. Dual-stub templates (e.g. Ritz) place
        // the same kinds twice on the canvas; PDF extraction keys by fieldKind.
        let filtered = templateElements.filter {
            $0.kind == .fieldPlaceholder && ($0.fieldKind?.isPDFExtractable ?? false)
        }
        let sorted = filtered.sorted { a, b in
            let ia = Self.recognizerOrder.firstIndex(of: a.fieldKind ?? .movieTitle) ?? 99
            let ib = Self.recognizerOrder.firstIndex(of: b.fieldKind ?? .movieTitle) ?? 99
            if ia != ib { return ia < ib }
            return elementIDString(a.id) < elementIDString(b.id)
        }
        var seen = Set<MovieTicketFieldKind>()
        var unique: [MovieTicketElement] = []
        for el in sorted {
            guard let kind = el.fieldKind else { continue }
            if seen.insert(kind).inserted {
                unique.append(el)
            }
        }
        return unique
    }

    private func elementIDString(_ id: UUID) -> String { id.uuidString }

    private var overlayRegions: [(id: UUID, rect: CGRect, label: String)] {
        // Auto-detect regions are page-wide — hide them so they don't block box-select.
        rule.regions.compactMap { region in
            guard region.showsCanvasBox else { return nil }
            return (
                region.id,
                CGRect(x: region.rect.x, y: region.rect.y, width: region.rect.width, height: region.rect.height),
                label(for: region)
            )
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                HSplitView {
                    pdfCanvasPane
                        .frame(minWidth: 420)
                    recognizerSidebar
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                }
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            if showMappingSheet, let pending {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { /* block behind clicks */ }
                mappingSheet(for: pending)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 16)
                    .padding(24)
                    .frame(maxWidth: 540)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            if mapElementId == nil {
                mapElementId = mappableElements.first?.id
            }
        }
        .onDisappear {
            showMappingSheet = false
            editingRegionId = nil
            pending = nil
        }
    }

    private var pdfCanvasPane: some View {
        ScrollView([.horizontal, .vertical]) {
            PDFRegionSelectNSViewRepresentable(
                image: pageImage,
                displaySize: CGSize(width: displayWidth, height: displayHeight),
                regions: overlayRegions,
                selectedRegionId: selectedRegionId,
                onCreateRegion: handleDragEnded,
                onMoveRegion: handleRegionMoved,
                onSelectRegion: { id in
                    selectedRegionId = id
                    if let region = rule.regions.first(where: { $0.id == id }) {
                        status = "已选中「\(label(for: region))」— 可拖动框位置"
                    }
                }
            )
            .frame(width: displayWidth, height: displayHeight)
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .allowsHitTesting(!showMappingSheet)
    }

    private var recognizerSidebar: some View {
        regionList
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(L10n.ui("PDF 区域编辑："))\(rule.name)")
                .font(.headline)
            Spacer()
            Button("−") { zoom = max(Self.zoomMin, zoom - 0.25) }
                .disabled(zoom <= Self.zoomMin || showMappingSheet)
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button("+") { zoom = min(Self.zoomMax, zoom + 0.25) }
                .disabled(zoom >= Self.zoomMax || showMappingSheet)
            Button(L10n.ui("适应")) { zoom = 1.0 }
                .disabled(showMappingSheet)
            Divider().frame(height: 16)
            Button(L10n.ui("完成")) {
                closeMappingOverlay()
                onSave(rule)
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(showMappingSheet)
            Button(L10n.ui("关闭")) {
                closeMappingOverlay()
                onDismiss()
            }
            .disabled(showMappingSheet)
        }
        .padding(12)
    }

    private func closeMappingOverlay() {
        showMappingSheet = false
        editingRegionId = nil
        pending = nil
    }

    private var regionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.ui("字段识别器")).font(.headline)
            Text(L10n.ui("与左侧 PDF 并列。先自动识别，失败再框选；每项可设关键词→打印映射。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ruleOptionsBar

            if mappableElements.isEmpty {
                Text(L10n.ui("当前模板没有可识别的字段。请先在模板编辑页添加「影片名称 / 日期 / 流水号…」。"))
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(mappableElements) { el in
                            recognizerRow(el)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var ruleOptionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.ui("无指定座位（导入 PDF 时不检索座位）"), isOn: $rule.skipSeatRecognition)
                .font(.caption)
            HStack(spacing: 8) {
                Text(L10n.ui("默认票型"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.ui("本规则下未识别到票型时填写"), text: $rule.defaultTicketType)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func recognizerRow(_ el: MovieTicketElement) -> some View {
        let kind = el.fieldKind
        let region = regionForElement(el)
        let isBoxing = boxTargetElementId == el.id
        let seatSkipped = kind == .seatArea && rule.skipSeatRecognition
        let hint = recognizerHint(region: region, seatSkipped: seatSkipped)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(elementLabel(el))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(hint.text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(hint.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let kind {
                Text(kind.recognizerSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            recognizerButtons(el: el, region: region, seatSkipped: seatSkipped, isBoxing: isBoxing)
            if isBoxing {
                Text(L10n.ui("下一步：在左侧 PDF 上拖拽出选区"))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            if !seatSkipped {
                printAffixEditor(for: el)
                valueMappingEditor(for: el)
            }
        }
        .padding(10)
        .background(isBoxing ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isBoxing ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func printAffixEditor(for el: MovieTicketElement) -> some View {
        let kind = el.fieldKind
        let isDateTime = kind == .showDate || kind == .startTime || kind == .timeRange || kind == .endTime
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.ui("字段前后文字"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if isDateTime {
                Text(L10n.ui("日期/时间用于排期解析，前后缀不会写入草稿；请用模板文字框拼接。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.ui("识别并映射后，在最终填入值前/后追加文字。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    TextField(L10n.ui("前缀"), text: printPrefixBinding(for: el))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                    Text(L10n.ui("· 识别值 ·"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(L10n.ui("后缀"), text: printSuffixBinding(for: el))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                }
                if let preview = printAffixPreview(for: el) {
                    Text("\(L10n.ui("预览："))\(preview)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 2)
    }

    private func printPrefixBinding(for el: MovieTicketElement) -> Binding<String> {
        Binding(
            get: { regionForElement(el)?.printPrefix ?? "" },
            set: { newValue in
                let idx = ensureRegionStub(for: el)
                guard idx >= 0 else { return }
                rule.regions[idx].printPrefix = newValue
            }
        )
    }

    private func printSuffixBinding(for el: MovieTicketElement) -> Binding<String> {
        Binding(
            get: { regionForElement(el)?.printSuffix ?? "" },
            set: { newValue in
                let idx = ensureRegionStub(for: el)
                guard idx >= 0 else { return }
                rule.regions[idx].printSuffix = newValue
            }
        )
    }

    private func printAffixPreview(for el: MovieTicketElement) -> String? {
        guard let region = regionForElement(el) else { return nil }
        let core = region.extractedHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty || !region.printPrefix.isEmpty || !region.printSuffix.isEmpty else {
            return nil
        }
        let mapped = MovieTicketPDFRecognitionService.applyValueMappings(
            core.isEmpty ? "…" : core,
            mappings: region.valueMappings
        )
        return MovieTicketPDFRecognitionService.applyPrintAffixes(mapped, region: region)
    }

    private func valueMappingEditor(for el: MovieTicketElement) -> some View {
        let mappings = regionForElement(el)?.valueMappings ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.ui("关键词映射（打印简写）"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(L10n.ui("检索到左侧内容时，小票上打印右侧文字。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(Array(mappings.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 4) {
                    TextField(L10n.ui("原文"), text: mappingMatchBinding(el: el, index: index))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                    Text("→")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(L10n.ui("打印"), text: mappingReplacementBinding(el: el, index: index))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                    Button(L10n.ui("删"), role: .destructive) {
                        removeMapping(el: el, index: index)
                    }
                    .controlSize(.mini)
                }
            }
            Button(L10n.ui("+ 添加映射")) {
                appendMapping(for: el)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private func mappingMatchBinding(el: MovieTicketElement, index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let maps = regionForElement(el)?.valueMappings, maps.indices.contains(index) else {
                    return ""
                }
                return maps[index].match
            },
            set: { newValue in
                updateMapping(el: el, index: index) { $0.match = newValue }
            }
        )
    }

    private func mappingReplacementBinding(el: MovieTicketElement, index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let maps = regionForElement(el)?.valueMappings, maps.indices.contains(index) else {
                    return ""
                }
                return maps[index].replacement
            },
            set: { newValue in
                updateMapping(el: el, index: index) { $0.replacement = newValue }
            }
        )
    }

    private func ensureRegionStub(for el: MovieTicketElement) -> Int {
        if let idx = rule.regions.firstIndex(where: {
            $0.elementId == el.id || $0.fieldKind == el.fieldKind
        }) {
            return idx
        }
        guard let field = el.fieldKind else { return -1 }
        let region = MovieTicketPDFRegion(
            fieldKind: field,
            elementId: el.id,
            rect: MovieTicketRelativeRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            pageIndex: 0,
            captureMode: .withKeywords,
            extractedHint: "",
            isPageWideAuto: true
        )
        rule.regions.append(region)
        return rule.regions.count - 1
    }

    private func appendMapping(for el: MovieTicketElement) {
        let idx = ensureRegionStub(for: el)
        guard idx >= 0 else { return }
        // Prefill 原文 with the latest recognized value so user only types the print short form.
        let recognized = recognizedText(for: el)
        rule.regions[idx].valueMappings.append(
            MovieTicketPDFValueMapping(match: recognized, replacement: "")
        )
    }

    /// Best available recognized text for mapping 原文 (hint → live auto-detect).
    private func recognizedText(for el: MovieTicketElement) -> String {
        if let hint = regionForElement(el)?.extractedHint
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint
        }
        guard let kind = el.fieldKind, let url = samplePDFURL,
              let hit = MovieTicketPDFFieldRecognizer.autoDetect(fieldKind: kind, from: url)
        else { return "" }
        return hit.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeMapping(el: MovieTicketElement, index: Int) {
        guard let idx = rule.regions.firstIndex(where: {
            $0.elementId == el.id || $0.fieldKind == el.fieldKind
        }),
        rule.regions[idx].valueMappings.indices.contains(index)
        else { return }
        rule.regions[idx].valueMappings.remove(at: index)
    }

    private func updateMapping(
        el: MovieTicketElement,
        index: Int,
        mutate: (inout MovieTicketPDFValueMapping) -> Void
    ) {
        let idx = ensureRegionStub(for: el)
        guard idx >= 0, rule.regions[idx].valueMappings.indices.contains(index) else { return }
        mutate(&rule.regions[idx].valueMappings[index])
    }

    private func regionForElement(_ el: MovieTicketElement) -> MovieTicketPDFRegion? {
        rule.regions.first { $0.elementId == el.id || $0.fieldKind == el.fieldKind }
    }

    private func recognizerHint(
        region: MovieTicketPDFRegion?,
        seatSkipped: Bool
    ) -> (text: String, color: Color) {
        if seatSkipped { return (L10n.ui("已跳过"), .orange) }
        if let region {
            let t = region.extractedHint.isEmpty ? L10n.ui("已配置") : region.extractedHint
            return (t, .secondary)
        }
        return (L10n.ui("未配置"), .red)
    }

    @ViewBuilder
    private func recognizerButtons(
        el: MovieTicketElement,
        region: MovieTicketPDFRegion?,
        seatSkipped: Bool,
        isBoxing: Bool
    ) -> some View {
        if !seatSkipped {
            HStack(spacing: 6) {
                Button(L10n.ui("自动识别")) { runAutoDetect(for: el) }
                    .controlSize(.small)
                    .disabled(showMappingSheet || samplePDFURL == nil)
                Button(isBoxing ? L10n.ui("框选中…") : L10n.ui("框选定位")) {
                    toggleBoxTarget(el, currentlyBoxing: isBoxing)
                }
                .controlSize(.small)
                .disabled(showMappingSheet)
                if let region {
                    Button(L10n.ui("高级")) { beginEditRegion(region) }
                        .controlSize(.small)
                        .disabled(showMappingSheet)
                    Button(L10n.ui("清除"), role: .destructive) {
                        removeRecognizer(for: el, regionId: region.id)
                    }
                    .controlSize(.small)
                    .disabled(showMappingSheet)
                }
            }
        }
    }

    private func toggleBoxTarget(_ el: MovieTicketElement, currentlyBoxing: Bool) {
        if currentlyBoxing {
            boxTargetElementId = nil
            status = L10n.ui("已取消框选")
        } else {
            boxTargetElementId = el.id
            status = "请在 PDF 上拖拽框选「\(elementLabel(el))」的识别位置"
        }
    }

    private func removeRecognizer(for el: MovieTicketElement, regionId: UUID) {
        rule.regions.removeAll { $0.elementId == el.id || $0.fieldKind == el.fieldKind }
        if selectedRegionId == regionId { selectedRegionId = nil }
        status = "已删除「\(elementLabel(el))」识别配置"
    }

    private func runAutoDetect(for el: MovieTicketElement) {
        guard let kind = el.fieldKind, let url = samplePDFURL else {
            status = L10n.ui("无样本 PDF，无法自动识别")
            return
        }
        if kind == .seatArea, rule.skipSeatRecognition {
            status = L10n.ui("已设为无指定座位，跳过座位识别")
            return
        }
        let hit = MovieTicketPDFFieldRecognizer.autoDetect(fieldKind: kind, from: url)
        guard let hit else {
            boxTargetElementId = el.id
            status = "未找到「\(elementLabel(el))」特征 — 请在左侧 PDF 上框选定位"
            return
        }
        let previous = rule.regions.first {
            $0.elementId == el.id || $0.fieldKind == kind
        }
        guard let region = MovieTicketPDFFieldRecognizer.makeAutoRegion(
            for: el,
            hit: hit,
            existingId: previous?.id,
            preserving: previous
        ) else { return }
        rule.regions.removeAll { $0.elementId == el.id || $0.fieldKind == kind }
        rule.regions.append(region)
        selectedRegionId = region.id
        boxTargetElementId = nil
        status = "已自动识别「\(elementLabel(el))」→ \(hit.value)"
    }

    private func handleDragEnded(_ viewRect: CGRect) {
        // viewRect is already in relative 0…1 display space from NSView.
        guard viewRect.width >= 0.005, viewRect.height >= 0.005 else {
            status = L10n.ui("选区太小，请重新拖拽框选")
            return
        }
        let rel = MovieTicketRelativeRect(
            x: viewRect.minX,
            y: viewRect.minY,
            width: viewRect.width,
            height: viewRect.height
        ).clamped()
        editingRegionId = nil
        selectedRegionId = nil
        let preview = previewText(for: rel, fieldKind: targetFieldKind(for: boxTargetElementId))
        mapHint = preview
        mapMode = .positionOnly
        mapKeywords = ""
        mapExtractSample = ""
        mapValueMappings = []

        // Targeted box-select from a recognizer row → save directly.
        if let targetId = boxTargetElementId,
           let el = mappableElements.first(where: { $0.id == targetId }),
           let field = el.fieldKind {
            let keepId = rule.regions.first { $0.elementId == el.id || $0.fieldKind == field }?.id ?? UUID()
            let previous = rule.regions.first { $0.id == keepId }
            let region = MovieTicketPDFRegion(
                id: keepId,
                fieldKind: field,
                elementId: el.id,
                rect: rel,
                pageIndex: 0,
                captureMode: .positionOnly,
                regionKeywords: [],
                extractKind: defaultExtractKind(for: field),
                extractKeyword: defaultExtractKeyword(for: field),
                extractSample: preview,
                extractedHint: preview,
                valueMappings: previous?.valueMappings ?? [],
                printPrefix: previous?.printPrefix ?? "",
                printSuffix: previous?.printSuffix ?? "",
                isPageWideAuto: false
            )
            rule.regions.removeAll { $0.id == keepId || $0.fieldKind == field || $0.elementId == el.id }
            rule.regions.append(region)
            selectedRegionId = keepId
            boxTargetElementId = nil
            status = preview.isEmpty
                ? "已框选「\(elementLabel(el))」，但选区内无文字 — 可点「改」调整"
                : "已框选「\(elementLabel(el))」→ \(preview)"
            return
        }

        if mapElementId == nil || !mappableElements.contains(where: { $0.id == mapElementId }) {
            mapElementId = mappableElements.first?.id
        }
        pending = MovieTicketPendingPDFRegion(rect: rel, previewText: preview)
        showMappingSheet = true
        status = L10n.ui("请指定映射方式与目标元素块")
    }

    private func targetFieldKind(for elementId: UUID?) -> MovieTicketFieldKind? {
        guard let elementId else { return nil }
        return mappableElements.first(where: { $0.id == elementId })?.fieldKind
    }

    private func defaultExtractKind(for field: MovieTicketFieldKind) -> MovieTicketPDFExtractKind {
        switch field {
        case .ticketPrice: return .currency
        case .serialNumber: return .digits
        default: return .entire
        }
    }

    private func defaultExtractKeyword(for field: MovieTicketFieldKind) -> String {
        switch field {
        case .ticketPrice: return "Total"
        case .seatArea: return "Seats"
        case .startTime, .timeRange: return "Time"
        default: return ""
        }
    }

    private func handleRegionMoved(id: UUID, rel: CGRect) {
        guard let idx = rule.regions.firstIndex(where: { $0.id == id }) else { return }
        let moved = MovieTicketRelativeRect(
            x: rel.origin.x,
            y: rel.origin.y,
            width: rel.size.width,
            height: rel.size.height
        ).clamped()
        rule.regions[idx].rect = moved
        // Refresh hint from new position so extract preview stays accurate.
        let preview = previewText(for: moved, fieldKind: rule.regions[idx].fieldKind)
        if !preview.isEmpty {
            rule.regions[idx].extractedHint = preview
        }
        selectedRegionId = id
        status = "已移动「\(label(for: rule.regions[idx]))」— 点「完成」保存"
    }

    private func beginEditRegion(_ region: MovieTicketPDFRegion) {
        selectedRegionId = region.id
        editingRegionId = region.id
        mapHint = region.extractedHint.isEmpty
            ? previewText(for: region.rect, fieldKind: region.fieldKind)
            : region.extractedHint
        mapMode = region.captureMode
        mapKeywords = region.regionKeywords.joined(separator: ", ")
        mapExtractSample = region.extractSample
        mapValueMappings = region.valueMappings
        mapElementId = region.elementId
            ?? mappableElements.first(where: { $0.fieldKind == region.fieldKind })?.id
            ?? mappableElements.first?.id
        pending = MovieTicketPendingPDFRegion(rect: region.rect, previewText: mapHint)
        showMappingSheet = true
        status = "正在修改「\(label(for: region))」"
    }

    /// Live preview of extract + value mapping for the mapping sheet.
    private var mappedValuePreview: String {
        let analysis = MovieTicketPDFRecognitionService.analyzeExtractSample(mapExtractSample, in: mapHint)
        let extracted = MovieTicketPDFRecognitionService.applyExtractFilter(
            mapHint,
            kind: analysis.kind,
            keyword: analysis.keyword
        )
        let base = extracted.isEmpty ? mapHint : extracted
        return MovieTicketPDFRecognitionService.applyValueMappings(base, mappings: mapValueMappings)
    }

    private func mappingSheet(for pendingRegion: MovieTicketPendingPDFRegion) -> some View {
        let isEditing = editingRegionId != nil
        return VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? L10n.ui("修改映射") : L10n.ui("映射选区到元素块")).font(.headline)
            if isEditing {
                Text(L10n.ui("修改定位方式、关键词或仅提取内容。框选位置保持不变；若要改位置请删除后重新框选。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.ui("选区内识别到的文字预览："))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $mapHint)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 120)
                .border(Color.secondary.opacity(0.3))

            Picker(L10n.ui("定位方式"), selection: $mapMode) {
                ForEach(MovieTicketPDFCaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mapMode == .withKeywords {
                TextField(L10n.ui("定位关键词（逗号分隔）"), text: $mapKeywords)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.ui("以后换 PDF 时优先用这些词在整页定位选区，例如 Total、SESSION DATE & TIME。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.ui("按相对位置抽取；页面比例变化大时可能偏移，重要字段建议改用「识别关键词」。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(L10n.ui("仅提取"))
                .font(.subheadline.weight(.semibold))
            TextField(L10n.ui("填写想保留的内容，如 20.45 或 $20.45（留空=全部）"), text: $mapExtractSample)
                .textFieldStyle(.roundedBorder)
            Text(L10n.ui("从上方预览里抄一段目标内容即可；软件会分析它是金额/数字，以及前面的锚定词。"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            let analysis = MovieTicketPDFRecognitionService.analyzeExtractSample(mapExtractSample, in: mapHint)
            if !mapExtractSample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分析特征：\(analysis.summary)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            Text(L10n.ui("映射规则"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.ui("抓取结果匹配左侧原文时，打印用右侧简写（不区分大小写；多条时优先最长匹配）。"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach($mapValueMappings) { $row in
                HStack(spacing: 6) {
                    TextField(L10n.ui("原文，如 Member Adult"), text: $row.match)
                        .textFieldStyle(.roundedBorder)
                    Text("→")
                        .foregroundStyle(.secondary)
                    TextField(L10n.ui("简写，如 Mem Adu"), text: $row.replacement)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.ui("删"), role: .destructive) {
                        mapValueMappings.removeAll { $0.id == row.id }
                    }
                    .controlSize(.small)
                }
            }
            Button(L10n.ui("+ 添加规则")) {
                mapValueMappings.append(MovieTicketPDFValueMapping(match: "", replacement: ""))
            }
            .controlSize(.small)

            if mapValueMappings.contains(where: {
                !$0.match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.ui("打印预览："))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mappedValuePreview.isEmpty ? L10n.ui("（空）") : mappedValuePreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if mappableElements.isEmpty {
                Text(L10n.ui("当前模板没有可映射的字段元素块。请先在画布上添加「流水号 / 票型 / 影厅…」等字段。"))
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Picker(L10n.ui("填入元素块"), selection: $mapElementId) {
                    ForEach(mappableElements) { el in
                        Text(elementLabel(el)).tag(Optional(el.id))
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.ui("取消")) {
                    closeMappingOverlay()
                }
                Button(isEditing ? L10n.ui("保存修改") : L10n.ui("确认映射")) { confirmMapping(pendingRegion) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mapElementId == nil || mappableElements.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func confirmMapping(_ pendingRegion: MovieTicketPendingPDFRegion) {
        guard let elementId = mapElementId,
              let el = mappableElements.first(where: { $0.id == elementId }),
              let field = el.fieldKind else { return }
        let keywords = mapKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let analysis = MovieTicketPDFRecognitionService.analyzeExtractSample(mapExtractSample, in: mapHint)
        // Auto-locate by inferred anchor when user only filled the extract sample.
        var locateKeywords = mapMode == .withKeywords ? keywords : []
        var mode = mapMode
        if locateKeywords.isEmpty, !analysis.keyword.isEmpty, analysis.kind != .entire {
            locateKeywords = [analysis.keyword]
            mode = .withKeywords
        }
        let keepId = editingRegionId ?? UUID()
        let cleanedMappings = mapValueMappings.filter {
            !$0.match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let previous = rule.regions.first { $0.id == keepId }
        let region = MovieTicketPDFRegion(
            id: keepId,
            fieldKind: field,
            elementId: elementId,
            rect: pendingRegion.rect,
            pageIndex: 0,
            captureMode: mode,
            regionKeywords: locateKeywords,
            extractKind: analysis.kind,
            extractKeyword: analysis.keyword,
            extractSample: analysis.sample,
            extractedHint: mapHint.trimmingCharacters(in: .whitespacesAndNewlines),
            valueMappings: cleanedMappings,
            printPrefix: previous?.printPrefix ?? "",
            printSuffix: previous?.printSuffix ?? "",
            isPageWideAuto: false
        )
        rule.regions.removeAll {
            $0.id == keepId || $0.fieldKind == field || $0.elementId == elementId
        }
        rule.regions.append(region)
        selectedRegionId = keepId
        closeMappingOverlay()
        let extractNote = analysis.kind == .entire ? "" : " · \(analysis.summary)"
        status = "已保存「\(elementLabel(el))」\(extractNote) — 点「完成」写入规则"
    }

    private func previewText(
        for rel: MovieTicketRelativeRect,
        fieldKind: MovieTicketFieldKind? = nil
    ) -> String {
        guard let url = samplePDFURL else { return "" }
        let kind = fieldKind ?? .serialNumber
        let temp = MovieTicketPDFRegion(fieldKind: kind, rect: rel, pageIndex: 0)
        return (try? MovieTicketPDFRecognitionService.extractText(from: url, region: temp)) ?? ""
    }

    private func label(for region: MovieTicketPDFRegion) -> String {
        if let id = region.elementId,
           let el = templateElements.first(where: { $0.id == id }) {
            return elementLabel(el)
        }
        return region.fieldKind.displayName
    }

    private func elementLabel(_ el: MovieTicketElement) -> String {
        let custom = el.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return el.fieldKind?.displayName ?? L10n.ui("字段")
    }
}

// MARK: - AppKit rubber-band selector + region move (top-left coords)

private struct PDFRegionOverlayItem: Equatable {
    var id: UUID
    var rect: CGRect
    var label: String
}

private struct PDFRegionSelectNSViewRepresentable: NSViewRepresentable {
    let image: NSImage
    let displaySize: CGSize
    let regions: [(id: UUID, rect: CGRect, label: String)]
    var selectedRegionId: UUID?
    let onCreateRegion: (CGRect) -> Void
    let onMoveRegion: (UUID, CGRect) -> Void
    let onSelectRegion: (UUID) -> Void

    func makeNSView(context: Context) -> PDFRegionSelectNSView {
        let view = PDFRegionSelectNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PDFRegionSelectNSView, context: Context) {
        apply(to: nsView)
        nsView.needsDisplay = true
    }

    private func apply(to view: PDFRegionSelectNSView) {
        view.image = image
        // Don't clobber in-progress move preview with stale parent state.
        if view.moveSession == nil {
            view.regions = regions.map {
                PDFRegionOverlayItem(id: $0.id, rect: $0.rect, label: $0.label)
            }
        }
        view.selectedRegionId = selectedRegionId
        view.onCreateRegion = onCreateRegion
        view.onMoveRegion = onMoveRegion
        view.onSelectRegion = onSelectRegion
    }
}

private final class PDFRegionSelectNSView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var regions: [PDFRegionOverlayItem] = [] { didSet { needsDisplay = true } }
    var selectedRegionId: UUID? { didSet { needsDisplay = true } }
    var onCreateRegion: ((CGRect) -> Void)?
    var onMoveRegion: ((UUID, CGRect) -> Void)?
    var onSelectRegion: ((UUID) -> Void)?

    /// Active move; kept so SwiftUI updates don't reset the live rect mid-drag.
    private(set) var moveSession: (id: UUID, startPoint: CGPoint, originalRel: CGRect)?
    private var createStart: CGPoint?
    private var createCurrent: CGPoint?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var contentRect: CGRect {
        guard let image else { return bounds }
        return MovieTicketPDFGeometry.aspectFitContentRect(imageSize: image.size, in: bounds)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
        let content = contentRect
        for item in regions {
            let abs = absoluteRect(fromRelative: item.rect, in: content)
            addCursorRect(abs, cursor: .openHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let content = contentRect
        if let image {
            image.draw(
                in: content,
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        for item in regions {
            let rect = absoluteRect(fromRelative: item.rect, in: content)
            let selected = item.id == selectedRegionId
            (selected ? NSColor.systemOrange : NSColor.systemBlue)
                .withAlphaComponent(0.18).setFill()
            rect.fill()
            (selected ? NSColor.systemOrange : NSColor.systemBlue).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = selected ? 2.5 : 2
            path.stroke()
            let bg = (selected ? NSColor.systemOrange : NSColor.systemBlue).withAlphaComponent(0.9)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: bg
            ]
            (item.label as NSString).draw(
                at: CGPoint(x: rect.minX, y: max(0, rect.minY - 14)),
                withAttributes: attrs
            )
        }

        if let start = createStart, let cur = createCurrent {
            let rect = CGRect(
                x: min(start.x, cur.x),
                y: min(start.y, cur.y),
                width: abs(cur.x - start.x),
                height: abs(cur.y - start.y)
            )
            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            rect.fill()
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func absoluteRect(fromRelative rel: CGRect, in content: CGRect) -> CGRect {
        CGRect(
            x: content.minX + rel.origin.x * content.width,
            y: content.minY + rel.origin.y * content.height,
            width: rel.size.width * content.width,
            height: rel.size.height * content.height
        )
    }

    private func relativeRect(fromAbsolute rect: CGRect, in content: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - content.minX) / content.width,
            y: (rect.minY - content.minY) / content.height,
            width: rect.width / content.width,
            height: rect.height / content.height
        )
    }

    private func hitTestRegion(at point: CGPoint) -> PDFRegionOverlayItem? {
        let content = contentRect
        // Topmost first (last in list drawn last).
        for item in regions.reversed() {
            let abs = absoluteRect(fromRelative: item.rect, in: content)
            if abs.insetBy(dx: -2, dy: -2).contains(point) {
                return item
            }
        }
        return nil
    }

    private func clampedRelativeMove(original: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var x = original.origin.x + dx
        var y = original.origin.y + dy
        let w = original.size.width
        let h = original.size.height
        x = min(max(0, x), max(0, 1 - w))
        y = min(max(0, y), max(0, 1 - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTestRegion(at: p) {
            moveSession = (hit.id, p, hit.rect)
            selectedRegionId = hit.id
            onSelectRegion?(hit.id)
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        moveSession = nil
        createStart = p
        createCurrent = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let session = moveSession {
            let content = contentRect
            guard content.width > 0, content.height > 0 else { return }
            let dx = (p.x - session.startPoint.x) / content.width
            let dy = (p.y - session.startPoint.y) / content.height
            let moved = clampedRelativeMove(original: session.originalRel, dx: dx, dy: dy)
            if let idx = regions.firstIndex(where: { $0.id == session.id }) {
                regions[idx].rect = moved
            }
            needsDisplay = true
            return
        }
        createCurrent = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        defer {
            createStart = nil
            createCurrent = nil
            moveSession = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }

        if let session = moveSession {
            let content = contentRect
            guard content.width > 0, content.height > 0 else { return }
            let dx = (end.x - session.startPoint.x) / content.width
            let dy = (end.y - session.startPoint.y) / content.height
            let moved = clampedRelativeMove(original: session.originalRel, dx: dx, dy: dy)
            if let idx = regions.firstIndex(where: { $0.id == session.id }) {
                regions[idx].rect = moved
            }
            NSCursor.arrow.set()
            onMoveRegion?(session.id, moved)
            return
        }

        guard let start = createStart else { return }
        let absRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(1, abs(end.x - start.x)),
            height: max(1, abs(end.y - start.y))
        )
        let content = contentRect
        let clipped = absRect.intersection(content)
        guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else { return }
        let rel = relativeRect(fromAbsolute: clipped, in: content)
        onCreateRegion?(rel)
    }
}

enum MovieTicketPDFPageRenderer {
    /// Renders a page upright using cropBox + rotation-aware display size.
    static func image(
        from doc: PDFDocument,
        pageIndex: Int = 0,
        maxPixelWidth: CGFloat = 1600
    ) -> (NSImage, CGSize)? {
        guard pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex)
        else { return nil }
        let displaySize = MovieTicketPDFGeometry.displaySize(of: page)
        let scale = maxPixelWidth / max(displaySize.width, 1)
        let pixelSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        let image = page.thumbnail(of: pixelSize, for: MovieTicketPDFGeometry.boxType)

        return (image, displaySize)
    }
}
