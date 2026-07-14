import SwiftUI

struct PrintPreviewView: View {
    let template: ReceiptTemplate
    let previewData: [String: String]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack {
            Text("80mm 小票预览")
                .font(.headline)
            Image(nsImage: TemplateRenderer.renderPreviewImage(
                template: template,
                data: previewData,
                config: appState.settings.printerConfig
            ))
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 360)
            .padding()
            HStack {
                Button("关闭") { dismiss() }
                Button("打印") {
                    Task {
                        await appState.printTemplate(template, data: previewData)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 500)
    }
}

/// Bitmap-only preview (quick print / template print).
struct BitmapPrintPreviewView: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("80mm 小票预览")
                .font(.headline)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360)
                .padding()
            Button("关闭") { dismiss() }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 500)
    }
}
