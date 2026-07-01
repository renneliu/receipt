import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var printers: [String] = []
    @State private var loadError: String?

    var body: some View {
        Form {
            if !appState.settings.hasCompletedSetup {
                Section("首次设置") {
                    Text("1. 在系统设置中添加 USB 热敏打印机（Generic 驱动）\n2. 下方选择打印机名称\n3. 可选：配置 Gmail 与影院规则")
                        .foregroundStyle(.secondary)
                    Button("我已完成打印机配置") {
                        appState.settings.hasCompletedSetup = true
                        appState.settings.save()
                    }
                }
            }

            Section("打印机") {
                Picker("CUPS 打印机", selection: Binding(
                    get: { appState.settings.selectedPrinterName ?? "" },
                    set: {
                        appState.settings.selectedPrinterName = $0.isEmpty ? nil : $0
                        appState.settings.save()
                    }
                )) {
                    Text("未选择").tag("")
                    ForEach(printers, id: \.self) { Text($0).tag($0) }
                }
                Button("刷新打印机列表") { refreshPrinters() }
                if let loadError { Text(loadError).foregroundStyle(.red).font(.caption) }
            }

            Section("纸张与编码") {
                Picker("纸宽", selection: Binding(
                    get: { appState.settings.printerConfig.paperWidthMM },
                    set: {
                        appState.settings.printerConfig.paperWidthMM = $0
                        appState.settings.printerConfig.dotsPerLine = $0 == 80 ? 576 : 384
                        appState.settings.printerConfig.columnsPerLine = $0 == 80 ? 48 : 32
                        appState.settings.save()
                    }
                )) {
                    Text("80mm").tag(80)
                    Text("58mm").tag(58)
                }
                Picker("每行字符宽度", selection: Binding(
                    get: { appState.settings.printerConfig.columnsPerLine },
                    set: {
                        appState.settings.printerConfig.columnsPerLine = $0
                        appState.settings.save()
                    }
                )) {
                    Text("32（58mm 推荐）").tag(32)
                    Text("48（80mm 推荐）").tag(48)
                }
                Picker("文本编码", selection: Binding(
                    get: { appState.settings.printerConfig.encoding },
                    set: {
                        appState.settings.printerConfig.encoding = $0
                        appState.settings.save()
                    }
                )) {
                    ForEach(PrinterConfig.TextEncoding.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("打印后切纸", isOn: Binding(
                    get: { appState.settings.printerConfig.cutPaper },
                    set: {
                        appState.settings.printerConfig.cutPaper = $0
                        appState.settings.save()
                    }
                ))
            }

            Section("Gmail OAuth") {
                TextField("Client ID", text: Binding(
                    get: { appState.settings.gmailClientID },
                    set: { appState.settings.gmailClientID = $0; appState.settings.save() }
                ))
                SecureField("Client Secret", text: Binding(
                    get: { appState.settings.gmailClientSecret },
                    set: { appState.settings.gmailClientSecret = $0; appState.settings.save() }
                ))
                TextField("Redirect URI", text: Binding(
                    get: { appState.settings.gmailRedirectURI },
                    set: { appState.settings.gmailRedirectURI = $0; appState.settings.save() }
                ))
                Stepper("同步间隔 \(Int(appState.settings.gmailSyncInterval)) 秒", value: Binding(
                    get: { appState.settings.gmailSyncInterval },
                    set: { appState.settings.gmailSyncInterval = $0; appState.settings.save() }
                ), in: 60...3600, step: 60)
                TextField("Gmail 搜索条件", text: Binding(
                    get: { appState.settings.gmailSearchQuery },
                    set: { appState.settings.gmailSearchQuery = $0; appState.settings.save() }
                ))
            }

            Section("关于") {
                LabeledContent("版本", value: AppVersion.display)
            }
        }
        .padding()
        .navigationTitle("设置")
        .onAppear { refreshPrinters() }
    }

    private func refreshPrinters() {
        do {
            printers = try appState.printService.listPrinters()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
