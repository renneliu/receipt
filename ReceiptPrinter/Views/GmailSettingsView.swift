import SwiftUI

struct GmailSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isConnecting = false
    @State private var draftFilterSender = ""
    @State private var draftFilterSubject = ""
    @State private var customStart = Date()
    @State private var customEnd = Date()

    var body: some View {
        Form {
            Section("账号状态") {
                if appState.gmailAuth.isAuthenticated {
                    Label("已连接 Gmail", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let email = appState.gmailAuth.accountEmail {
                        Text(email)
                    }
                    Button("断开连接") {
                        appState.gmailAuth.signOut()
                        appState.gmailSync.stop()
                        appState.settings.gmailSyncEnabled = false
                        appState.settings.save()
                    }
                } else {
                    Text("未连接")
                        .foregroundStyle(.secondary)
                    Button(isConnecting ? "连接中..." : "连接 Gmail") {
                        connect()
                    }
                    .disabled(isConnecting || appState.settings.gmailClientID.isEmpty)
                }
            }

            Section("时间筛选") {
                Picker("范围", selection: Binding(
                    get: { appState.settings.gmailTimeRange },
                    set: {
                        appState.settings.gmailTimeRange = $0
                        appState.settings.save()
                    }
                )) {
                    ForEach(GmailTimeRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                if appState.settings.gmailTimeRange == .custom {
                    DatePicker("开始", selection: $customStart, displayedComponents: .date)
                    DatePicker("结束", selection: $customEnd, displayedComponents: .date)
                }
                TextField("发件人包含（可选）", text: $draftFilterSender)
                    .textFieldStyle(.roundedBorder)
                TextField("主题包含（可选）", text: $draftFilterSubject)
                    .textFieldStyle(.roundedBorder)
                Button("应用筛选并同步") {
                    applyFiltersAndSync()
                }
                .disabled(!appState.gmailAuth.isAuthenticated)
            }

            Section("同步") {
                Toggle("启用自动同步", isOn: Binding(
                    get: { appState.settings.gmailSyncEnabled },
                    set: { enabled in
                        appState.settings.gmailSyncEnabled = enabled
                        appState.settings.save()
                        if enabled && appState.gmailAuth.isAuthenticated {
                            appState.gmailSync.start(interval: appState.settings.gmailSyncInterval)
                        } else {
                            appState.gmailSync.stop()
                        }
                    }
                ))
                Text(appState.gmailSyncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("合并过滤：\(appState.settings.composedGmailExtraQuery().isEmpty ? "无（不限制时间）" : appState.settings.composedGmailExtraQuery())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let preview = previewSearchQuery {
                    Text("实际 Gmail 搜索：\(preview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("立即同步") {
                    Task { await appState.syncGmailNow() }
                }
                .disabled(!appState.gmailAuth.isAuthenticated)
            }

            Section("配置说明") {
                Text(GmailOAuthConfig.googleConsoleSteps)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("当前 Redirect URI：\(appState.settings.gmailRedirectURI)")
                    .font(.caption)
                    .textSelection(.enabled)
                Text(GmailOAuthConfig.testUserAccessDeniedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .navigationTitle("Gmail")
        .onAppear { loadFilterDrafts() }
    }

    private var previewSearchQuery: String? {
        switch GmailSearchQueryBuilder.build(rules: appState.cinemaRules, settings: appState.settings) {
        case .success(let query, _): return query
        case .failure: return nil
        }
    }

    private func loadFilterDrafts() {
        draftFilterSender = appState.settings.gmailFilter.senderContains
        draftFilterSubject = appState.settings.gmailFilter.subjectContains
        customStart = appState.settings.gmailCustomStart ?? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        customEnd = appState.settings.gmailCustomEnd ?? Date()
    }

    private func applyFiltersAndSync() {
        appState.settings.gmailFilter.senderContains = draftFilterSender
        appState.settings.gmailFilter.subjectContains = draftFilterSubject
        if appState.settings.gmailTimeRange == .custom {
            appState.settings.gmailCustomStart = customStart
            appState.settings.gmailCustomEnd = customEnd
        }
        appState.settings.save()
        Task { await appState.syncGmailNow() }
    }

    private func connect() {
        isConnecting = true
        Task {
            do {
                try await appState.gmailAuth.signIn(
                    clientID: appState.settings.gmailClientID,
                    clientSecret: appState.settings.gmailClientSecret,
                    redirectURI: appState.settings.gmailRedirectURI
                )
                if appState.settings.gmailSyncEnabled {
                    appState.gmailSync.start(interval: appState.settings.gmailSyncInterval)
                }
            } catch {
                appState.lastError = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
