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
    @State private var status: String = "拖拽空白处新建框选；拖动已有蓝框可移动位置"

    private static let zoomMin: CGFloat = 0.5
    private static let zoomMax: CGFloat = 3.0
    private static let baseWidth: CGFloat = 720

    private var displayWidth: CGFloat { Self.baseWidth * zoom }
    private var displayHeight: CGFloat {
        let ratio = pageSize.height / max(pageSize.width, 1)
        return displayWidth * ratio
    }

    private var mappableElements: [MovieTicketElement] {
        templateElements.filter {
            $0.kind == .fieldPlaceholder && ($0.fieldKind?.isPDFExtractable ?? false)
        }
    }

    private var overlayRegions: [(id: UUID, rect: CGRect, label: String)] {
        rule.regions.map { region in
            (
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
                                status = "已选中「\(label(for: region))」— 可拖动框位置，或点「改」编辑设置"
                            }
                        }
                    )
                    .frame(width: displayWidth, height: displayHeight)
                    .padding(16)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                // Disable canvas while mapping overlay is open (avoids stuck mouse sessions).
                .allowsHitTesting(!showMappingSheet)
                Divider()
                regionList
                    // Fixed panel height so the PDF ScrollView above cannot steal this space,
                    // and the inner row ScrollView always gets a real viewport (not ~0).
                    .frame(height: 220)
                    .layoutPriority(1)
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            // Inline overlay instead of nested .sheet — nested sheets on macOS often leave
            // an invisible modal that freezes the parent editor after dismiss.
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
        .frame(minWidth: 820, minHeight: 640)
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

    private var header: some View {
        HStack(spacing: 12) {
            Text("PDF 区域编辑：\(rule.name)")
                .font(.headline)
            Spacer()
            Button("−") { zoom = max(Self.zoomMin, zoom - 0.25) }
                .disabled(zoom <= Self.zoomMin || showMappingSheet)
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button("+") { zoom = min(Self.zoomMax, zoom + 0.25) }
                .disabled(zoom >= Self.zoomMax || showMappingSheet)
            Button("适应") { zoom = 1.0 }
                .disabled(showMappingSheet)
            Divider().frame(height: 16)
            Button("完成") {
                closeMappingOverlay()
                onSave(rule)
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(showMappingSheet)
            Button("关闭") {
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
        VStack(alignment: .leading, spacing: 4) {
            Text("已映射区域").font(.subheadline.weight(.semibold))
            Text("点击一行可修改设置；在 PDF 上拖动蓝框可移动位置。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if rule.regions.isEmpty {
                Text("尚无区域。在上方 PDF 上拖拽框选。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Scroll so many regions never compress/clip inside the fixed panel height.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(rule.regions) { region in
                            regionRow(region)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func regionRow(_ region: MovieTicketPDFRegion) -> some View {
        HStack(spacing: 8) {
            Button {
                beginEditRegion(region)
            } label: {
                HStack(spacing: 6) {
                    Text(label(for: region))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(region.captureMode.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !region.regionKeywords.isEmpty {
                        Text(region.regionKeywords.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !region.extractSample.isEmpty {
                        Text("提取「\(region.extractSample)」")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if region.extractKind != .entire {
                        Text(region.extractKind.displayName)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    if !region.valueMappings.isEmpty {
                        Text("映射×\(region.valueMappings.count)")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    }
                    if !region.extractedHint.isEmpty {
                        Text(region.extractedHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("改") { beginEditRegion(region) }
                .controlSize(.small)
            Button("删", role: .destructive) {
                if selectedRegionId == region.id { selectedRegionId = nil }
                if editingRegionId == region.id {
                    closeMappingOverlay()
                }
                rule.regions.removeAll { $0.id == region.id }
                status = "已删除「\(label(for: region))」"
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedRegionId == region.id
                      ? Color.accentColor.opacity(0.15)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    selectedRegionId == region.id ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private func handleDragEnded(_ viewRect: CGRect) {
        // viewRect is already in relative 0…1 display space from NSView.
        guard viewRect.width >= 0.005, viewRect.height >= 0.005 else {
            status = "选区太小，请重新拖拽框选"
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
        let preview = previewText(for: rel)
        mapHint = preview
        mapMode = .positionOnly
        mapKeywords = ""
        mapExtractSample = ""
        mapValueMappings = []
        if mapElementId == nil || !mappableElements.contains(where: { $0.id == mapElementId }) {
            mapElementId = mappableElements.first?.id
        }
        pending = MovieTicketPendingPDFRegion(rect: rel, previewText: preview)
        showMappingSheet = true
        status = "请指定映射方式与目标元素块"
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
        let preview = previewText(for: moved)
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
            ? previewText(for: region.rect)
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
            Text(isEditing ? "修改映射" : "映射选区到元素块").font(.headline)
            if isEditing {
                Text("修改定位方式、关键词或仅提取内容。框选位置保持不变；若要改位置请删除后重新框选。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("选区内识别到的文字预览：")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $mapHint)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 120)
                .border(Color.secondary.opacity(0.3))

            Picker("定位方式", selection: $mapMode) {
                ForEach(MovieTicketPDFCaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mapMode == .withKeywords {
                TextField("定位关键词（逗号分隔）", text: $mapKeywords)
                    .textFieldStyle(.roundedBorder)
                Text("以后换 PDF 时优先用这些词在整页定位选区，例如 Total、SESSION DATE & TIME。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("按相对位置抽取；页面比例变化大时可能偏移，重要字段建议改用「识别关键词」。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("仅提取")
                .font(.subheadline.weight(.semibold))
            TextField("填写想保留的内容，如 20.45 或 $20.45（留空=全部）", text: $mapExtractSample)
                .textFieldStyle(.roundedBorder)
            Text("从上方预览里抄一段目标内容即可；软件会分析它是金额/数字，以及前面的锚定词。")
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

            Text("映射规则")
                .font(.subheadline.weight(.semibold))
            Text("抓取结果匹配左侧原文时，打印用右侧简写（不区分大小写；多条时优先最长匹配）。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach($mapValueMappings) { $row in
                HStack(spacing: 6) {
                    TextField("原文，如 Member Adult", text: $row.match)
                        .textFieldStyle(.roundedBorder)
                    Text("→")
                        .foregroundStyle(.secondary)
                    TextField("简写，如 Mem Adu", text: $row.replacement)
                        .textFieldStyle(.roundedBorder)
                    Button("删", role: .destructive) {
                        mapValueMappings.removeAll { $0.id == row.id }
                    }
                    .controlSize(.small)
                }
            }
            Button("+ 添加规则") {
                mapValueMappings.append(MovieTicketPDFValueMapping(match: "", replacement: ""))
            }
            .controlSize(.small)

            if mapValueMappings.contains(where: {
                !$0.match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("打印预览：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mappedValuePreview.isEmpty ? "（空）" : mappedValuePreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if mappableElements.isEmpty {
                Text("当前模板没有可映射的字段元素块。请先在画布上添加「流水号 / 票型 / 影厅…」等字段。")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Picker("填入元素块", selection: $mapElementId) {
                    ForEach(mappableElements) { el in
                        Text(elementLabel(el)).tag(Optional(el.id))
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    closeMappingOverlay()
                }
                Button(isEditing ? "保存修改" : "确认映射") { confirmMapping(pendingRegion) }
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
            valueMappings: cleanedMappings
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

    private func previewText(for rel: MovieTicketRelativeRect) -> String {
        guard let url = samplePDFURL else { return "" }
        let temp = MovieTicketPDFRegion(fieldKind: .serialNumber, rect: rel, pageIndex: 0)
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
        return el.fieldKind?.displayName ?? "字段"
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
    /// Renders page 0 upright using cropBox + rotation-aware display size.
    static func image(from doc: PDFDocument, maxPixelWidth: CGFloat = 1600) -> (NSImage, CGSize)? {
        guard let page = doc.page(at: 0) else { return nil }
        let displaySize = MovieTicketPDFGeometry.displaySize(of: page)
        let scale = maxPixelWidth / max(displaySize.width, 1)
        let pixelSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        let image = page.thumbnail(of: pixelSize, for: MovieTicketPDFGeometry.boxType)

        return (image, displaySize)
    }
}
