import SwiftUI

struct EmailExtractionRulesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSchema: EmailExtractionSchema?
    @State private var editorSchema = EmailExtractionSchema(name: "新规则")
    @State private var searchResults: [GmailMessageSummary] = []
    @State private var selectedMessageId: String?
    @State private var messageBody = ""
    @State private var selectionText = ""
    @State private var testOutput: [String: String] = [:]
    @State private var isLoading = false

    var body: some View {
        HSplitView {
            schemaList
                .frame(minWidth: 200, idealWidth: 240)
            editorPanel
                .frame(minWidth: 360)
            testPanel
                .frame(minWidth: 280)
        }
        .navigationTitle("邮件抓取规则")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建规则") { startNewSchema() }
            }
        }
        .onAppear {
            if let first = appState.extractionSchemas.first, selectedSchema == nil {
                selectedSchema = first
                loadSchema(first)
            }
        }
    }

    private var schemaList: some View {
        List(appState.extractionSchemas, selection: Binding(
            get: { selectedSchema?.id },
            set: { id in
                if let id, let schema = appState.extractionSchemas.first(where: { $0.id == id }) {
                    selectedSchema = schema
                    loadSchema(schema)
                }
            }
        )) { schema in
            VStack(alignment: .leading) {
                Text(schema.name).font(.headline)
                Text("\(schema.fields.count) 个字段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(schema.id as UUID?)
        }
    }

    private var editorPanel: some View {
        Form {
            Section("规则") {
                TextField("名称", text: $editorSchema.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Gmail 搜索（可选）", text: $editorSchema.searchQuery)
                    .textFieldStyle(.roundedBorder)
                Button(isLoading ? "搜索中..." : "搜索邮件") {
                    Task { await searchMail() }
                }
                .disabled(!appState.gmailAuth.isAuthenticated || isLoading)
            }

            Section("字段") {
                ForEach(editorSchema.fields.indices, id: \.self) { index in
                    fieldRow(at: index)
                }
                Button("从选区创建字段") { createFieldFromSelection() }
                    .disabled(selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("添加锚点字段") {
                    editorSchema.fields.append(EmailExtractionField(
                        id: "field\(editorSchema.fields.count + 1)",
                        label: "新字段",
                        strategy: .anchorBeforeAfter(before: "", after: "")
                    ))
                }
            }

            HStack {
                Button("保存") { saveSchema() }
                Button("删除", role: .destructive) { deleteSchema() }
                    .disabled(selectedSchema == nil)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func fieldRow(at index: Int) -> some View {
        let binding = $editorSchema.fields[index]
        VStack(alignment: .leading, spacing: 4) {
            TextField("字段 ID", text: binding.id)
                .textFieldStyle(.roundedBorder)
            TextField("标签", text: binding.label)
                .textFieldStyle(.roundedBorder)
            strategyEditor(field: binding)
            Text("占位符: {{gmail.\(editorSchema.fields[index].id)}}")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("测试").font(.headline)
            if !searchResults.isEmpty {
                Picker("邮件", selection: $selectedMessageId) {
                    ForEach(searchResults, id: \.id) { msg in
                        Text(String(msg.id.prefix(12))).tag(msg.id as String?)
                    }
                }
                .onChange(of: selectedMessageId) { _, id in
                    if let id { Task { await loadBody(messageId: id) } }
                }
            }
            TextEditor(text: $messageBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
            TextField("选区文本", text: $selectionText)
                .textFieldStyle(.roundedBorder)
            Button("运行提取测试") {
                testOutput = EmailExtractionEngine.extractFields(from: messageBody, schema: editorSchema)
            }
            List(Array(testOutput.keys.sorted()), id: \.self) { key in
                VStack(alignment: .leading) {
                    Text("gmail.\(key)").font(.caption).foregroundStyle(.secondary)
                    Text(testOutput[key] ?? "")
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func strategyEditor(field: Binding<EmailExtractionField>) -> some View {
        switch field.wrappedValue.strategy {
        case .anchorBeforeAfter(let before, let after):
            TextField("前文锚点", text: Binding(
                get: { before },
                set: { field.wrappedValue.strategy = .anchorBeforeAfter(before: $0, after: after) }
            ))
            TextField("后文锚点", text: Binding(
                get: { after },
                set: { field.wrappedValue.strategy = .anchorBeforeAfter(before: before, after: $0) }
            ))
        case .regex(let pattern):
            TextField("正则", text: Binding(
                get: { pattern },
                set: { field.wrappedValue.strategy = .regex(pattern: $0) }
            ))
        case .fixedValue(let value):
            TextField("固定值", text: Binding(
                get: { value },
                set: { field.wrappedValue.strategy = .fixedValue($0) }
            ))
        }
    }

    private func startNewSchema() {
        editorSchema = EmailExtractionSchema(name: "新规则 \(appState.extractionSchemas.count + 1)")
        selectedSchema = nil
    }

    private func loadSchema(_ schema: EmailExtractionSchema) {
        editorSchema = schema
    }

    private func saveSchema() {
        appState.saveExtractionSchema(editorSchema)
        selectedSchema = editorSchema
    }

    private func deleteSchema() {
        guard let schema = selectedSchema else { return }
        appState.deleteExtractionSchema(schema)
        selectedSchema = appState.extractionSchemas.first
        if let first = selectedSchema { loadSchema(first) } else { startNewSchema() }
    }

    private func createFieldFromSelection() {
        let text = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        editorSchema.fields.append(EmailExtractionField(
            id: "field\(editorSchema.fields.count + 1)",
            label: text,
            strategy: .regex(pattern: "(.*)\(NSRegularExpression.escapedPattern(for: text))(.*)")
        ))
    }

    private func searchMail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let service = GmailSearchService(auth: appState.gmailAuth)
            let trimmed = editorSchema.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = trimmed.isEmpty ? appState.settings.composedGmailExtraQuery() : trimmed
            searchResults = try await service.searchMessages(query: query.isEmpty ? "in:inbox" : query)
            selectedMessageId = searchResults.first?.id
            if let id = selectedMessageId {
                await loadBody(messageId: id)
            }
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func loadBody(messageId: String) async {
        do {
            let service = GmailSearchService(auth: appState.gmailAuth)
            messageBody = try await service.fetchPlainBody(messageId: messageId)
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}
