import SwiftUI

struct RecognitionPreviewView: View {
    let result: ImportReceiptResult
    let onConfirm: (ReceiptTemplate) -> Void
    let onRetry: () -> Void

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Text("原图 + 识别区域")
                    .font(.headline)
                Image(nsImage: result.sourceImage)
                    .resizable()
                    .scaledToFit()
            }
            .frame(minWidth: 300)

            List {
                Section("识别块 (\(result.observations.count))") {
                    ForEach(result.observations.indices, id: \.self) { i in
                        let obs = result.observations[i]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(obs.block.type.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(obs.confidence < 0.7 ? Color.orange.opacity(0.3) : Color.green.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(String(format: "%.0f%%", obs.confidence * 100))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(summary(obs.block))
                                .font(.body)
                        }
                    }
                }
            }
        }
        .toolbar {
            Button("重新识别", action: onRetry)
            Button("生成模板并编辑") {
                onConfirm(result.template)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func summary(_ block: TemplateBlock) -> String {
        switch block.type {
        case .text: return block.content
        case .line: return "分隔线"
        case .spacer: return "空白"
        case .barcode: return block.content
        case .qr: return block.content
        case .image: return "图片"
        case .table: return "表格"
        case .row: return "\(block.content) | \(block.rightContent)"
        }
    }
}
