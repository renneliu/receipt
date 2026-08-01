import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct ReceiptPrinterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 1200, minHeight: 720)
                .onAppear {
                    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
                       let icon = NSImage(contentsOf: url) {
                        NSApp.applicationIconImage = icon
                    }
                    appState.bootstrap()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.handleAppWillTerminate()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

extension Notification.Name {
    static let receiptPrinterPersistWorkingDrafts = Notification.Name("ReceiptPrinter.persistWorkingDrafts")
    static let receiptPrinterClearWorkingContent = Notification.Name("ReceiptPrinter.clearWorkingContent")
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings = AppSettings.load()
    @Published var templates: [ReceiptTemplate] = []
    @Published var selectedSidebarItem: SidebarItem = .quickPrint
    @Published var designerTemplate: ReceiptTemplate?
    @Published var importResult: ImportReceiptResult?
    @Published var lastError: String?
    @Published var diagnosticRecords: [PrintDiagnosticRecord] = []
    @Published var isPrinting = false
    /// Settings editor drafts report dirtiness so MainView can prompt on leave.
    @Published var settingsHasUnsavedChanges = false
    let settingsDraftStore = SettingsDraftStore()

    let printService = CUPSPrintService()
    let printController = PrintController()
    let diagnosticStore = PrintDiagnosticStore()
    let templateStore = TemplateStore()
    let notificationService = NotificationService()

    func bootstrap() {
        KeychainHelper.abandonLegacyKeychainItems()
        if !settings.retainWorkingContentOnQuit {
            WorkingContentDrafts.clearAll()
        }
        templates = templateStore.loadAll()
        diagnosticRecords = diagnosticStore.loadAll()
        notificationService.requestAuthorization()
        L10n.current = settings.appLanguage
        selectedSidebarItem = settings.defaultStartupPage
    }

    /// Called before process exit: either flush POS cart or wipe working drafts.
    func handleAppWillTerminate() {
        if settings.retainWorkingContentOnQuit {
            NotificationCenter.default.post(name: .receiptPrinterPersistWorkingDrafts, object: nil)
        } else {
            WorkingContentDrafts.clearAll()
            NotificationCenter.default.post(name: .receiptPrinterClearWorkingContent, object: nil)
        }
    }

    func reloadTemplates() {
        templates = templateStore.loadAll()
    }

    func saveTemplate(_ template: ReceiptTemplate) {
        templateStore.save(template)
        reloadTemplates()
    }

    func deleteTemplate(_ template: ReceiptTemplate) {
        templateStore.delete(template)
        reloadTemplates()
    }

    func printTemplate(_ template: ReceiptTemplate, data: [String: String]) async {
        guard let printer = settings.selectedPrinterName, !printer.isEmpty else {
            lastError = L10n.ui("请先在设置中选择打印机")
            return
        }
        let escpos = TemplateRenderer.renderESCPOS(template: template, data: data, config: settings.printerConfig)
        let config = PrintController.Config(
            printerName: printer,
            connectionType: "USB raw via CUPS `lp`",
            statusPollingWasActive: false,
            clearStuckJobsFirst: false
        )
        let record = await printController.printRawOnce(
            config: config,
            payload: escpos,
            sourceLabel: "template:\(template.name)",
            renderMode: .raster
        )
        ingest(record)
        if let err = record.transportError { lastError = err }
    }

    // MARK: - Diagnostics

    /// Off-main render + serialized single transmission, then publish the record on main.
    func runDiagnosticPrint(artifacts: PrintArtifacts, statusPollingWasActive: Bool) async -> PrintDiagnosticRecord? {
        guard let printer = settings.selectedPrinterName, !printer.isEmpty else {
            lastError = L10n.ui("请先在设置中选择打印机")
            return nil
        }
        isPrinting = true
        defer { isPrinting = false }
        let config = PrintController.Config(
            printerName: printer,
            connectionType: "USB raw via CUPS `lp`",
            statusPollingWasActive: statusPollingWasActive,
            clearStuckJobsFirst: false
        )
        let record = await printController.printOnce(config: config, artifacts: artifacts)
        ingest(record)
        if let err = record.transportError { lastError = err }
        return record
    }

    func ingest(_ record: PrintDiagnosticRecord) {
        diagnosticRecords.removeAll { $0.id == record.id }
        diagnosticRecords.insert(record, at: 0)
    }

    func reloadDiagnostics() {
        diagnosticRecords = diagnosticStore.loadAll()
    }

    func markDiagnosticResult(id: String, result: PrintResultLabel, note: String? = nil) {
        guard var record = diagnosticRecords.first(where: { $0.id == id }) else { return }
        record.result = result
        if let note { record.note = note }
        diagnosticStore.upsert(record)
        diagnosticStore.writeMetadata(record)
        ingest(record)
    }

    func deleteDiagnostic(id: String) {
        diagnosticStore.delete(id: id)
        diagnosticRecords.removeAll { $0.id == id }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case quickPrint
    case spreadsheetSequence
    case posReceipt
    case templatePrint
    case pdfPrint
    /// Kept for deep-links / migration; hidden from sidebar.
    case templates
    case designer
    case diagnostics
    case settings

    var id: String { rawValue }

    /// Sidebar entries (legacy template designer folded into 影票打印).
    static var sidebarItems: [SidebarItem] {
        allCases.filter {
            switch $0 {
            case .templates, .designer:
                return false
            default:
                return true
            }
        }
    }

    /// Pages offered as “default on launch” (exclude Settings).
    static var startupPageChoices: [SidebarItem] {
        sidebarItems.filter { $0 != .settings }
    }

    func title(_ language: AppLanguage) -> String {
        L10n.t("nav.\(rawValue)", language)
    }

    static func fromPersisted(_ raw: String) -> SidebarItem {
        if let item = SidebarItem(rawValue: raw) { return item }
        return fromLegacyTitle(raw) ?? .quickPrint
    }

    static func fromLegacyTitle(_ title: String) -> SidebarItem? {
        switch title {
        case "快速打印": return .quickPrint
        case "Excel表格序列打印": return .spreadsheetSequence
        case "POS小票打印": return .posReceipt
        case "影票打印": return .templatePrint
        case "PDF打印": return .pdfPrint
        case "模板管理": return .templates
        case "模板设计": return .designer
        case "邮件抓取规则", "订单收件箱", "影院规则", "Gmail":
            // Removed Gmail / email pipeline — map old defaults to Quick Print.
            return .quickPrint
        case "打印诊断": return .diagnostics
        case "设置": return .settings
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .quickPrint: return "printer"
        case .spreadsheetSequence: return "tablecells"
        case .posReceipt: return "cart"
        case .templatePrint: return "ticket"
        case .pdfPrint: return "doc.viewfinder"
        case .templates: return "doc.text"
        case .designer: return "pencil.and.outline"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

struct ImportReceiptResult {
    let template: ReceiptTemplate
    let observations: [RecognizedBlock]
    let sourceImage: NSImage
}
