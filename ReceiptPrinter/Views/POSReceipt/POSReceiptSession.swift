import AppKit
import Combine
import Foundation
import SwiftUI

enum POSDraftField: Hashable, CaseIterable {
    case code, name, quantity, amount

    static func lastEnabled(template: POSReceiptTemplate) -> POSDraftField {
        if template.enableAmount { return .amount }
        if template.enableQuantity { return .quantity }
        return .name
    }
}

/// Shared session for POS receipt main + template panes.
@MainActor
final class POSReceiptSession: ObservableObject {
    @Published var settings: POSReceiptSettings
    @Published var templates: [POSReceiptTemplate] = []
    @Published var editingTemplate: POSReceiptTemplate?
    @Published var backgroundImage: NSImage?
    @Published var logoImages: [UUID: NSImage] = [:]
    @Published var lineItems: [POSLineItem] = []
    @Published var selectedItemId: UUID?
    /// Persists while editing a list row; not cleared when the List loses selection focus.
    @Published var editingLineItemId: UUID?
    @Published var draftCode = ""
    @Published var draftName = ""
    @Published var draftQuantity = ""
    @Published var draftAmount = ""
    @Published var surcharge = "0"
    /// Set when surcharge comes from percent shortcuts (`"10%"`); cleared on manual edit.
    @Published var surchargePercentLabel: String?
    @Published var nextAutoCode = 1
    /// After the first line item used an auto-generated code, subsequent lines prefill code and focus 项目名称.
    @Published var prefersNameFieldForNextLine = false
    @Published var message = ""
    @Published var excelRowCount: Int?
    @Published var excelCatalog: [POSExcelCatalogEntry] = []
    @Published var excelCatalogPage = 0
    @Published var printHistory: [POSPrintHistoryRecord] = []

    let store = POSReceiptTemplateStore()

    static let excelCatalogPageSize = 12

    var activeTemplate: POSReceiptTemplate? {
        guard let id = settings.activeTemplateId else { return templates.first }
        return templates.first { $0.id == id } ?? templates.first
    }

    init() {
        settings = POSReceiptSettings.load()
        reloadTemplates()
        printHistory = POSPrintHistoryStore.loadAll()
        if let t = activeTemplate {
            surcharge = t.defaultSurcharge
            surchargePercentLabel = nil
            loadImages(for: t)
            // Do NOT load Excel here: unzip uses Process.waitUntilExit and crashes
            // AttributeGraph if run during SwiftUI StateObject init/layout (crash 20:13:24).
        }
        restoreCartDraftIfAvailable()
    }

    func restoreCartDraftIfAvailable() {
        guard let draft = POSCartDraftStore.load() else { return }
        lineItems = draft.lineItems
        draftCode = draft.draftCode
        draftName = draft.draftName
        draftQuantity = draft.draftQuantity
        draftAmount = draft.draftAmount
        surcharge = draft.surcharge
        surchargePercentLabel = draft.surchargePercentLabel
        nextAutoCode = max(1, draft.nextAutoCode)
        prefersNameFieldForNextLine = draft.prefersNameFieldForNextLine
        if let id = draft.activeTemplateId, templates.contains(where: { $0.id == id }) {
            settings.activeTemplateId = id
            settings.save()
            if let t = templates.first(where: { $0.id == id }) {
                loadImages(for: t)
            }
        }
        if let editId = draft.editingLineItemId, lineItems.contains(where: { $0.id == editId }) {
            editingLineItemId = editId
            selectedItemId = editId
        }
    }

    func persistCartDraft() {
        let draft = POSCartDraft(
            lineItems: lineItems,
            draftCode: draftCode,
            draftName: draftName,
            draftQuantity: draftQuantity,
            draftAmount: draftAmount,
            surcharge: surcharge,
            surchargePercentLabel: surchargePercentLabel,
            nextAutoCode: nextAutoCode,
            prefersNameFieldForNextLine: prefersNameFieldForNextLine,
            activeTemplateId: settings.activeTemplateId,
            editingLineItemId: editingLineItemId
        )
        POSCartDraftStore.save(draft)
    }

    func clearCartDraftDisk() {
        POSCartDraftStore.clear()
    }

