import SwiftUI

struct QuickPrintView: View {
    @EnvironmentObject private var appState: AppState
    @State private var text = "Hello 测试小票\n\nReceiptPrinter 快速打印测试"
    @State private var includeQR = true
    @State private var includeBarcode = true
    @State private var isPrinting = false
    @State private var message = ""

    var body: some View {
        Form {
            Section("测试内容") {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                Toggle("包含二维码", isOn: $includeQR)
                Toggle("包含条码", isOn: $includeBarcode)
            }

            Section {
                Button(isPrinting ? "打印中..." : "打印测试页") {
                    Task { await printTest() }
                }
                .disabled(isPrinting || appState.settings.selectedPrinterName == nil)
                if !message.isEmpty {
                    Text(message).foregroundStyle(.secondary)
                }
            }

            if appState.settings.selectedPrinterName == nil {
                Section {
                    Text("请先在「设置」中选择 CUPS 打印机。")
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .navigationTitle("快速打印")
    }

    private func printTest() async {
        guard let printer = appState.settings.selectedPrinterName else { return }
        isPrinting = true
        defer { isPrinting = false }
        let builder = ESCPOSBuilder(config: appState.settings.printerConfig).initialize()
        builder.align(.center).bold(true).text("ReceiptPrinter 测试\n").bold(false).newline()
        builder.align(.left).text(text).newline(2)
        if includeBarcode {
            builder.barcode(type: .code128, content: "TEST123456")
        }
        if includeQR {
            builder.qrCodeImage("https://example.com/receipt-test")
        }
        builder.text("--- 测试完成 ---").newline()
        let data = builder.cut().build()
        do {
            try appState.printService.printRaw(printerName: printer, data: data)
            message = "已发送到打印机 \(printer)"
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}
