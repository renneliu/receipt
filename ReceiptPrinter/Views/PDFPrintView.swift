import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Import a PDF, freely box-select a region, and print that crop scaled to receipt width.
struct PDFPrintView: View {
    @EnvironmentObject private var appState: AppState

    @State private var pdfURL: URL?
    @State private var pdfDocument: PDFDocument?
    @State private var pageIndex: Int = 0
    @State private var pageImage: NSImage?
    @State private var selection: CGRect?
    @State private var isPrinting = false
    @State private var message: String?
    @State private var previewImage: NSImage?
    @State private var rotate90 = false
    @State private var feedLinesBeforeCut: Int = 12
    @State private var isDropTargeted = false

    private var config: PrinterConfig { appState.settings.printerConfig }
    private var pageCount: Int { pdfDocument?.pageCount ?? 0 }
    private var hasDocument: Bool { pageImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.ui("PDF打印")).font(.title2.weight(.semibold))
                Spacer()
                if hasDocument {
                    Button(L10n.ui("导入 PDF…")) { importPDF() }
                    pageNavigationBar
                    Button(L10n.ui("自动寻找边界")) { autoDetectBounds() }
                    Button(L10n.ui("整页选区")) { selectFullPage() }
                    Button(L10n.ui("清除选区")) { selection = nil; previewImage = nil }
                        .disabled(selection == nil)
                    Toggle(L10n.ui("翻转90°打印"), isOn: $rotate90)
                        .toggleStyle(.checkbox)
                    Button(isPrinting ? L10n.ui("打印中…") : L10n.ui("打印选区 (⌘↩)")) {
                        Task { await printCrop(relative: selection) }
                    }
                    .disabled(selection == nil || isPrinting
                              || appState.settings.selectedPrinterName == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                    Button(isPrinting ? L10n.ui("打印中…") : L10n.ui("整页打印")) {
                        Task { await printCrop(relative: CGRect(x: 0, y: 0, width: 1, height: 1)) }
                    }
                    .disabled(isPrinting || appState.settings.selectedPrinterName == nil)
                }
            }

            if hasDocument {
                Text(L10n.ui("拖拽框选；框定后可拖边/角调整。长条内容可开「翻转90°打印」。切纸前走纸控制切刀位置。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            if hasDocument {
                documentWorkspace
            } else {
                emptyImportDropZone
            }
        }
        .padding(12)
        .navigationTitle(L10n.ui("PDF打印"))
        .onAppear {
            feedLinesBeforeCut = max(0, min(40, config.feedLinesBeforeCut))
        }
        .onChange(of: selection) { _, _ in refreshCropPreview() }
        .onChange(of: rotate90) { _, _ in refreshCropPreview() }
    }