    func reloadTemplates() {
        templates = store.loadAll()
        if settings.activeTemplateId == nil, let first = templates.first {
            settings.activeTemplateId = first.id
            settings.save()
        }
        if let id = settings.activeTemplateId, templates.contains(where: { $0.id == id }) == false {
            settings.activeTemplateId = templates.first?.id
            settings.save()
        }
    }

    func selectTemplate(_ id: UUID) {
        settings.activeTemplateId = id
        settings.save()
        if let t = templates.first(where: { $0.id == id }) {
            surcharge = t.defaultSurcharge
            surchargePercentLabel = nil
            loadImages(for: t)
            nextAutoCode = 1
            prefersNameFieldForNextLine = false
            lineItems = []
            clearDraft()
            selectedItemId = nil
            editingLineItemId = nil
            reloadExcelCatalog(for: t)
        }
    }

    func loadImages(for template: POSReceiptTemplate) {
        if let bg = store.loadBackground(template: template) {
            backgroundImage = bg
        }
        let disk = store.loadLogoImages(template: template)
        var merged = disk
        // Keep unsaved in-memory logos still referenced by the template.
        for el in template.elements where el.kind == .logo {
            if merged[el.id] == nil, let mem = logoImages[el.id] {
                merged[el.id] = mem
            }
        }
        logoImages = merged
    }

    /// Persist a lightweight meta tweak (e.g. cut feed) without a full save dialog.
    func updateTemplateMeta(id: UUID? = nil, _ body: (inout POSReceiptTemplate) -> Void) {
        let targetId = id ?? editingTemplate?.id ?? settings.activeTemplateId
        guard let targetId else { return }
        var t: POSReceiptTemplate
        if let editing = editingTemplate, editing.id == targetId {
            t = editing
        } else if let stored = templates.first(where: { $0.id == targetId }) {
            t = stored
        } else {
            return
        }
        body(&t)
        t.touch()
        store.saveMeta(t)
        if let idx = templates.firstIndex(where: { $0.id == t.id }) {
            templates[idx] = t
        }
        if editingTemplate?.id == t.id {
            editingTemplate = t
        }
    }

    func persistEditingTemplate() {
        guard var t = editingTemplate else { return }
        // Keep name-field placeholder forced.
        if !t.hasElement(field: .name) {
            t.elements.append(POSReceiptElement(
                kind: .fieldPlaceholder,
                frame: SequencePlaceholderFrame(x: 12, y: 80, width: 200, height: 28),
                fieldKind: .name
            ))
        }
        // Sync field placeholders with toggles.
        syncFieldPlaceholders(&t)
        let logos = logoImages.map { ($0.key, $0.value) }
        // Use returned doc so logo/background filenames match files on disk.
        let saved = store.save(template: t, backgroundImage: backgroundImage, logos: logos)
        editingTemplate = saved
        reloadTemplates()
        loadImages(for: saved)
        message = L10n.ui("模板已保存")
    }

    /// Push in-memory editing fields into `templates` so 主页面 sees unsaved tweaks (e.g. 字号/宽).
    func syncEditingIntoTemplates() {
        guard let t = editingTemplate,
              let idx = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates[idx] = t
    }

    func syncFieldPlaceholders(_ t: inout POSReceiptTemplate) {
        func ensure(_ kind: POSFieldKind, enabled: Bool, defaultFrame: SequencePlaceholderFrame) {
            let idx = t.elements.firstIndex { $0.kind == .fieldPlaceholder && $0.fieldKind == kind }
            if enabled {
                if idx == nil {
                    t.elements.append(POSReceiptElement(
                        kind: .fieldPlaceholder,
                        frame: defaultFrame,
                        fieldKind: kind
                    ))
                }
            } else if let idx, kind != .name {
                t.elements.remove(at: idx)
            }
        }
        // One horizontal row: 编号 | 项目 | 数量 | 金额
        let rowY: CGFloat = t.elements.first(where: {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .name
        })?.frame.y ?? 80
        ensure(.name, enabled: true, defaultFrame: SequencePlaceholderFrame(x: 72, y: rowY, width: 150, height: 28))
        ensure(.code, enabled: t.enableCode, defaultFrame: SequencePlaceholderFrame(x: 12, y: rowY, width: 56, height: 28))
        ensure(.quantity, enabled: t.enableQuantity, defaultFrame: SequencePlaceholderFrame(x: 228, y: rowY, width: 40, height: 28))
        ensure(.amount, enabled: t.enableAmount, defaultFrame: SequencePlaceholderFrame(x: 272, y: rowY, width: 56, height: 28))
        // Keep existing line fields on the same row as 项目名称 (X preserved).
        alignLineFieldsToNameRow(&t)
    }

