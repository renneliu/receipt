import SwiftUI

struct MainView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $appState.selectedSidebarItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detailView
        }
        .alert("错误", isPresented: Binding(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } }
        )) {
            Button("确定") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
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
        case .templatePrint:
            TemplatePrintView()
        case .templates:
            TemplateListView()
        case .designer:
            TemplateDesignerView(template: appState.designerTemplate ?? appState.templates.first ?? ReceiptTemplate(name: "新模板"))
        case .emailExtraction:
            EmailExtractionRulesView()
        case .orders:
            OrderInboxView()
        case .cinemaRules:
            CinemaRulesView()
        case .gmail:
            GmailSettingsView()
        case .diagnostics:
            PrintDiagnosticView()
        case .settings:
            SettingsView()
        }
    }
}
