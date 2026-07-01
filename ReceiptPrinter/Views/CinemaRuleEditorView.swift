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
            Form {
                Section("基本信息") {
                    TextField("影院名称", text: $rule.cinemaName)
                    Toggle("启用", isOn: $rule.enabled)
                    Picker("绑定模板", selection: $rule.templateId) {
                        ForEach(appState.templates) { t in
                            Text(t.name).tag(t.id)
                        }
                    }
                }

                Section("匹配条件") {
                    TextField("发件人（逗号分隔，支持 @domain.com）", text: $sendersText)
                    TextField("主题包含（逗号分隔）", text: $subjectText)
                    TextField("正文包含（逗号分隔）", text: $bodyText)
                }

                Section("字段提取正则") {
                    ForEach(rule.fieldExtractors.keys.sorted(), id: \.self) { key in
                        if let extractor = rule.fieldExtractors[key] {
                            VStack(alignment: .leading) {
                                Text(key).font(.caption).foregroundStyle(.secondary)
                                TextField("正则", text: binding(for: key, extractor: extractor))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    Button("添加常用字段") { addDefaultExtractors() }
                }

                Section("样本邮件测试") {
                    TextEditor(text: $sampleEmail)
                        .frame(minHeight: 120)
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
        .frame(minWidth: 520, minHeight: 600)
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
    }
}