    /// Snap 编号/数量/金额 to 项目名称 row; pack X left→right without overlap.
    /// Widening 项目名称 steals space from 金额 → 数量 → 编号 (down to mins).
    func alignLineFieldsToNameRow(_ t: inout POSReceiptTemplate) {
        guard let nameIdx = t.elements.firstIndex(where: {
            $0.kind == .fieldPlaceholder && $0.fieldKind == .name
        }) else { return }
        let nameY = t.elements[nameIdx].frame.y
        let nameH = t.elements[nameIdx].frame.height
        let resolved = POSReceiptLayoutEngine.resolvedLineFieldWidths(template: t)

        var cursor: CGFloat = 12
        for (kind, width) in resolved {
            guard let idx = t.elements.firstIndex(where: {
                $0.kind == .fieldPlaceholder && $0.fieldKind == kind
            }) else { continue }
            t.elements[idx].frame.y = nameY
            t.elements[idx].frame.height = nameH
            t.elements[idx].frame.x = cursor
            t.elements[idx].frame.width = width
            cursor += width + 4
        }
    }

    func createTemplate(named name: String) {
        let t = POSReceiptTemplate.makeBlank(name: name)
        _ = store.save(template: t, backgroundImage: nil, logos: [])
        reloadTemplates()
        selectTemplate(t.id)
        editingTemplate = templates.first { $0.id == t.id }
        backgroundImage = nil
        logoImages = [:]
    }

    /// Deep-copy a template (meta + background/logos) under a new id; name becomes `原名(1)` (or `(2)`…).
    @discardableResult
    func duplicateTemplate(_ source: POSReceiptTemplate) -> POSReceiptTemplate {
        var bg = store.loadBackground(template: source)
        var logos = store.loadLogoImages(template: source)
        if editingTemplate?.id == source.id {
            if let memBg = backgroundImage { bg = memBg }
            for (id, img) in logoImages {
                logos[id] = img
            }
        }

        var copy = source
        copy.id = UUID()
        copy.name = uniqueDuplicateName(from: source.name)
        copy.createdAt = Date()
        copy.touch()

        let logoPairs = logos.map { ($0.key, $0.value) }
        let saved = store.save(template: copy, backgroundImage: bg, logos: logoPairs)
        reloadTemplates()
        beginEditing(saved)
        message = "已复制为「\(saved.name)」"
        return saved
    }

    private func uniqueDuplicateName(from original: String) -> String {
        let first = "\(original)(1)"
        if templates.allSatisfy({ $0.name != first }) { return first }
        var n = 2
        while templates.contains(where: { $0.name == "\(original)(\(n))" }) {
            n += 1
        }
        return "\(original)(\(n))"
    }

    func deleteTemplate(_ t: POSReceiptTemplate) {
        store.delete(t)
        if editingTemplate?.id == t.id { editingTemplate = nil }
        reloadTemplates()
        if settings.activeTemplateId == t.id {
            settings.activeTemplateId = templates.first?.id
            settings.save()
        }
        if let active = activeTemplate {
            loadImages(for: active)
        } else {
            backgroundImage = nil
            logoImages = [:]
        }
    }

    func beginEditing(_ t: POSReceiptTemplate) {
        editingTemplate = t
        loadImages(for: t)
    }

    func clearDraft() {
        draftCode = ""
        draftName = ""
        draftQuantity = ""
        draftAmount = ""
    }

    /// Prefer the in-memory editing copy when it matches the active template (has latest Excel binding).
    func templateForExcelRefresh() -> POSReceiptTemplate? {
        if let editing = editingTemplate,
           editing.id == settings.activeTemplateId || editing.id == activeTemplate?.id,
           editing.excelBookmarkData != nil {
            return editing
        }
        if let active = activeTemplate, active.excelBookmarkData != nil {
            return active
        }
        return nil
    }

