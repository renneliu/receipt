import SwiftUI

struct OrderDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State var order: PendingOrder
    @Environment(\.dismiss) private var dismiss
    @State private var isPrinting = false

    private var template: ReceiptTemplate? {
        appState.templates.first { $0.id == order.templateId }
    }

    private var resolvedFields: [String: String] {
        OrderPrintData.resolvedFields(for: order, templates: appState.templates)
    }

    private var mergedData: [String: String] {
        OrderPrintData.merged(for: order, templates: appState.templates)
    }

    private var fieldKeys: [String] {
        OrderPrintData.editableKeys(for: order, templates: appState.templates)
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("邮件信息") {
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("主题", value: order.subject)
                                LabeledContent("发件人", value: order.sender)
                                LabeledContent("规则", value: order.ruleName)
                                LabeledContent("状态", value: order.status.displayName)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("票务信息（可修改）") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(fieldKeys, id: \.self) { key in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(fieldLabel(key))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if order.missingFields.contains(key) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundStyle(.orange)
                                                    .font(.caption)
                                            }
                                        }
                                        TextField("", text: binding(for: key))
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack {
                            if order.status == .pending {
                                Button(isPrinting ? "打印中..." : "确认打印") {
                                    Task {
                                        isPrinting = true
                                        appState.saveOrderEdits(order)
                                        await appState.confirmPrint(order: order)
                                        isPrinting = false
                                        dismiss()
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(isPrinting)

                                Button("忽略") {
                                    appState.ignoreOrder(order)
                                    dismiss()
                                }
                            }

                            if order.status == .printed {
                                Button(isPrinting ? "打印中..." : "再次打印") {
                                    Task {
                                        isPrinting = true
                                        appState.saveOrderEdits(order)
                                        await appState.reprintOrder(order: order)
                                        isPrinting = false
                                    }
                                }
                                .disabled(isPrinting)
                            }

                            Button("保存修改") {
                                persistReparsedFields()
                                appState.saveOrderEdits(order)
                            }

                            Button("关闭") { dismiss() }
                        }
                    }
                    .padding(16)
                }
                .frame(width: 400)

                Divider()

                ScrollView {
                    VStack(spacing: 12) {
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
                            .frame(maxWidth: 380)
                        } else {
                            Text("找不到模板")
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("订单详情")
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear {
            persistReparsedFields()
        }
    }

    private func persistReparsedFields() {
        let resolved = OrderPrintData.resolvedFields(for: order, templates: appState.templates)
        guard !resolved.isEmpty else { return }
        if order.fields.isEmpty || !OrderPrintData.isOrpheumOrder(order, templates: appState.templates) {
            order.fields = resolved
        } else if OrderPrintData.isOrpheumOrder(order, templates: appState.templates) {
            for (key, value) in resolved where (order.fields[key] ?? "").isEmpty && !value.isEmpty {
                order.fields[key] = value
            }
        }
    }

    private func fieldLabel(_ key: String) -> String {
        OrderPrintData.orpheumFieldLabels[key] ?? key
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if let manual = order.manualFields[key], !manual.isEmpty { return manual }
                if let stored = order.fields[key], !stored.isEmpty { return stored }
                return resolvedFields[key] ?? ""
            },
            set: { order.manualFields[key] = $0 }
        )
    }
}
