import SwiftUI

struct OrderDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State var order: PendingOrder
    @Environment(\.dismiss) private var dismiss
    @State private var isPrinting = false

    private var template: ReceiptTemplate? {
        appState.templates.first { $0.id == order.templateId }
    }

    private var mergedData: [String: String] {
        var data = order.fields
        for (k, v) in order.manualFields { data[k] = v }
        return data
    }

    var body: some View {
        HSplitView {
            Form {
                Section("邮件信息") {
                    LabeledContent("主题", value: order.subject)
                    LabeledContent("发件人", value: order.sender)
                    LabeledContent("规则", value: order.ruleName)
                }
                Section("提取字段") {
                    ForEach(sortedFieldKeys, id: \.self) { key in
                        HStack {
                            Text(key)
                                .frame(width: 90, alignment: .leading)
                            TextField("", text: Binding(
                                get: { order.manualFields[key] ?? order.fields[key] ?? "" },
                                set: { order.manualFields[key] = $0 }
                            ))
                            if order.missingFields.contains(key) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Section {
                    if order.status == .pending {
                        Button(isPrinting ? "打印中..." : "确认打印") {
                            Task {
                                isPrinting = true
                                await appState.confirmPrint(order: order)
                                isPrinting = false
                                dismiss()
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("忽略") {
                            appState.ignoreOrder(order)
                            dismiss()
                        }
                    }
                    Button("关闭") { dismiss() }
                }
            }
            .frame(minWidth: 320)

            VStack {
                Text("小票预览")
                    .font(.headline)
                if let template {
                    Image(nsImage: TemplateRenderer.renderPreviewImage(
                        template: template,
                        data: mergedData,
                        config: appState.settings.printerConfig
                    ))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 340)
                } else {
                    Text("找不到模板")
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sortedFieldKeys: [String] {
        let keys = Set(order.fields.keys).union(order.manualFields.keys).union(order.missingFields)
        return keys.sorted()
    }
}