    /// Re-read the bound spreadsheet off the main thread and refresh the quick-pick catalog.
    func refreshBoundExcel() async -> Bool {
        guard let source = templateForExcelRefresh(),
              let bookmark = source.excelBookmarkData else {
            message = L10n.ui("当前模板未绑定 Excel")
            return false
        }
        let templateId = source.id
        let map = source.excelColumnMap
        let fileName = source.excelDisplayName ?? L10n.ui("表格")
        message = L10n.ui("正在刷新 Excel…")
        let result = await Self.loadCatalogOffMain(bookmarkData: bookmark, map: map)
        switch result {
        case .success(let packed):
            if var updated = templates.first(where: { $0.id == templateId }) {
                updated.excelCachedHeaders = packed.headers
                store.saveMeta(updated)
                if editingTemplate?.id == templateId {
                    editingTemplate?.excelCachedHeaders = packed.headers
                }
                reloadTemplates()
            }
            excelRowCount = packed.rowCount
            excelCatalog = packed.entries
            let maxPage = max(0, (excelCatalog.count - 1) / Self.excelCatalogPageSize)
            excelCatalogPage = min(excelCatalogPage, maxPage)
            message = "Excel 已刷新：\(fileName)，\(packed.rowCount) 行 / \(packed.entries.count) 个快捷项"
            return true
        case .failure(let error):
            message = "刷新失败：\(error.localizedDescription)"
            return false
        }
    }

    func reloadExcelCatalog(for template: POSReceiptTemplate) {
        guard template.excelBookmarkData != nil else {
            excelCatalog = []
            excelCatalogPage = 0
            excelRowCount = nil
            return
        }
        let templateId = template.id
        let map = template.excelColumnMap
        let bookmark = template.excelBookmarkData
        Task {
            let result = await Self.loadCatalogOffMain(bookmarkData: bookmark, map: map)
            guard settings.activeTemplateId == templateId
                    || activeTemplate?.id == templateId
                    || editingTemplate?.id == templateId else { return }
            switch result {
            case .success(let packed):
                excelRowCount = packed.rowCount
                excelCatalog = packed.entries
                let maxPage = max(0, (excelCatalog.count - 1) / Self.excelCatalogPageSize)
                excelCatalogPage = min(excelCatalogPage, maxPage)
            case .failure(let error):
                excelCatalog = []
                excelCatalogPage = 0
                message = error.localizedDescription
            }
        }
    }

    private struct ExcelCatalogLoad: Sendable {
        var rowCount: Int
        var entries: [POSExcelCatalogEntry]
        var headers: [String]
    }

