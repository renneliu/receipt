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
        case .templates, .designer:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var detailView: some View {
        let selected = appState.selectedSidebarItem
        ZStack {
            // Keep these modules mounted so typed content / imported sheets survive sidebar switches.
            QuickPrintView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(selected == .quickPrint ? 1 : 0)
                .allowsHitTesting(selected == .quickPrint)
                .accessibilityHidden(selected != .quickPrint)
                .zIndex(selected == .quickPrint ? 1 : 0)

            SpreadsheetSequencePrintView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(selected == .spreadsheetSequence ? 1 : 0)
                .allowsHitTesting(selected == .spreadsheetSequence)
                .accessibilityHidden(selected != .spreadsheetSequence)
                .zIndex(selected == .spreadsheetSequence ? 1 : 0)

            POSReceiptRootView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(selected == .posReceipt ? 1 : 0)
                .allowsHitTesting(selected == .posReceipt)
                .accessibilityHidden(selected != .posReceipt)
                .zIndex(selected == .posReceipt ? 1 : 0)

            Group {
                switch selected {
                case .quickPrint, .spreadsheetSequence, .posReceipt:
                    EmptyView()
                case .templatePrint, .templates, .designer:
                    MovieTicketRootView()
                case .pdfPrint:
                    PDFPrintView()
                case .diagnostics:
                    PrintDiagnosticView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(isKeepAliveModule(selected) ? 0 : 2)
        }
        // Title owned by MainView so keep-alive children cannot steal navigationTitle.
        .navigationTitle(detailTitle(for: selected))
    }

    private func isKeepAliveModule(_ item: SidebarItem) -> Bool {
        item == .quickPrint || item == .spreadsheetSequence || item == .posReceipt
    }

    private func detailTitle(for item: SidebarItem) -> String {
        switch item {
        case .quickPrint: return L10n.ui("快速打印", language)
        case .spreadsheetSequence: return L10n.ui("Excel表格序列打印", language)
        case .posReceipt: return L10n.ui("POS小票打印", language)
        case .templatePrint, .templates, .designer: return L10n.ui("影票打印", language)
        case .pdfPrint: return L10n.ui("PDF打印", language)
        case .diagnostics: return L10n.ui("打印诊断", language)
        case .settings: return L10n.t("settings.title", language)
        }
    }
}
