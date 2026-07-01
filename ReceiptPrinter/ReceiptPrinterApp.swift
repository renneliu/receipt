import SwiftUI
import UserNotifications

@main
struct ReceiptPrinterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 700)
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

    let printService = CUPSPrintService()
    let templateStore = TemplateStore()
    let cinemaRuleStore = CinemaRuleStore()
    let orderStore = OrderStore()
    let gmailAuth = GmailAuthService()
    let gmailSync: GmailSyncService
    let notificationService = NotificationService()

    init() {
        gmailSync = GmailSyncService(auth: gmailAuth)
        gmailSync.rulesProvider = { [weak self] in self?.cinemaRules ?? [] }
        gmailSync.settingsProvider = { [weak self] in self?.settings ?? AppSettings.load() }
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
        do {
            let escpos = TemplateRenderer.renderESCPOS(template: template, data: data, config: settings.printerConfig)
            try printService.printRaw(printerName: printer, data: escpos)
        } catch {
            lastError = error.localizedDescription
        }
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
        var data = order.fields
        for (key, value) in order.manualFields {
            data[key] = value
        }
        await printTemplate(template, data: data)
        var updated = order
        updated.status = .printed
        updated.printedAt = Date()
        orderStore.save(updated)
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
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case quickPrint = "快速打印"
    case templates = "模板管理"
    case designer = "模板设计"
    case importPhoto = "照片识别"
    case orders = "订单收件箱"
    case cinemaRules = "影院规则"
    case gmail = "Gmail"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .quickPrint: return "printer"
        case .templates: return "doc.text"
        case .designer: return "pencil.and.outline"
        case .importPhoto: return "photo"
        case .orders: return "tray"
        case .cinemaRules: return "film"
        case .gmail: return "envelope"
        case .settings: return "gearshape"
        }
    }
}

struct ImportReceiptResult {
    let template: ReceiptTemplate
    let observations: [RecognizedBlock]
    let sourceImage: NSImage
}