    private nonisolated static func loadCatalogOffMain(
        bookmarkData: Data?,
        map: POSExcelColumnMap
    ) async -> Result<ExcelCatalogLoad, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                guard let bookmarkData else {
                    throw POSExcelLookupError.noExcel
                }
                let resolved = try POSExcelLookupService.resolveBookmark(bookmarkData)
                let accessed = resolved.url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { resolved.url.stopAccessingSecurityScopedResource() }
                }
                let table = try SpreadsheetImportService.load(from: resolved.url)
                let entries = POSExcelLookupService.catalogEntries(table: table, map: map)
                return .success(ExcelCatalogLoad(
                    rowCount: table.rows.count,
                    entries: entries,
                    headers: table.headers
                ))
            } catch {
                return .failure(error)
            }
        }.value
    }

    var excelCatalogPageCount: Int {
        guard !excelCatalog.isEmpty else { return 1 }
        return (excelCatalog.count + Self.excelCatalogPageSize - 1) / Self.excelCatalogPageSize
    }

    var excelCatalogPageEntries: [POSExcelCatalogEntry] {
        let start = excelCatalogPage * Self.excelCatalogPageSize
        let end = min(start + Self.excelCatalogPageSize, excelCatalog.count)
        guard start < end else { return [] }
        return Array(excelCatalog[start..<end])
    }

    func applyDraft(from item: POSLineItem, template: POSReceiptTemplate) {
        if template.enableCode {
            draftCode = sanitizeCode(item.code)
        }
        draftName = item.name
        if template.enableQuantity {
            draftQuantity = item.quantity
        }
        if template.enableAmount {
            draftAmount = item.amount
        }
    }

    func beginEditingLineItem(_ item: POSLineItem, template: POSReceiptTemplate) {
        selectedItemId = item.id
        editingLineItemId = item.id
        applyDraft(from: item, template: template)
    }

    func endEditingLineItem() {
        editingLineItemId = nil
        selectedItemId = nil
    }

    func isDraftComplete(template: POSReceiptTemplate) -> Bool {
        let nameOK = !draftName.trimmingCharacters(in: .whitespaces).isEmpty
        let qtyOK = !template.enableQuantity || !draftQuantity.trimmingCharacters(in: .whitespaces).isEmpty
        let amtOK = !template.enableAmount || !draftAmount.trimmingCharacters(in: .whitespaces).isEmpty
        return nameOK && qtyOK && amtOK
    }

    func firstEmptyDraftField(template: POSReceiptTemplate) -> POSDraftField? {
        let order: [(POSDraftField, Bool, String)] = [
            (.code, template.enableCode, draftCode),
            (.name, true, draftName),
            (.quantity, template.enableQuantity, draftQuantity),
            (.amount, template.enableAmount, draftAmount)
        ]
        for (field, enabled, value) in order {
            guard enabled else { continue }
            if field == .code, !value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                return field
            }
        }
        return nil
    }

    func prepareNextLineDraft(template: POSReceiptTemplate) {
        draftName = ""
        draftQuantity = ""
        draftAmount = ""
        if template.enableCode, prefersNameFieldForNextLine {
            draftCode = "\(nextAutoCode)"
        } else if template.enableCode {
            draftCode = ""
        } else {
            draftCode = ""
        }
    }

    func applySurchargePercent(_ fraction: Double) {
        let subtotal = POSReceiptTotals.amountSubtotal(items: lineItems)
        surcharge = POSReceiptTotals.formatAmount(subtotal * fraction)
        let pct = Int((fraction * 100).rounded())
        surchargePercentLabel = "\(pct)%"
    }

    func setSurchargeManually(_ raw: String) {
        surcharge = raw
        surchargePercentLabel = nil
    }

    func clearLineItemsForNextTicket(resetSurchargeFrom template: POSReceiptTemplate?) {
        lineItems = []
        endEditingLineItem()
        clearDraft()
        nextAutoCode = 1
        prefersNameFieldForNextLine = false
        if let template {
            surcharge = template.defaultSurcharge
        }
        surchargePercentLabel = nil
    }

    func recordSuccessfulPrint(
        template: POSReceiptTemplate,
        items: [POSLineItem],
        surcharge: String,
        surchargePercentLabel: String?,
        previewPNG: Data
    ) {
        let record = POSPrintHistoryRecord(
            templateId: template.id,
            templateName: template.name,
            items: items,
            surcharge: surcharge,
            surchargePercentLabel: surchargePercentLabel ?? "",
            previewPNG: previewPNG
        )
        POSPrintHistoryStore.append(record)
        printHistory = POSPrintHistoryStore.loadAll()
    }

    func deletePrintHistory(id: UUID) {
        POSPrintHistoryStore.delete(id: id)
        printHistory = POSPrintHistoryStore.loadAll()
    }

    func clearPrintHistory() {
        POSPrintHistoryStore.clear()
        printHistory = []
    }

    func loadPrintHistory(_ record: POSPrintHistoryRecord) {
        lineItems = record.items
        surcharge = record.surcharge
        surchargePercentLabel = record.surchargePercentLabel.isEmpty ? nil : record.surchargePercentLabel
        endEditingLineItem()
        clearDraft()
        nextAutoCode = max(1, (record.items.compactMap { Int($0.code) }.max() ?? 0) + 1)
        prefersNameFieldForNextLine = !record.items.isEmpty
    }

    func sanitizeCode(_ raw: String) -> String {
        raw.filter { $0.isLetter || $0.isNumber }
    }

    var quantitySubtotalText: String {
        POSReceiptTotals.formatQuantity(POSReceiptTotals.quantitySubtotal(items: lineItems))
    }

    var amountSubtotalText: String {
        POSReceiptTotals.formatAmount(POSReceiptTotals.amountSubtotal(items: lineItems))
    }

    var amountTotalText: String {
        POSReceiptTotals.formatAmount(POSReceiptTotals.amountTotal(items: lineItems, surcharge: surcharge))
    }

    var itemCountText: String {
        "\(POSReceiptTotals.itemCount(items: lineItems))"
    }
}