    private var pageNavigationBar: some View {
        HStack(spacing: 6) {
            Button {
                goToPage(pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(pageIndex <= 0)

            Text("\(L10n.ui("第")) \(pageIndex + 1) / \(max(pageCount, 1)) \(L10n.ui("页"))")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 88)

            Button {
                goToPage(pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(pageIndex >= pageCount - 1)
        }
        .disabled(pageCount <= 1)
    }

    private func goToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        let idx = min(max(0, index), pageCount - 1)
        guard idx != pageIndex || pageImage == nil else { return }
        pageIndex = idx
        reloadCurrentPage(clearSelection: true)
    }

    private var emptyImportDropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L10n.ui("导入 PDF 开始打印"))
                .font(.title3.weight(.medium))
            Text(L10n.ui("点击下方按钮，或将 PDF 拖到此处"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.ui("导入 PDF…")) { importPDF() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isDropTargeted ? 0.9 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 1.5, dash: [8, 6])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var documentWorkspace: some View {
        HStack(alignment: .top, spacing: 12) {
            if let pageImage {
                PDFPrintSelectRepresentable(
                    image: pageImage,
                    selection: $selection
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.ui("选区预览")).font(.headline)
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200)
                        .background(Color.white)
                        .border(Color.secondary.opacity(0.4))
                    if rotate90 {
                        Text(L10n.ui("预览已按 90° 旋转"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.ui("尚未框选"))
                        .foregroundStyle(.secondary)
                        .frame(width: 200, height: 120)
                }

                Group {
                    Text(L10n.ui("切纸位置")).font(.headline)
                    Stepper(
                        "\(L10n.ui("切纸前走纸")) \(feedLinesBeforeCut) \(L10n.ui("行"))",
                        value: $feedLinesBeforeCut,
                        in: 0...40
                    )
                    Button(L10n.ui("恢复默认")) {
                        feedLinesBeforeCut = max(0, min(40, config.feedLinesBeforeCut))
                    }
                    .controlSize(.small)
                    Text(L10n.ui("打印结束后再走纸再切刀；越小越省纸，过小可能裁到内容。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("\(L10n.ui("打印宽度")) \(config.paperWidthMM)mm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if appState.settings.selectedPrinterName == nil {
                    Text(L10n.ui("请先在设置中选择打印机"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .frame(width: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPDF(from: url)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, url.pathExtension.lowercased() == "pdf" else {
                DispatchQueue.main.async { message = L10n.ui("请拖入 PDF 文件") }
                return
            }
            DispatchQueue.main.async { loadPDF(from: url) }
        }
        return true
    }

    private func loadPDF(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            message = L10n.ui("无法打开 PDF")
            return
        }
        pdfURL = url
        pdfDocument = doc
        pageIndex = 0
        selection = nil
        previewImage = nil
        reloadCurrentPage(clearSelection: true)
        let pages = doc.pageCount
        message = pages > 1
            ? "\(L10n.ui("已加载")) \(url.lastPathComponent)\(L10n.ui("（共")) \(pages) \(L10n.ui("页）。可用翻页按钮切换。"))"
            : "\(L10n.ui("已加载")) \(url.lastPathComponent)\(L10n.ui("。可框选、自动寻找边界或整页打印。"))"
    }

    private func reloadCurrentPage(clearSelection: Bool) {
        guard let doc = pdfDocument else { return }
        let idx = min(max(0, pageIndex), max(0, doc.pageCount - 1))
        if idx != pageIndex { pageIndex = idx }
        guard let rendered = MovieTicketPDFPageRenderer.image(
            from: doc,
            pageIndex: idx,
            maxPixelWidth: 1800
        ) else {
            message = "\(L10n.ui("无法渲染第")) \(idx + 1) \(L10n.ui("页"))"
            pageImage = nil
            return
        }
        pageImage = rendered.0
        if clearSelection {
            selection = nil
            previewImage = nil
        } else {
            refreshCropPreview()
        }
    }

    private func selectFullPage() {
        selection = CGRect(x: 0, y: 0, width: 1, height: 1)
        message = L10n.ui("已选中整页")
    }

    private func autoDetectBounds() {
        guard let pageImage else { return }
        guard let bounds = Self.detectContentBounds(in: pageImage) else {
            message = L10n.ui("未能找到明显内容边界，请手动框选")
            return
        }
        selection = bounds
        message = L10n.ui("已自动裁到内容区域")
    }

    private func refreshCropPreview() {
        guard let pageImage, let selection else {
            previewImage = nil
            return
        }
        guard var crop = Self.crop(image: pageImage, relative: selection) else {
            previewImage = nil
            return
        }
        if rotate90 {
            crop = Self.rotateImage90Clockwise(crop)
        }
        previewImage = crop
    }

    private func printCrop(relative: CGRect?) async {
        guard let pageImage, let relative else { return }
        guard var crop = Self.crop(image: pageImage, relative: relative) else {
            message = L10n.ui("裁切失败")
            return
        }
        if rotate90 {
            crop = Self.rotateImage90Clockwise(crop)
        }
        isPrinting = true
        defer { isPrinting = false }

        var printConfig = config
        printConfig.cutPaper = true
        let feed = max(0, min(40, feedLinesBeforeCut))
        // Match POSReceiptPrintComposer: white warmup + second raster init so POS-80
        // does not misread the first GS v 0 header as GBK.
        let warmup = Self.whiteStrip(width: printConfig.dotsPerLine, height: 24)
        let payload = ESCPOSBuilder(config: printConfig)
            .initializeForRaster()
            .align(.left)
            .imageBanded(warmup, maxWidth: printConfig.dotsPerLine, bandHeight: 24)
            .initializeForRaster()
            .align(.left)
            .imageBanded(crop, maxWidth: printConfig.dotsPerLine, bandHeight: 48, scaleToWidth: true)
            .cut(feedLines: feed, reassertChinese: false)
            .build()

        let pngData = crop.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        } ?? Data()

        let artifacts = PrintArtifacts(
            sourceText: "PDF print \(pdfURL?.lastPathComponent ?? "") p\(pageIndex + 1)"
                + (rotate90 ? " rot90" : ""),
            attributedRTFD: nil,
            pngData: pngData,
            rasterData: Data(),
            payload: payload,
            imagePixelWidth: Int(crop.size.width.rounded()),
            imagePixelHeight: Int(crop.size.height.rounded()),
            rasterWidthBytes: 0,
            rasterHeight: 0,
            headerXL: 0,
            headerXH: 0,
            headerYL: 0,
            headerYH: 0,
            expectedRasterBytes: 0,
            renderMode: .raster,
            usedNativeText: false,
            usedRaster: true,
            dpi: 203,
            printableWidthDots: printConfig.dotsPerLine,
            printerModelHint: "PDF region print \(printConfig.paperWidthMM)mm"
                + (rotate90 ? " rot90" : "")
        )

        if let record = await appState.runDiagnosticPrint(
            artifacts: artifacts,
            statusPollingWasActive: false
        ) {
            message = record.transportError == nil ? L10n.ui("已发送到打印机") : "\(L10n.ui("打印失败："))\(record.transportError ?? "")"
        }
    }

    private static func whiteStrip(width: Int, height: Int) -> NSImage {
        let w = max(8, width)
        let h = max(8, height)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
    }

    /// Clockwise 90° — long horizontal strips become tall for better receipt-width fit.
    static func rotateImage90Clockwise(_ image: NSImage) -> NSImage {
        let src = image.size
        let outSize = NSSize(width: max(1, src.height), height: max(1, src.width))
        let out = NSImage(size: outSize)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(origin: .zero, size: outSize).fill()
        // AppKit rotates CCW for positive degrees; -90° = clockwise.
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: outSize.height)
        transform.rotate(byDegrees: -90)
        transform.concat()
        image.draw(
            in: NSRect(origin: .zero, size: src),
            from: NSRect(origin: .zero, size: src),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        out.unlockFocus()
        return out
    }

    /// Top-left relative selection → crop via NSImage bottom-left `from` (PDFKit thumbnail).
    static func crop(image: NSImage, relative: CGRect) -> NSImage? {
        let rel = clampRelative(relative)
        let srcSize = image.size
        guard srcSize.width > 1, srcSize.height > 1 else { return nil }
        let outSize = NSSize(
            width: max(1, (srcSize.width * rel.width).rounded(.down)),
            height: max(1, (srcSize.height * rel.height).rounded(.down))
        )
        let from = NSRect(
            x: srcSize.width * rel.minX,
            y: srcSize.height * (1 - rel.maxY),
            width: srcSize.width * rel.width,
            height: srcSize.height * rel.height
        )
        let out = NSImage(size: outSize)
        out.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: outSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: outSize),
            from: from,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        out.unlockFocus()
        return out
    }

    /// Find the largest content cluster (top-left relative), ignoring sparse distant footers.
    static func detectContentBounds(in image: NSImage) -> CGRect? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.bitmapData
        else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 8, h > 8 else { return nil }
        let bpp = max(1, rep.bitsPerPixel / 8)
        let rowBytes = rep.bytesPerRow

        func luma(at x: Int, y: Int) -> Double {
            let i = y * rowBytes + x * bpp
            let r = Double(data[i])
            let g = bpp > 1 ? Double(data[i + 1]) : r
            let b = bpp > 2 ? Double(data[i + 2]) : r
            return 0.299 * r + 0.587 * g + 0.114 * b
        }

        let corners = [
            (2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3),
            (w / 2, 2), (2, h / 2), (w - 3, h / 2), (w / 2, h - 3)
        ]
        let bg = corners.map { luma(at: $0.0, y: $0.1) }.reduce(0, +) / Double(corners.count)
        let threshold = 28.0

        func isInk(_ x: Int, _ y: Int) -> Bool {
            abs(luma(at: x, y: y) - bg) >= threshold
        }

        var rowInk = [Bool](repeating: false, count: h)
        let step = max(1, min(w, h) / 400)
        for y in stride(from: 0, to: h, by: step) {
            var count = 0
            for x in stride(from: 0, to: w, by: step) where isInk(x, y) {
                count += 1
            }
            rowInk[y] = count >= 2
        }

        let inkYs = Array(stride(from: 0, to: h, by: step)).filter { rowInk[$0] }
        guard let globalTop = inkYs.first else { return nil }

        // Split ink rows into vertical clusters at large empty gaps.
        let splitGap = max(step * 10, h / 20)
        var vRanges: [(top: Int, bottom: Int)] = []
        var runTop = globalTop
        var runBottom = globalTop
        for y in inkYs.dropFirst() {
            if y - runBottom > splitGap {
                vRanges.append((runTop, runBottom))
                runTop = y
                runBottom = y
            } else {
                runBottom = y
            }
        }
        vRanges.append((runTop, runBottom))

        // Split horizontally within each band; pick largest content block by area.
        let hSplitGap = max(step * 10, w / 20)
        struct ContentCluster {
            var left: Int
            var top: Int
            var right: Int
            var bottom: Int
            var ink: Int
            var area: Int { max(1, (right - left + 1) * (bottom - top + 1)) }
            var score: Int { area * 10 + ink }
        }
        var clusters: [ContentCluster] = []
        for vr in vRanges {
            var colHas = [Bool](repeating: false, count: w)
            for y in stride(from: vr.top, through: vr.bottom, by: step) {
                for x in stride(from: 0, to: w, by: step) where isInk(x, y) {
                    colHas[x] = true
                }
            }
            let inkXs = Array(stride(from: 0, to: w, by: step)).filter { colHas[$0] }
            guard let firstX = inkXs.first else { continue }
            var cLeft = firstX
            var cRight = firstX
            func flushH() {
                var t = vr.bottom
                var b = vr.top
                var ink = 0
                for y in stride(from: vr.top, through: vr.bottom, by: step) {
                    var row = 0
                    for x in stride(from: cLeft, through: cRight, by: step) where isInk(x, y) {
                        row += 1
                    }
                    if row >= 1 {
                        t = min(t, y)
                        b = max(b, y)
                        ink += row
                    }
                }
                guard b >= t else { return }
                clusters.append(ContentCluster(left: cLeft, top: t, right: cRight, bottom: b, ink: ink))
            }
            for x in inkXs.dropFirst() {
                if x - cRight > hSplitGap {
                    flushH()
                    cLeft = x
                    cRight = x
                } else {
                    cRight = x
                }
            }
            flushH()
        }

        guard let best = clusters.max(by: { $0.score < $1.score }) else { return nil }

        let pad = max(4, min(w, h) / 80)
        let x0 = max(0, best.left - pad)
        let y0 = max(0, best.top - pad)
        let x1 = min(w - 1, best.right + pad)
        let y1 = min(h - 1, best.bottom + pad)
        let rw = CGFloat(x1 - x0 + 1) / CGFloat(w)
        let rh = CGFloat(y1 - y0 + 1) / CGFloat(h)
        if rw > 0.97 && rh > 0.97 { return nil }
        if rw < 0.05 || rh < 0.05 { return nil }

        return clampRelative(CGRect(
            x: CGFloat(x0) / CGFloat(w),
            y: CGFloat(y0) / CGFloat(h),
            width: rw,
            height: rh
        ))
    }

    fileprivate static func clampRelative(_ relative: CGRect) -> CGRect {
        let x = min(max(0, relative.origin.x), 1)
        let y = min(max(0, relative.origin.y), 1)
        var w = min(max(0.01, relative.size.width), 1)
        var h = min(max(0.01, relative.size.height), 1)
        if x + w > 1 { w = 1 - x }
        if y + h > 1 { h = 1 - y }
        return CGRect(x: x, y: y, width: max(0.01, w), height: max(0.01, h))
    }
}

// MARK: - Free rubber-band + resize handles (top-left relative)

private struct PDFPrintSelectRepresentable: NSViewRepresentable {
    let image: NSImage
    @Binding var selection: CGRect?

    func makeNSView(context: Context) -> PDFPrintSelectNSView {
        let view = PDFPrintSelectNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PDFPrintSelectNSView, context: Context) {
        apply(to: nsView)
        nsView.needsDisplay = true
    }

    private func apply(to view: PDFPrintSelectNSView) {
        view.image = image
        if !view.isDragging {
            view.selection = selection
        }
        view.onSelectionChange = { selection = $0 }
    }
}

private final class PDFPrintSelectNSView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var selection: CGRect? { didSet { needsDisplay = true } }
    var onSelectionChange: ((CGRect?) -> Void)?
    var isDragging: Bool { dragSession != nil }

    private var dragSession: DragSession?
    private enum DragSession {
        case create(start: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(handle: ResizeHandle, start: CGPoint, original: CGRect)
    }

    private enum ResizeHandle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w

        var cursor: NSCursor {
            switch self {
            case .n, .s: return .resizeUpDown
            case .e, .w: return .resizeLeftRight
            case .nw, .se: return .crosshair
            case .ne, .sw: return .crosshair
            }
        }
    }

    private let handleSize: CGFloat = 8

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var contentRect: CGRect {
        guard let image else { return bounds }
        return MovieTicketPDFGeometry.aspectFitContentRect(imageSize: image.size, in: bounds)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
        guard let sel = selection else { return }
        let abs = absoluteRect(fromRelative: sel, in: contentRect)
        addCursorRect(abs.insetBy(dx: handleSize, dy: handleSize), cursor: .openHand)
        for handle in ResizeHandle.allCases {
            addCursorRect(handleRect(handle, in: abs), cursor: handle.cursor)
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
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        if let sel = selection {
            let abs = absoluteRect(fromRelative: sel, in: content)
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSRect(x: content.minX, y: content.minY, width: content.width, height: max(0, abs.minY - content.minY)).fill()
            NSRect(x: content.minX, y: abs.maxY, width: content.width, height: max(0, content.maxY - abs.maxY)).fill()
            NSRect(x: content.minX, y: abs.minY, width: max(0, abs.minX - content.minX), height: abs.height).fill()
            NSRect(x: abs.maxX, y: abs.minY, width: max(0, content.maxX - abs.maxX), height: abs.height).fill()

            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            abs.fill()
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath(rect: abs)
            path.lineWidth = 2
            path.stroke()

            let label = L10n.ui("打印选区")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.9)
            ]
            (label as NSString).draw(
                at: CGPoint(x: abs.minX, y: max(content.minY, abs.minY - 14)),
                withAttributes: attrs
            )

            // Resize handles
            NSColor.white.setFill()
            NSColor.systemOrange.setStroke()
            for handle in ResizeHandle.allCases {
                let hr = handleRect(handle, in: abs)
                let hp = NSBezierPath(rect: hr)
                hp.lineWidth = 1.5
                hp.fill()
                hp.stroke()
            }
        }
    }

    private func handleRect(_ handle: ResizeHandle, in abs: CGRect) -> CGRect {
        let s = handleSize
        let cx = abs.midX - s / 2
        let cy = abs.midY - s / 2
        switch handle {
        case .nw: return CGRect(x: abs.minX - s / 2, y: abs.minY - s / 2, width: s, height: s)
        case .n:  return CGRect(x: cx, y: abs.minY - s / 2, width: s, height: s)
        case .ne: return CGRect(x: abs.maxX - s / 2, y: abs.minY - s / 2, width: s, height: s)
        case .e:  return CGRect(x: abs.maxX - s / 2, y: cy, width: s, height: s)
        case .se: return CGRect(x: abs.maxX - s / 2, y: abs.maxY - s / 2, width: s, height: s)
        case .s:  return CGRect(x: cx, y: abs.maxY - s / 2, width: s, height: s)
        case .sw: return CGRect(x: abs.minX - s / 2, y: abs.maxY - s / 2, width: s, height: s)
        case .w:  return CGRect(x: abs.minX - s / 2, y: cy, width: s, height: s)
        }
    }

    private func hitTestHandle(at point: CGPoint, in abs: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            if handleRect(handle, in: abs).insetBy(dx: -2, dy: -2).contains(point) {
                return handle
            }
        }
        return nil
    }

    private func absoluteRect(fromRelative rel: CGRect, in content: CGRect) -> CGRect {
        CGRect(
            x: content.minX + rel.origin.x * content.width,
            y: content.minY + rel.origin.y * content.height,
            width: rel.size.width * content.width,
            height: rel.size.height * content.height
        )
    }

    private func relativePoint(fromAbsolute p: CGPoint, in content: CGRect) -> CGPoint {
        guard content.width > 0, content.height > 0 else { return .zero }
        return CGPoint(
            x: (p.x - content.minX) / content.width,
            y: (p.y - content.minY) / content.height
        )
    }

    private func clampRelative(_ r: CGRect) -> CGRect {
        PDFPrintView.clampRelative(r)
    }

    private func makeSelection(start: CGPoint, current: CGPoint) -> CGRect {
        let content = contentRect
        let a = relativePoint(fromAbsolute: start, in: content)
        let b = relativePoint(fromAbsolute: current, in: content)
        let x0 = min(max(0, min(a.x, b.x)), 1)
        let x1 = min(max(0, max(a.x, b.x)), 1)
        let y0 = min(max(0, min(a.y, b.y)), 1)
        let y1 = min(max(0, max(a.y, b.y)), 1)
        return clampRelative(CGRect(x: x0, y: y0, width: max(0.01, x1 - x0), height: max(0.01, y1 - y0)))
    }

    private func resizedSelection(
        handle: ResizeHandle,
        original: CGRect,
        start: CGPoint,
        current: CGPoint
    ) -> CGRect {
        let content = contentRect
        guard content.width > 0, content.height > 0 else { return original }
        let dx = (current.x - start.x) / content.width
        let dy = (current.y - start.y) / content.height
        var minX = original.minX
        var minY = original.minY
        var maxX = original.maxX
        var maxY = original.maxY
        switch handle {
        case .nw: minX += dx; minY += dy
        case .n:  minY += dy
        case .ne: maxX += dx; minY += dy
        case .e:  maxX += dx
        case .se: maxX += dx; maxY += dy
        case .s:  maxY += dy
        case .sw: minX += dx; maxY += dy
        case .w:  minX += dx
        }
        // Keep min < max with a minimum size.
        if maxX - minX < 0.02 {
            if handle == .w || handle == .nw || handle == .sw { minX = maxX - 0.02 }
            else { maxX = minX + 0.02 }
        }
        if maxY - minY < 0.02 {
            if handle == .n || handle == .nw || handle == .ne { minY = maxY - 0.02 }
            else { maxY = minY + 0.02 }
        }
        return clampRelative(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let sel = selection {
            let abs = absoluteRect(fromRelative: sel, in: contentRect)
            if let handle = hitTestHandle(at: p, in: abs) {
                dragSession = .resize(handle: handle, start: p, original: sel)
                needsDisplay = true
                return
            }
            if abs.insetBy(dx: -2, dy: -2).contains(p) {
                dragSession = .move(start: p, original: sel)
                NSCursor.closedHand.set()
                needsDisplay = true
                return
            }
        }
        dragSession = .create(start: p)
        selection = makeSelection(start: p, current: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragSession {
        case .create(let start):
            selection = makeSelection(start: start, current: p)
        case .move(let start, let original):
            let content = contentRect
            guard content.width > 0, content.height > 0 else { return }
            let dx = (p.x - start.x) / content.width
            let dy = (p.y - start.y) / content.height
            var moved = original
            moved.origin.x += dx
            moved.origin.y += dy
            selection = clampRelative(moved)
        case .resize(let handle, let start, let original):
            selection = resizedSelection(handle: handle, original: original, start: start, current: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragSession = nil
        onSelectionChange?(selection)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
