import AppKit
import Combine
import Foundation
import SwiftUI

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
    @Published var draftCode = ""
    @Published var draftName = ""
    @Published var draftQuantity = ""
    @Published var draftAmount = ""
    @Published var surcharge = "0"
    @Published var nextAutoCode = 1
    @Published var message = ""
    @Published var excelRowCount: Int?

    let store = POSReceiptTemplateStore()

    var activeTemplate: POSReceiptTemplate? {
        guard let id = settings.activeTemplateId else { return templates.first }
        return templates.first { $0.id == id } ?? templates.first
    }

    init() {
        settings = POSReceiptSettings.load()
        reloadTemplates()
        if let t = activeTemplate {
            surcharge = t.defaultSurcharge
            loadImages(for: t)
        }
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
            loadImages(for: t)
            nextAutoCode = 1
            lineItems = []
            clearDraft()
            selectedItemId = nil
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
        message = "模板已保存"
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
}
