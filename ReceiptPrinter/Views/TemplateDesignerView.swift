import SwiftUI

struct TemplateDesignerView: View {
    @EnvironmentObject private var appState: AppState
    @State var template: ReceiptTemplate
    @State private var selectedBlockID: UUID?
    @State private var previewDataJSON: String = ""
    @State private var previewImage: NSImage?
    @State private var showPreview = false
    @State private var movieTicket = MovieTicketData.sample
    @State private var showAdvancedJSON = false
    @State private var inspectorTab: DesignerInspectorTab = .ticket
    @State private var previewUpdateTask: Task<Void, Never>?
    private enum DesignerInspectorTab: String, CaseIterable, Identifiable {
        case ticket = "票券内容"
        case block = "块格式"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            toolbox
                .frame(width: 160)
            Divider()
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector
                .frame(width: 420)
                .frame(maxHeight: .infinity)
        }
        .navigationTitle("模板设计: \(template.name)")
        .toolbar {
            ToolbarItemGroup {
                TextField("模板名称", text: $template.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("保存") { saveTemplate() }
                Button("预览") { updatePreview(); showPreview = true }
                Button("测试打印") { Task { await testPrint() } }
            }
        }
        .sheet(isPresented: $showPreview) {
            PrintPreviewView(template: template, previewData: parsedPreviewData())
        }
        .onAppear {
            loadPreviewData()
            updatePreview()
        }
        .onDisappear {
            previewUpdateTask?.cancel()
        }
        .onChange(of: template.blocks) { _, _ in updatePreview() }
        .onChange(of: previewDataJSON) { _, _ in
            if !isMovieTicketTemplate { updatePreview() }
        }
        .onChange(of: selectedBlockID) { _, id in
            if id != nil, isMovieTicketTemplate {
                inspectorTab = .block
            }
        }
    }

    private var isMovieTicketTemplate: Bool {
        MovieTicketData.isMovieTicketTemplate(template)
    }

    private var toolbox: some View {
        List {
            Section("添加块") {
                ForEach(BlockType.allCases) { type in
                    Button(type.displayName) { addBlock(type) }
                }
            }
        }
        .frame(minWidth: 140, idealWidth: 160)
    }

