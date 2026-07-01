import SwiftUI
import UniformTypeIdentifiers

struct ImportReceiptView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isProcessing = false
    @State private var step = ""
    @State private var selectedImage: NSImage?
    @State private var result: ImportReceiptResult?

    var body: some View {
        Group {
            if let result {
                RecognitionPreviewView(result: result) { template in
                    appState.saveTemplate(template)
                    appState.designerTemplate = template
                    appState.selectedSidebarItem = .designer
                } onRetry: {
                    self.result = nil
                }
            } else {
                uploadView
            }
        }
        .navigationTitle("照片识别")
    }

    private var uploadView: some View {
        VStack(spacing: 20) {
            if isProcessing {
                ProgressView(step)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("上传小票照片，自动识别版式并生成模板")
                    .foregroundStyle(.secondary)
                Button("选择图片") { pickImage() }
                Text("支持 JPG / PNG / HEIC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let img = selectedImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        selectedImage = image
        process(image)
    }

    private func process(_ image: NSImage) {
        isProcessing = true
        step = "预处理中..."
        Task {
            do {
                step = "OCR 识别中..."
                let (observations, processed) = try await ReceiptScannerService.scan(image: image)
                step = "生成模板..."
                let template = TemplateInferrer.buildTemplate(from: observations, name: "识别模板 \(Date().formatted(date: .numeric, time: .omitted))")
                await MainActor.run {
                    result = ImportReceiptResult(template: template, observations: observations, sourceImage: processed)
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    appState.lastError = error.localizedDescription
                    isProcessing = false
                }
            }
        }
    }
}
