import SwiftUI

struct GmailSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isConnecting = false

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
                Button("立即同步") {
                    Task { await appState.syncGmailNow() }
                }
                .disabled(!appState.gmailAuth.isAuthenticated)
            }

            Section("配置说明") {
                Text("请先在「设置」中填写 Google Cloud OAuth Client ID 和 Secret，并启用 Gmail API。测试阶段请将你的 Google 账号添加为 OAuth 测试用户。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Gmail")
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
