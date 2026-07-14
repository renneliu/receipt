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
                    appState.bootstrap()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings = AppSettings.load()
    @Published var templates: [ReceiptTemplate] = []
    @Published var cinemaRules: [CinemaRule] = []
    @Published var orders: [PendingOrder] = []
    @Published var selectedSidebarItem: SidebarItem = .quickPrint
    @Published var designerTemplate: ReceiptTemplate?
    @Published var importResult: ImportReceiptResult?
    @Published var lastError: String?
    @Published var gmailSyncStatus: String = "未同步"
    @Published var extractionSchemas: [EmailExtractionSchema] = []
    @Published var diagnosticRecords: [PrintDiagnosticRecord] = []
    @Published var isPrinting = false

    let printService = CUPSPrintService()
    let printController = PrintController()
    let diagnosticStore = PrintDiagnosticStore()
    let templateStore = TemplateStore()
    let cinemaRuleStore = CinemaRuleStore()
    let orderStore = OrderStore()
    let extractionSchemaStore = ExtractionSchemaStore()
    let gmailAuth = GmailAuthService()
    let gmailSync: GmailSyncService
    let notificationService = NotificationService()

    init() {
        gmailSync = GmailSyncService(auth: gmailAuth)
        gmailSync.rulesProvider = { [weak self] in self?.cinemaRules ?? [] }
        gmailSync.settingsProvider = { [weak self] in self?.settings ?? AppSettings.load() }
        gmailSync.templatesProvider = { [weak self] in self?.templates ?? [] }
        gmailSync.hasOrderForMessageId = { [weak self] messageId in
            self?.orderStore.hasOrder(messageId: messageId) ?? false
        }
        gmailSync.hasProcessedMessageId = { [weak self] messageId in
            self?.orderStore.hasProcessed(messageId: messageId) ?? false
        }
        gmailSync.onNewOrder = { [weak self] order in
            Task { @MainActor in
                self?.handleNewOrder(order)
            }
        }
        gmailSync.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.gmailSyncStatus = status
            }
        }
    }

    func bootstrap() {
        templates = templateStore.loadAll()
        cinemaRules = cinemaRuleStore.loadAll()
        orders = orderStore.loadAll()
        extractionSchemas = extractionSchemaStore.loadAll()
        diagnosticRecords = diagnosticStore.loadAll()
        notificationService.requestAuthorization()
        if settings.gmailSyncEnabled && gmailAuth.isAuthenticated {
            gmailSync.start(interval: settings.gmailSyncInterval)
        }
    }

    func reloadTemplates() {
        templates = templateStore.loadAll()
    }

    func reloadRules() {
        cinemaRules = cinemaRuleStore.loadAll()
    }

    func reloadOrders() {
        orders = orderStore.loadAll()
    }

    func saveTemplate(_ template: ReceiptTemplate) {
        templateStore.save(template)
        reloadTemplates()
    }

    func deleteTemplate(_ template: ReceiptTemplate) {
        templateStore.delete(template)
        reloadTemplates()
    }

    func saveRule(_ rule: CinemaRule) {
        cinemaRuleStore.save(rule)
        reloadRules()
    }

    func deleteRule(_ rule: CinemaRule) {
        cinemaRuleStore.delete(rule)
        reloadRules()
    }

    func printTemplate(_ template: ReceiptTemplate, data: [String: String]) async {
        guard let printer = settings.selectedPrinterName, !printer.isEmpty else {
            lastError = "请先在设置中选择打印机"
            return
        }
        let escpos = TemplateRenderer.renderESCPOS(template: template, data: data, config: settings.printerConfig)
        let config = PrintController.Config(
            printerName: printer,
            connectionType: "USB raw via CUPS `lp`",
            statusPollingWasActive: false,
            clearStuckJobsFirst: false
        )
        // Route through the single serialized, off-main controller (no overlap with manual/Gmail).
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
            lastError = "请先在设置中选择打印机"
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

    func handleNewOrder(_ order: PendingOrder) {
        orderStore.save(order)
        reloadOrders()
        notificationService.notifyNewOrder(order)
    }

    func confirmPrint(order: PendingOrder) async {
        guard let template = templates.first(where: { $0.id == order.templateId }) else {
            lastError = "找不到关联模板"
            return
        }
        let data = OrderPrintData.merged(for: order, templates: templates)
        await printTemplate(template, data: data)
        var updated = order
        updated.status = .printed
        updated.printedAt = Date()
        orderStore.save(updated)
        reloadOrders()
    }

    func reprintOrder(order: PendingOrder) async {
        guard let template = templates.first(where: { $0.id == order.templateId }) else {
            lastError = "找不到关联模板"
            return
        }
        let data = OrderPrintData.merged(for: order, templates: templates)
        await printTemplate(template, data: data)
        var updated = order
        updated.printedAt = Date()
        orderStore.save(updated)
        reloadOrders()
    }

    func saveOrderEdits(_ order: PendingOrder) {
        orderStore.save(order)
        reloadOrders()
    }

    func ignoreOrder(_ order: PendingOrder) {
        var updated = order
        updated.status = .ignored
        orderStore.save(updated)
        reloadOrders()
    }

    func syncGmailNow() async {
        await gmailSync.syncNow(rules: cinemaRules, settings: settings)
        reloadOrders()
    }

    func saveExtractionSchema(_ schema: EmailExtractionSchema) {
        extractionSchemaStore.save(schema)
        extractionSchemas = extractionSchemaStore.loadAll()
    }

    func deleteExtractionSchema(_ schema: EmailExtractionSchema) {
        extractionSchemaStore.delete(schema)
        extractionSchemas = extractionSchemaStore.loadAll()
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case quickPrint = "快速打印"
    case templatePrint = "模板打印"
    case templates = "模板管理"
    case designer = "模板设计"
    case emailExtraction = "邮件抓取规则"
    case orders = "订单收件箱"
    case cinemaRules = "影院规则"
    case gmail = "Gmail"
    case diagnostics = "打印诊断"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .quickPrint: return "printer"
        case .templatePrint: return "doc.richtext"
        case .templates: return "doc.text"
        case .designer: return "pencil.and.outline"
        case .emailExtraction: return "envelope.badge"
        case .orders: return "tray"
        case .cinemaRules: return "film"
        case .gmail: return "envelope"
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
