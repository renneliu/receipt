import SwiftUI

struct CinemaRuleEditorView: View {
    @EnvironmentObject private var appState: AppState
    @State var rule: CinemaRule
    let onSave: (CinemaRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sendersText = ""
    @State private var subjectText = ""
    @State private var bodyText = ""
    @State private var sampleEmail = ""
    @State private var testResults: [(String, String?)] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    basicInfoSection
                    matchRulesSection
                    extractorsSection
                    sampleTestSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("编辑规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveRule() }
                }
            }
            .onAppear {
                sendersText = rule.matchRules.senders.joined(separator: ", ")
                subjectText = rule.matchRules.subjectContains.joined(separator: ", ")
                bodyText = rule.matchRules.bodyContains.joined(separator: ", ")
                if rule.fieldExtractors.isEmpty { addDefaultExtractors() }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 720, idealHeight: 820)
    }

    private var basicInfoSection: some View {
        GroupBox("基本信息") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("影院名称", text: $rule.cinemaName)
                    .textFieldStyle(.roundedBorder)
                Toggle("启用", isOn: $rule.enabled)
                Picker("绑定模板", selection: $rule.templateId) {
                    ForEach(appState.templates) { t in
                        Text(t.name).tag(t.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var matchRulesSection: some View {
        GroupBox("匹配条件") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("发件人", placeholder: "逗号分隔，支持 @domain.com", text: $sendersText)
                labeledField("主题包含", placeholder: "逗号分隔关键词", text: $subjectText)
                labeledField("正文包含", placeholder: "逗号分隔关键词", text: $bodyText)
                Text("留空表示不限制该条件。建议至少填写发件人或主题关键词，避免匹配所有邮件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var extractorsSection: some View {
        GroupBox("字段提取正则") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rule.fieldExtractors.keys.sorted(), id: \.self) { key in
                    if let extractor = rule.fieldExtractors[key] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key).font(.caption).foregroundStyle(.secondary)
                            TextField("正则", text: binding(for: key, extractor: extractor))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Button("添加常用字段") { addDefaultExtractors() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sampleTestSection: some View {
        GroupBox("样本邮件测试") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $sampleEmail)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                Button("测试提取") { runTest() }
                ForEach(testResults, id: \.0) { key, value in
                    HStack {
                        Text(key).font(.caption)
                        Spacer()
                        Text(value ?? "—")
                            .foregroundStyle(value == nil ? .red : .primary)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func binding(for key: String, extractor: FieldExtractor) -> Binding<String> {
        Binding(
            get: { rule.fieldExtractors[key]?.pattern ?? extractor.pattern },
            set: { newValue in
                var e = rule.fieldExtractors[key] ?? extractor
                e.pattern = newValue
                rule.fieldExtractors[key] = e
            }
        )
    }

    private func addDefaultExtractors() {
        let defaults: [String: String] = [
            "movieName": #"影片[:：]\s*(.+?)(?:\n|<)"#,
            "showTime": #"场次[:：]\s*(.+?)(?:\n|<)"#,
            "seats": #"座位[:：]\s*(.+?)(?:\n|<)"#,
            "orderNo": #"订单号[:：]\s*(\w+)"#,
            "cinemaName": #"影城[:：]\s*(.+?)(?:\n|<)"#,
            "hall": #"影厅[:：]\s*(.+?)(?:\n|<)"#,
            "total": #"合计[:：]\s*¥?([\d.]+)"#,
            "qrContent": #"(https?://[^\s"<>]+)"#
        ]
        for (k, v) in defaults where rule.fieldExtractors[k] == nil {
            rule.fieldExtractors[k] = FieldExtractor(pattern: v, source: k == "qrContent" ? .html : .plainText)
        }
    }

    private func runTest() {
        let plain = EmailParserService.plainText(from: sampleEmail)
        let html = sampleEmail.contains("<") ? sampleEmail : plain
        if let template = appState.templates.first(where: { $0.id == rule.templateId }),
           MovieTicketData.isMovieTicketTemplate(template),
           let parsed = OrpheumEmailParser.parse(plainText: plain, html: html, subject: rule.cinemaName) {
            testResults = OrderPrintData.editableKeys(for: PendingOrder(
                messageId: "", ruleId: rule.id, ruleName: rule.cinemaName, templateId: rule.templateId,
                cinemaName: rule.cinemaName, subject: "", sender: "", receivedAt: Date(), fields: parsed
            ), templates: appState.templates).map { key in
                (key, parsed[key])
            }
            return
        }
        let (fields, missing) = EmailParserService.extractFields(rule: rule, plainText: plain, html: html)
        testResults = rule.fieldExtractors.keys.sorted().map { key in
            if missing.contains(key) { return (key, nil) }
            return (key, fields[key])
        }
    }

    private func saveRule() {
        rule.matchRules.senders = sendersText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        rule.matchRules.subjectContains = subjectText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        rule.matchRules.bodyContains = bodyText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        rule.updatedAt = Date()
        onSave(rule)
        dismiss()
    }
}
