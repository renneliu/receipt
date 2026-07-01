import SwiftUI

struct TemplateDesignerView: View {
    @EnvironmentObject private var appState: AppState
    @State var template: ReceiptTemplate
    @State private var selectedBlockID: UUID?
    @State private var previewDataJSON: String = ""
    @State private var previewImage: NSImage?
    @State private var showPreview = false

    var body: some View {
        HSplitView {
            toolbox
            canvas
            inspector
        }
        .navigationTitle("模板设计: \(template.name)")
        .toolbar {
            ToolbarItemGroup {
                TextField("模板名称", text: $template.name)
                    .frame(width: 180)
                Button("保存") { appState.saveTemplate(template) }
                Button("预览") { updatePreview(); showPreview = true }
                Button("测试打印") { Task { await testPrint() } }
            }
        }
        .sheet(isPresented: $showPreview) {
            PrintPreviewView(template: template, previewData: parsedPreviewData())
        }
        .onAppear {
            if previewDataJSON.isEmpty {
                previewDataJSON = defaultPreviewJSON()
            }
            updatePreview()
        }
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
            if let idx = template.blocks.firstIndex(where: { $0.id == selectedBlockID }) {
                blockEditor(template.blocks[idx], index: idx)
            } else {
                Text("选择一个块进行编辑")
                    .foregroundStyle(.secondary)
            }
            Section("预览数据 JSON") {
                TextEditor(text: $previewDataJSON)
                    .frame(minHeight: 100)
                    .font(.system(.caption, design: .monospaced))
                Button("刷新预览") { updatePreview() }
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
    }

    @ViewBuilder
    private func blockEditor(_ block: TemplateBlock, index: Int) -> some View {
        Section("块属性") {
            Picker("类型", selection: Binding(
                get: { template.blocks[index].type },
                set: { template.blocks[index].type = $0 }
            )) {
                ForEach(BlockType.allCases) { Text($0.displayName).tag($0) }
            }
            if block.type == .text {
                TextField("内容", text: $template.blocks[index].content)
                Picker("对齐", selection: $template.blocks[index].align) {
                    ForEach(TextAlign.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("字号", selection: $template.blocks[index].size) {
                    ForEach(TextSize.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("加粗", isOn: $template.blocks[index].bold)
            }
            if block.type == .row {
                TextField("左侧", text: $template.blocks[index].content)
                TextField("右侧", text: $template.blocks[index].rightContent)
                TextField("右侧高亮（反白）", text: $template.blocks[index].rightHighlight)
                Picker("字号", selection: $template.blocks[index].size) {
                    ForEach(TextSize.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("左侧加粗", isOn: $template.blocks[index].bold)
            }
            if block.type == .spacer {
                Stepper("行数: \(template.blocks[index].spacerLines)", value: $template.blocks[index].spacerLines, in: 1...10)
            }
            if block.type == .barcode || block.type == .qr {
                TextField("内容/占位符", text: $template.blocks[index].content)
            }
            if block.type == .table {
                TextField("数据源键名", text: Binding(
                    get: { template.blocks[index].dataSource ?? "items" },
                    set: { template.blocks[index].dataSource = $0 }
                ))
            }
        }
    }

    private func addBlock(_ type: BlockType) {
        let block: TemplateBlock = switch type {
        case .text: .text("新文本", align: .center)
        case .line: .line()
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
        guard let data = previewDataJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return defaultPreviewData()
        }
        return dict
    }

    private func defaultPreviewData() -> [String: String] {
        if template.name.contains("Orpheum") {
            return SampleTemplates.previewDataMovieTicket
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
        appState.saveTemplate(template)
        await appState.printTemplate(template, data: parsedPreviewData())
    }
}
