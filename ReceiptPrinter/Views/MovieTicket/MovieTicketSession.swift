import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MovieTicketSession: ObservableObject {
    let store = MovieTicketTemplateStore()

    @Published var settings: MovieTicketSettings
    @Published var templates: [MovieTicketTemplate] = []
    @Published var pdfRules: [MovieTicketPDFRule] = []
    @Published var editingTemplate: MovieTicketTemplate?
    @Published var draft: MovieTicketDraft = .blank()
    @Published var backgroundImage: NSImage?
    @Published var logoImages: [UUID: NSImage] = [:]
    @Published var message: String = ""
    @Published var printHistory: [MovieTicketPrintHistoryRecord] = []
    /// True when the in-memory template editor has changes not written via 保存.
    @Published var isEditingDirty: Bool = false

    init() {
        settings = MovieTicketSettings.load()
        reloadAll()
        printHistory = MovieTicketPrintHistoryStore.loadAll()
    }

    func markEditingDirty() {
        isEditingDirty = true
    }

    func markEditingClean() {
        isEditingDirty = false
    }

    var activeTemplate: MovieTicketTemplate? {
        guard let id = settings.activeTemplateId else { return templates.first }
        return templates.first { $0.id == id } ?? templates.first
    }

    func reloadAll() {
        templates = store.loadAll()
        pdfRules = store.loadAllRules()
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
            loadImages(for: t)
        }
    }

    /// Persist a meta-only change on the active (or editing) template.
    func updateTemplateMeta(id: UUID? = nil, _ body: (inout MovieTicketTemplate) -> Void) {
        let targetId = id ?? editingTemplate?.id ?? settings.activeTemplateId
        guard let targetId else { return }
        var t: MovieTicketTemplate
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

    func beginEditing(_ template: MovieTicketTemplate) {
        var t = template
        MovieTicketRitzESCPOS.migratePrintHeightScales(in: &t)
        editingTemplate = t
        loadImages(for: t)
        markEditingClean()
    }

    func syncEditingIntoTemplates() {
        guard var t = editingTemplate,
              let idx = templates.firstIndex(where: { $0.id == t.id }) else { return }
        t.touch()
        templates[idx] = t
        store.saveMeta(t)
        if settings.activeTemplateId == t.id {
            loadImages(for: t)
        }
    }

    /// Reload the current editing template from disk, discarding unsaved canvas edits.
    func discardEditingChanges() {
        guard let id = editingTemplate?.id else {
            editingTemplate = nil
            logoImages = [:]
            backgroundImage = nil
            markEditingClean()
            return
        }
        reloadAll()
        if let t = templates.first(where: { $0.id == id }) {
            beginEditing(t)
        } else {
            editingTemplate = nil
            logoImages = [:]
            backgroundImage = nil
            markEditingClean()
        }
    }

    func createTemplate(name: String = L10n.ui("新影票模板")) {
        let t = MovieTicketTemplate.makeBlank(name: name)
        store.saveMeta(t)
        reloadAll()
        selectTemplate(t.id)
        beginEditing(t)
    }

    /// Deep-copy meta + background/logos under a new id; name becomes `原名(1)` (or `(2)`…).
    @discardableResult
    func duplicateTemplate(_ source: MovieTicketTemplate? = nil) -> MovieTicketTemplate? {
        guard let source = source ?? editingTemplate ?? activeTemplate else { return nil }

        var bg = store.loadBackground(for: source)
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
        copy.pdfRuleId = nil
        copy.touch()

        store.saveMeta(copy)
        if let bg {
            copy.backgroundImageFilename = store.saveBackground(bg, for: copy.id) ?? copy.backgroundImageFilename
            store.saveMeta(copy)
        } else {
            copy.backgroundImageFilename = nil
            store.saveMeta(copy)
        }
        copy = store.saveLogos(template: copy, logos: logos)

        reloadAll()
        selectTemplate(copy.id)
        if let saved = templates.first(where: { $0.id == copy.id }) {
            beginEditing(saved)
            message = "已复制为「\(saved.name)」"
            return saved
        }
        beginEditing(copy)
        message = "已复制为「\(copy.name)」"
        return copy
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

    func deleteTemplate(_ id: UUID) {
        store.delete(id)
        if editingTemplate?.id == id {
            editingTemplate = nil
            logoImages = [:]
            backgroundImage = nil
            markEditingClean()
        }
        reloadAll()
    }

    func loadImages(for template: MovieTicketTemplate) {
        backgroundImage = store.loadBackground(for: template)
        let disk = store.loadLogoImages(template: template)
        // Keep unsaved in-memory logos still referenced by the template.
        var merged = disk
        for el in template.elements where el.kind == .logo {
            if merged[el.id] == nil, let mem = logoImages[el.id] {
                merged[el.id] = mem
            }
        }
        logoImages = merged
    }

    func saveEditingTemplate() {
        guard var t = editingTemplate else { return }
        t = store.saveLogos(template: t, logos: logoImages)
        if let bg = backgroundImage {
            t.backgroundImageFilename = store.saveBackground(bg, for: t.id) ?? t.backgroundImageFilename
            store.saveMeta(t)
        } else {
            store.saveMeta(t)
        }
        reloadAll()
        editingTemplate = templates.first { $0.id == t.id } ?? t
        if let saved = editingTemplate {
            loadImages(for: saved)
        }
        markEditingClean()
        message = L10n.ui("模板已保存")
    }

    func setBackground(_ image: NSImage?) {
        guard var t = editingTemplate else { return }
        if let image {
            t.backgroundImageFilename = store.saveBackground(image, for: t.id)
            backgroundImage = image
        } else {
            t.backgroundImageFilename = nil
            backgroundImage = nil
        }
        editingTemplate = t
        store.saveMeta(t)
        reloadAll()
    }

    // MARK: PDF rules

    func savePDFRule(_ rule: MovieTicketPDFRule) {
        store.saveRule(rule)
        pdfRules = store.loadAllRules()
        if var t = editingTemplate, t.pdfRuleId == nil, rule.linkedTemplateId == t.id {
            t.pdfRuleId = rule.id
            editingTemplate = t
            store.saveMeta(t)
            reloadAll()
        }
    }

    func deletePDFRule(_ id: UUID) {
        store.deleteRule(id)
        pdfRules = store.loadAllRules()
        // Clear any template that pointed at this rule.
        for var t in templates where t.pdfRuleId == id {
            t.pdfRuleId = nil
            store.saveMeta(t)
        }
        if editingTemplate?.pdfRuleId == id {
            editingTemplate?.pdfRuleId = nil
        }
        reloadAll()
    }

    /// Exclusive 1:1 — each template links to exactly one PDF rule.
    func linkRule(_ ruleId: UUID, to templateId: UUID) {
        guard var rule = pdfRules.first(where: { $0.id == ruleId }) else { return }
        let previousPdfRuleId = templates.first(where: { $0.id == templateId })?.pdfRuleId

        // Detach any other rules that pointed at this template.
        for var other in pdfRules where other.linkedTemplateId == templateId && other.id != ruleId {
            other.linkedTemplateId = nil
            store.saveRule(other)
        }
        // If this rule was linked to another template, clear that template's pdfRuleId.
        if let oldTemplateId = rule.linkedTemplateId, oldTemplateId != templateId,
           var oldT = templates.first(where: { $0.id == oldTemplateId }),
           oldT.pdfRuleId == ruleId {
            oldT.pdfRuleId = nil
            store.saveMeta(oldT)
        }
        // If the template previously pointed at a different rule, clear that rule's link.
        if let oldRuleId = previousPdfRuleId, oldRuleId != ruleId,
           var oldRule = pdfRules.first(where: { $0.id == oldRuleId }) {
            oldRule.linkedTemplateId = nil
            store.saveRule(oldRule)
        }

        rule.linkedTemplateId = templateId
        store.saveRule(rule)
        if var t = templates.first(where: { $0.id == templateId }) {
            t.pdfRuleId = ruleId
            store.saveMeta(t)
        }
        if editingTemplate?.id == templateId {
            editingTemplate?.pdfRuleId = ruleId
        }
        reloadAll()
    }

    func unlinkRule(from templateId: UUID) {
        guard var t = templates.first(where: { $0.id == templateId }) else { return }
        let oldRuleId = t.pdfRuleId
        t.pdfRuleId = nil
        store.saveMeta(t)
        if let oldRuleId, var rule = pdfRules.first(where: { $0.id == oldRuleId }) {
            rule.linkedTemplateId = nil
            store.saveRule(rule)
        }
        if editingTemplate?.id == templateId {
            editingTemplate?.pdfRuleId = nil
        }
        reloadAll()
    }

    // MARK: History

    func recordSuccessfulPrint(template: MovieTicketTemplate, draft: MovieTicketDraft, previewPNG: Data) {
        let record = MovieTicketPrintHistoryRecord(
            templateId: template.id,
            templateName: template.name,
            draft: draft,
            previewPNG: previewPNG
        )
        MovieTicketPrintHistoryStore.append(record)
        printHistory = MovieTicketPrintHistoryStore.loadAll()
    }

    func loadHistory(_ record: MovieTicketPrintHistoryRecord) {
        draft = record.draft
        if let tid = record.templateId {
            selectTemplate(tid)
        }
        message = L10n.ui("已载入打印记录")
    }

    func deleteHistory(_ id: UUID) {
        MovieTicketPrintHistoryStore.delete(id: id)
        printHistory = MovieTicketPrintHistoryStore.loadAll()
    }

    func clearHistory() {
        MovieTicketPrintHistoryStore.clear()
        printHistory = []
    }

    func resetDraft() {
        draft = .blank(defaultAd: 15)
        draft.setTicketCount(1)
    }
}
