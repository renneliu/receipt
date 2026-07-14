import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var printers: [String] = []
    @State private var loadError: String?
    @State private var draftClientID = ""
    @State private var draftClientSecret = ""
    @State private var draftRedirectURI = ""
    @State private var draftSearchQuery = ""
    @State private var draftTMDBKey = ""
    @State private var oauthSaveTask: Task<Void, Never>?

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

            Section("电影票默认值") {
                Stepper("默认广告时长 \(appState.settings.defaultAdvertisingMinutes) 分钟", value: Binding(
                    get: { appState.settings.defaultAdvertisingMinutes },
                    set: {
                        appState.settings.defaultAdvertisingMinutes = $0
                        appState.settings.save()
                    }
                ), in: 0...60)
                Text("模板打印与电影票模板将使用此默认值推算结束时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("TMDB") {
                SecureField("API Key", text: $draftTMDBKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftTMDBKey) { _, _ in
                        appState.settings.tmdbAPIKey = draftTMDBKey
                    }
                Text("用于「匹配片长」。在 themoviedb.org 申请 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gmail OAuth") {
                TextField("Client ID", text: $draftClientID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftClientID) { _, _ in scheduleSaveOAuthDrafts() }
                SecureField("Client Secret", text: $draftClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftClientSecret) { _, _ in scheduleSaveOAuthDrafts() }
                TextField("Redirect URI", text: $draftRedirectURI)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftRedirectURI) { _, _ in scheduleSaveOAuthDrafts() }
                Button("重置 Redirect URI 为默认值") {
                    draftRedirectURI = GmailOAuthConfig.defaultRedirectURI
                    scheduleSaveOAuthDrafts()
                }
                Text("Google Cloud 须创建「桌面应用」OAuth 客户端；Redirect URI 使用回环地址 \(GmailOAuthConfig.defaultRedirectURI)（无需在 Console 手动添加）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Stepper("同步间隔 \(Int(appState.settings.gmailSyncInterval)) 秒", value: Binding(
                    get: { appState.settings.gmailSyncInterval },
                    set: { appState.settings.gmailSyncInterval = $0; appState.settings.save() }
                ), in: 60...3600, step: 60)
                TextField("额外 Gmail 过滤（可选）", text: $draftSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftSearchQuery) { _, _ in scheduleSaveOAuthDrafts() }
                Text("留空表示不限制时间。同步主要依据「影院规则」中的发件人/主题/正文；此处可填可选过滤，如 is:unread 或 newer_than:90d。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.settings.gmailClientID.isEmpty {
                    Text("当前未保存 Client ID。填写后会自动保存；若 Access Token 过期，缺少 Client ID 会导致同步失败。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: AppVersion.display)
            }
        }
        .padding()
        .navigationTitle("设置")
        .onAppear {
            refreshPrinters()
            loadOAuthDrafts()
        }
        .onDisappear {
            persistOAuthDrafts()
        }
    }

    private func loadOAuthDrafts() {
        draftClientID = appState.settings.gmailClientID
        draftClientSecret = appState.settings.gmailClientSecret
        draftRedirectURI = appState.settings.gmailRedirectURI
        draftSearchQuery = appState.settings.gmailSearchQuery
        draftTMDBKey = appState.settings.tmdbAPIKey
    }

    private func scheduleSaveOAuthDrafts() {
        oauthSaveTask?.cancel()
        oauthSaveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { persistOAuthDrafts() }
        }
    }

    private func persistOAuthDrafts() {
        appState.settings.gmailClientID = draftClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.settings.gmailClientSecret = draftClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.settings.gmailRedirectURI = draftRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.settings.gmailSearchQuery = draftSearchQuery
        appState.settings.save()
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
