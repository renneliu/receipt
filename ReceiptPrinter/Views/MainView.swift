import SwiftUI

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingSidebarItem: SidebarItem?
    @State private var showSettingsSavePrompt = false

    private var language: AppLanguage { appState.settings.appLanguage }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.sidebarItems, selection: sidebarSelection) { item in
                Label(item.title(language), systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detailView
        }
        .environment(\.appLanguage, language)
        .alert(L10n.t("error.title", language), isPresented: Binding(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } }
        )) {
            Button(L10n.t("error.ok", language)) { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
        .alert(
            L10n.t("settings.unsavedTitle", language),
            isPresented: $showSettingsSavePrompt
        ) {
            Button(L10n.t("settings.saveAndLeave", language)) {
                appState.settingsDraftStore.save(into: appState)
                leaveSettings(to: pendingSidebarItem)
            }
            Button(L10n.t("settings.discardAndLeave", language), role: .destructive) {
                appState.settingsDraftStore.discard()
                appState.settingsHasUnsavedChanges = false
                leaveSettings(to: pendingSidebarItem)
            }
            Button(L10n.t("settings.cancelLeave", language), role: .cancel) {
                pendingSidebarItem = nil
            }
        } message: {
            Text(L10n.t("settings.unsavedMessage", language))
        }
        .onAppear {
            L10n.current = language
            migrateHiddenSidebarSelection()
        }
        .onChange(of: appState.settings.appLanguage) { _, newValue in
            L10n.current = newValue
        }
    }

    private var sidebarSelection: Binding<SidebarItem> {
        Binding(
            get: { appState.selectedSidebarItem },
            set: { selectSidebarItem($0) }
        )
    }

    private func selectSidebarItem(_ newValue: SidebarItem) {
        let target = isHiddenSidebarItem(newValue) ? SidebarItem.quickPrint : newValue
        let current = appState.selectedSidebarItem
        if current == .settings && target != .settings && appState.settingsHasUnsavedChanges {
            pendingSidebarItem = target
            showSettingsSavePrompt = true
            return
        }
        appState.selectedSidebarItem = target
    }

    private func leaveSettings(to item: SidebarItem?) {
        defer { pendingSidebarItem = nil }
        guard let item else { return }
        appState.selectedSidebarItem = item
    }

    private func migrateHiddenSidebarSelection() {
        if isHiddenSidebarItem(appState.selectedSidebarItem) {
            appState.selectedSidebarItem = .quickPrint
        }
    }

    private func isHiddenSidebarItem(_ item: SidebarItem) -> Bool {
        switch item {
        case .templates, .designer, .emailExtraction, .orders, .cinemaRules, .gmail:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSidebarItem {
        case .quickPrint:
            QuickPrintView()
        case .spreadsheetSequence:
            SpreadsheetSequencePrintView()
        case .posReceipt:
            POSReceiptRootView()
        case .templatePrint, .templates, .designer:
            MovieTicketRootView()
        case .pdfPrint:
            PDFPrintView()
        case .emailExtraction, .orders, .cinemaRules, .gmail:
            Text(L10n.t("common.featureRemoved", language))
                .foregroundStyle(.secondary)
        case .diagnostics:
            PrintDiagnosticView()
        case .settings:
            SettingsView()
        }
    }
}