    private var canvas: some View {
        VStack {
            Text("80mm 画布")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(selection: $selectedBlockID) {
                ForEach($template.blocks) { $block in
                    HStack {
                        Image(systemName: icon(for: block.type))
                        Text(summary(for: block))
                            .lineLimit(1)
                    }
                    .tag(block.id)
                }
                .onMove { from, to in template.blocks.move(fromOffsets: from, toOffset: to) }
                .onDelete { indexSet in template.blocks.remove(atOffsets: indexSet) }
            }
            if let img = previewImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300)
                    .border(Color.gray.opacity(0.3))
            }
        }
        .frame(minWidth: 320)
    }

    private var inspector: some View {
        Form {
            if isMovieTicketTemplate {
                Picker("编辑", selection: $inspectorTab) {
                    ForEach(DesignerInspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }

            if !isMovieTicketTemplate || inspectorTab == .ticket {
                if isMovieTicketTemplate {
                    MovieTicketDataEditorView(
                        data: $movieTicket,
                        templateId: template.id,
                        onFieldEdit: schedulePreviewUpdate
                    )
                }

                if isMovieTicketTemplate {
                    Toggle("显示高级 JSON", isOn: $showAdvancedJSON)
                }

                if !isMovieTicketTemplate || showAdvancedJSON {
                    Section(isMovieTicketTemplate ? "高级预览数据 JSON" : "预览数据 JSON") {
                        TextEditor(text: $previewDataJSON)
                            .frame(minHeight: 100)
                            .font(.system(.caption, design: .monospaced))
                            .disabled(isMovieTicketTemplate)
                        if isMovieTicketTemplate {
                            Text("电影票内容请在上方表单编辑，JSON 由系统自动生成")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !isMovieTicketTemplate || inspectorTab == .block {
                if let idx = template.blocks.firstIndex(where: { $0.id == selectedBlockID }) {
                    blockEditor(template.blocks[idx], index: idx)
                } else {
                    Text(isMovieTicketTemplate ? "在左侧列表选择一个块以调整排版" : "选择一个块进行编辑")
                        .foregroundStyle(.secondary)
                }
            }

            Button("刷新预览") { refreshPreviewJSON(); updatePreview() }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func blockEditor(_ block: TemplateBlock, index: Int) -> some View {
        Section("块类型") {
            Picker("类型", selection: Binding(
                get: { template.blocks[index].type },
                set: { template.blocks[index].type = $0 }
            )) {
                ForEach(BlockType.allCases) { Text($0.displayName).tag($0) }
            }
        }

        switch block.type {
        case .text:
            textBlockEditor(index: index)
        case .row:
            rowBlockEditor(index: index)
        case .line:
            lineBlockEditor(index: index)
        case .spacer:
            Section("空白") {
                Stepper("行数: \(template.blocks[index].spacerLines)", value: $template.blocks[index].spacerLines, in: 1...10)
            }
        case .barcode:
            barcodeBlockEditor(index: index)
        case .qr:
            Section("内容") {
                contentEditor(text: $template.blocks[index].content, placeholder: "{{qrContent}}")
            }
        case .table:
            Section("数据源") {
                TextField("键名", text: Binding(
                    get: { template.blocks[index].dataSource ?? "items" },
                    set: { template.blocks[index].dataSource = $0 }
                ))
            }
        case .image:
            Section("图片") {
                TextField("图片路径", text: Binding(
                    get: { template.blocks[index].imagePath ?? "" },
                    set: { template.blocks[index].imagePath = $0.isEmpty ? nil : $0 }
                ))
            }
        }

        placeholderSection()
    }

    @ViewBuilder
    private func textBlockEditor(index: Int) -> some View {
        Section("内容") {
            contentEditor(text: $template.blocks[index].content, placeholder: "输入文字，可用 {{字段名}}")
        }
        textFormatSection(
            align: $template.blocks[index].align,
            size: $template.blocks[index].size,
            bold: $template.blocks[index].bold,
            underline: $template.blocks[index].underline,
            reverse: $template.blocks[index].reverse
        )
    }

    @ViewBuilder
    private func rowBlockEditor(index: Int) -> some View {
        Section("左侧内容") {
            TextField("左侧文字", text: $template.blocks[index].content)
            textFormatSection(
                align: .constant(.left),
                size: $template.blocks[index].size,
                bold: $template.blocks[index].bold,
                underline: .constant(false),
                reverse: .constant(false),
                showAlign: false
            )
        }
        Section("右侧内容") {
            TextField("右侧文字", text: $template.blocks[index].rightContent)
            TextField("反白高亮（如影厅号）", text: $template.blocks[index].rightHighlight)
            Picker("右侧字号", selection: $template.blocks[index].rightSize) {
                ForEach(TextSize.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("右侧加粗", isOn: $template.blocks[index].rightBold)
        }
    }

    @ViewBuilder
    private func lineBlockEditor(index: Int) -> some View {
        Section("分隔线") {
            Picker("线条样式", selection: Binding(
                get: { template.blocks[index].content.isEmpty ? "-" : template.blocks[index].content },
                set: { template.blocks[index].content = $0 }
            )) {
                Text("虚线 -------").tag("-")
                Text("点线 ·······").tag("·")
                Text("等号 ======").tag("=")
            }
        }
    }

    @ViewBuilder
    private func barcodeBlockEditor(index: Int) -> some View {
        Section("内容") {
            contentEditor(text: $template.blocks[index].content, placeholder: "{{barcode}}")
        }
        Section("条码格式") {
            Picker("类型", selection: $template.blocks[index].barcodeType) {
                ForEach(BarcodeType.allCases) { Text($0.rawValue).tag($0) }
            }
            Stepper("高度: \(template.blocks[index].barcodeHeight)", value: Binding(
                get: { Int(template.blocks[index].barcodeHeight) },
                set: { template.blocks[index].barcodeHeight = UInt8(min(max($0, 40), 200)) }
            ), in: 40...200, step: 10)
            Stepper("宽度: \(template.blocks[index].barcodeWidth)", value: Binding(
                get: { Int(template.blocks[index].barcodeWidth) },
                set: { template.blocks[index].barcodeWidth = UInt8(min(max($0, 1), 6)) }
            ), in: 1...6)
            Toggle("打印下方文字", isOn: $template.blocks[index].barcodePrintHRI)
        }
    }

    @ViewBuilder
    private func textFormatSection(
        align: Binding<TextAlign>,
        size: Binding<TextSize>,
        bold: Binding<Bool>,
        underline: Binding<Bool>,
        reverse: Binding<Bool>,
        showAlign: Bool = true
    ) -> some View {
        Section("字体格式") {
            if showAlign {
                Picker("对齐", selection: align) {
                    ForEach(TextAlign.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("字号", selection: size) {
                ForEach(TextSize.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("加粗", isOn: bold)
            Toggle("下划线", isOn: underline)
            Toggle("反白（黑底白字）", isOn: reverse)
        }
    }

    @ViewBuilder
    private func contentEditor(text: Binding<String>, placeholder: String) -> some View {
        TextEditor(text: text)
            .frame(minHeight: 72)
            .font(.body)
        Text(placeholder)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func placeholderSection() -> some View {
        let keys = template.placeholders()
        if !keys.isEmpty {
            Section("可用占位符（点击插入）") {
                FlowLayout(spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        Button("{{\(key)}}") {
                            insertPlaceholder(key)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func insertPlaceholder(_ key: String) {
        guard let idx = template.blocks.firstIndex(where: { $0.id == selectedBlockID }) else { return }
        let token = "{{\(key)}}"
        switch template.blocks[idx].type {
        case .text, .barcode, .qr:
            template.blocks[idx].content += token
        case .row:
            template.blocks[idx].content += token
        default:
            break
        }
    }

    private func addBlock(_ type: BlockType) {
        let block: TemplateBlock = switch type {
        case .text: .text("新文本", align: .center)
        case .line: .line(char: "-")
        case .spacer: .spacer()
        case .image: TemplateBlock(type: .image)
        case .barcode: .barcode("{{barcode}}")
        case .qr: .qr("{{qrContent}}")
        case .table: TemplateBlock(type: .table, tableColumns: ["name", "qty", "price"], dataSource: "items")
        case .row: .row(left: "{{left}}", right: "{{right}}")
        }
        template.blocks.append(block)
        selectedBlockID = block.id
    }

    private func summary(for block: TemplateBlock) -> String {
        switch block.type {
        case .text: return block.content
        case .line: return "——— 分隔线 ———"
        case .spacer: return "空白 x\(block.spacerLines)"
        case .barcode: return "条码: \(block.content)"
        case .qr: return "二维码: \(block.content)"
        case .image: return "图片"
        case .table: return "表格 (\(block.dataSource ?? "items"))"
        case .row: return "\(block.content) | \(block.rightContent)\(block.rightHighlight.isEmpty ? "" : " [\(block.rightHighlight)]")"
        }
    }

    private func icon(for type: BlockType) -> String {
        switch type {
        case .text: "textformat"
        case .line: "minus"
        case .spacer: "space"
        case .image: "photo"
        case .barcode: "barcode"
        case .qr: "qrcode"
        case .table: "tablecells"
        case .row: "rectangle.split.2x1"
        }
    }

    private func parsedPreviewData() -> [String: String] {
        if isMovieTicketTemplate {
            return movieTicket.renderedDictionary()
        }
        guard let data = previewDataJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return defaultPreviewData()
        }
        return dict
    }

    private func loadPreviewData() {
        if isMovieTicketTemplate {
            if !template.defaultData.isEmpty {
                movieTicket = MovieTicketData.from(dictionary: template.defaultData)
            } else {
                movieTicket = MovieTicketData.from(dictionary: defaultPreviewData())
            }
            refreshPreviewJSON()
            return
        }
        if previewDataJSON.isEmpty {
            previewDataJSON = defaultPreviewJSON()
        }
    }

    private func refreshPreviewJSON() {
        guard isMovieTicketTemplate else { return }
        let rendered = movieTicket.renderedDictionary()
        if let data = try? JSONEncoder().encode(rendered),
           let str = String(data: data, encoding: .utf8) {
            previewDataJSON = prettyJSON(str) ?? str
        }
    }

    private func schedulePreviewUpdate() {
        previewUpdateTask?.cancel()
        previewUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if showAdvancedJSON { refreshPreviewJSON() }
                updatePreview()
            }
        }
    }

    private func saveTemplate() {
        if isMovieTicketTemplate {
            template.defaultData = movieTicket.storageDictionary()
        }
        appState.saveTemplate(template)
    }

    private func defaultPreviewData() -> [String: String] {
        if isMovieTicketTemplate {
            return MovieTicketData.sample.renderedDictionary()
        }
        return SampleTemplates.previewDataOrder
    }

    private func defaultPreviewJSON() -> String {
        let sample = defaultPreviewData()
        if let data = try? JSONEncoder().encode(sample),
           let str = String(data: data, encoding: .utf8) {
            return prettyJSON(str) ?? str
        }
        return "{}"
    }

    private func prettyJSON(_ str: String) -> String? {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private func updatePreview() {
        previewImage = TemplateRenderer.renderPreviewImage(
            template: template,
            data: parsedPreviewData(),
            config: appState.settings.printerConfig
        )
    }

    private func testPrint() async {
        saveTemplate()
        refreshPreviewJSON()
        updatePreview()
        await appState.printTemplate(template, data: parsedPreviewData())
    }
}
