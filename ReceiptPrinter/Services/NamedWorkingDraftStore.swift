import AppKit
import Foundation

/// One user-named working draft (separate from the single autosave slot used for page-switch retention).
struct NamedWorkingDraft: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// `quickPrint` / `spreadsheetSequence` / `posReceipt`
    var module: String
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Short plain-text preview for the picker list.
    var previewText: String
    /// POS: serialized cart. Quick/Excel: optional extra JSON beside body.rtfd.
    var payloadJSON: Data?
    var hasBodyRTFD: Bool = false

    mutating func touch() { updatedAt = Date() }
}

/// Multi-draft library per module under Application Support.
enum NamedWorkingDraftStore {
    private static func root(module: String) -> URL {
        // Use nested appendingPathComponent — a single "a/b" component is unreliable across Foundation versions.
        AppPaths.subdirectory("NamedDrafts").appendingPathComponent(module, isDirectory: true)
    }

    private static func indexURL(module: String) -> URL {
        let dir = root(module: module)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    private static func folder(module: String, id: UUID) -> URL {
        root(module: module).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func loadAll(module: String) -> [NamedWorkingDraft] {
        let url = indexURL(module: module)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = (try? decoder.decode([NamedWorkingDraft].self, from: data)) ?? []
        return all.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func saveIndex(_ records: [NamedWorkingDraft], module: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = root(module: module)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL(module: module), options: .atomic)
    }

    static func delete(id: UUID, module: String) {
        var all = loadAll(module: module)
        all.removeAll { $0.id == id }
        saveIndex(all, module: module)
        try? FileManager.default.removeItem(at: folder(module: module, id: id))
    }

    static func clear(module: String) {
        for record in loadAll(module: module) {
            try? FileManager.default.removeItem(at: folder(module: module, id: record.id))
        }
        saveIndex([], module: module)
    }

    static func clearAllKnown() {
        clear(module: "quickPrint")
        clear(module: "spreadsheetSequence")
        clear(module: "posReceipt")
    }

    // MARK: - Quick / Excel body

    static func saveQuickDraft(
        name: String,
        previewText: String,
        body: NSAttributedString,
        logos: [(item: SequenceLogoItem, image: NSImage)],
        backgroundImage: NSImage?,
        backgroundScalePercent: Double,
        autoNumber: QuickPrintAutoNumber
    ) -> NamedWorkingDraft {
        var record = NamedWorkingDraft(
            module: "quickPrint",
            name: name,
            previewText: previewText.isEmpty ? L10n.ui("（空白）") : String(previewText.prefix(120)),
            payloadJSON: nil,
            hasBodyRTFD: body.length > 0
        )
        let dir = folder(module: "quickPrint", id: record.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeRTFD(body, to: dir.appendingPathComponent("body.rtfd", isDirectory: true))

        var savedLogos: [SequenceLogoItem] = []
        let logosDir = dir.appendingPathComponent("logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: logosDir, withIntermediateDirectories: true)
        for entry in logos {
            var item = entry.item
            let fileName = SpreadsheetSequenceDocument.logoFilename(for: item.id)
            if writePNG(entry.image, to: logosDir.appendingPathComponent(fileName)) {
                item.imageFilename = fileName
                savedLogos.append(item)
            }
        }
        let hasBG = writePNG(backgroundImage, to: dir.appendingPathComponent("background.png"))
        let meta = QuickPrintMediaStore.DraftMeta(
            logos: savedLogos,
            hasBackground: hasBG,
            backgroundScalePercent: hasBG ? backgroundScalePercent : 100,
            autoNumber: autoNumber
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        record.payloadJSON = nil
        var all = loadAll(module: "quickPrint")
        all.insert(record, at: 0)
        saveIndex(all, module: "quickPrint")
        return record
    }

    static func loadQuickDraftAssets(id: UUID) -> (
        meta: QuickPrintMediaStore.DraftMeta,
        logoImages: [UUID: NSImage],
        background: NSImage?
    ) {
        let dir = folder(module: "quickPrint", id: id)
        var meta = QuickPrintMediaStore.DraftMeta()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let decoded = try? JSONDecoder().decode(QuickPrintMediaStore.DraftMeta.self, from: data) {
            meta = decoded
        }
        var logos: [UUID: NSImage] = [:]
        let logosDir = dir.appendingPathComponent("logos", isDirectory: true)
        for item in meta.logos {
            if let img = NSImage(contentsOf: logosDir.appendingPathComponent(item.imageFilename)) {
                logos[item.id] = img
            }
        }
        let bg = meta.hasBackground ? NSImage(contentsOf: dir.appendingPathComponent("background.png")) : nil
        return (meta, logos, bg)
    }

    static func saveRichDraft(
        module: String,
        name: String,
        previewText: String,
        body: NSAttributedString,
        metaJSON: Data?
    ) -> NamedWorkingDraft {
        var record = NamedWorkingDraft(
            module: module,
            name: name,
            previewText: previewText.isEmpty ? L10n.ui("（空白）") : String(previewText.prefix(120)),
            payloadJSON: metaJSON,
            hasBodyRTFD: body.length > 0
        )
        let dir = folder(module: module, id: record.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeRTFD(body, to: dir.appendingPathComponent("body.rtfd", isDirectory: true))
        if let metaJSON {
            try? metaJSON.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        var all = loadAll(module: module)
        all.insert(record, at: 0)
        saveIndex(all, module: module)
        return record
    }

    static func loadBody(module: String, id: UUID) -> NSAttributedString {
        let url = folder(module: module, id: id).appendingPathComponent("body.rtfd", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path),
           let loaded = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
           ) {
            return loaded
        }
        // Flat file fallback
        let flat = folder(module: module, id: id).appendingPathComponent("body.rtfd")
        if let loaded = try? NSAttributedString(
            url: flat,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        ) {
            return loaded
        }
        return NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
    }

    static func loadMetaJSON(module: String, id: UUID) -> Data? {
        try? Data(contentsOf: folder(module: module, id: id).appendingPathComponent("meta.json"))
    }

    // MARK: - POS cart

    static func savePOSDraft(name: String, previewText: String, cart: POSCartDraft) -> NamedWorkingDraft {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try? encoder.encode(cart)
        var record = NamedWorkingDraft(
            module: "posReceipt",
            name: name,
            previewText: previewText.isEmpty ? L10n.ui("（空白）") : String(previewText.prefix(120)),
            payloadJSON: nil,
            hasBodyRTFD: false
        )
        let dir = folder(module: "posReceipt", id: record.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json {
            try? json.write(to: dir.appendingPathComponent("cart.json"), options: .atomic)
        }
        var all = loadAll(module: "posReceipt")
        all.insert(record, at: 0)
        saveIndex(all, module: "posReceipt")
        return record
    }

    static func loadPOSCart(id: UUID) -> POSCartDraft? {
        let url = folder(module: "posReceipt", id: id).appendingPathComponent("cart.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(POSCartDraft.self, from: data)
    }

    static func saveExcelDraft(
        name: String,
        previewText: String,
        body: NSAttributedString,
        placeholders: [SequencePlaceholder],
        logos: [(item: SequenceLogoItem, image: NSImage)],
        backgroundImage: NSImage?,
        backgroundScalePercent: Double,
        spreadsheet: SpreadsheetTable?,
        selectedRowIndex: Int,
        importInfo: String,
        editorFontSize: Double
    ) -> NamedWorkingDraft {
        let dirPlaceholder = UUID()
        var record = NamedWorkingDraft(
            module: "spreadsheetSequence",
            name: name,
            previewText: previewText.isEmpty ? L10n.ui("（空白）") : String(previewText.prefix(120)),
            payloadJSON: nil,
            hasBodyRTFD: body.length > 0
        )
        let dir = folder(module: "spreadsheetSequence", id: record.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeRTFD(body, to: dir.appendingPathComponent("body.rtfd", isDirectory: true))

        var savedLogos: [SequenceLogoItem] = []
        let logosDir = dir.appendingPathComponent("logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: logosDir, withIntermediateDirectories: true)
        for entry in logos {
            var item = entry.item
            let fileName = SpreadsheetSequenceDocument.logoFilename(for: item.id)
            if writePNG(entry.image, to: logosDir.appendingPathComponent(fileName)) {
                item.imageFilename = fileName
                savedLogos.append(item)
            }
        }
        let hasBG = writePNG(backgroundImage, to: dir.appendingPathComponent("background.png"))
        let meta = SequenceDraftMeta(
            placeholders: placeholders,
            logos: savedLogos,
            hasBackground: hasBG,
            backgroundScalePercent: hasBG ? backgroundScalePercent : 100,
            spreadsheet: spreadsheet,
            selectedRowIndex: selectedRowIndex,
            importInfo: importInfo
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        record.payloadJSON = nil
        if let sizeData = try? JSONEncoder().encode(["editorFontSize": editorFontSize]) {
            try? sizeData.write(to: dir.appendingPathComponent("extra.json"), options: .atomic)
        }
        _ = dirPlaceholder
        var all = loadAll(module: "spreadsheetSequence")
        all.insert(record, at: 0)
        saveIndex(all, module: "spreadsheetSequence")
        return record
    }

    static func loadExcelDraftAssets(id: UUID) -> (
        meta: SequenceDraftMeta,
        logoImages: [UUID: NSImage],
        background: NSImage?,
        editorFontSize: Double?
    ) {
        let dir = folder(module: "spreadsheetSequence", id: id)
        var meta = SequenceDraftMeta()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           var decoded = try? JSONDecoder().decode(SequenceDraftMeta.self, from: data) {
            decoded.normalizeLogos()
            meta = decoded
        }
        var logos: [UUID: NSImage] = [:]
        let logosDir = dir.appendingPathComponent("logos", isDirectory: true)
        for item in meta.logos {
            if let img = NSImage(contentsOf: logosDir.appendingPathComponent(item.imageFilename)) {
                logos[item.id] = img
            }
        }
        let bg = meta.hasBackground ? NSImage(contentsOf: dir.appendingPathComponent("background.png")) : nil
        var fontSize: Double?
        if let data = try? Data(contentsOf: dir.appendingPathComponent("extra.json")),
           let dict = try? JSONDecoder().decode([String: Double].self, from: data) {
            fontSize = dict["editorFontSize"]
        }
        return (meta, logos, bg, fontSize)
    }

    @discardableResult
    private static func writePNG(_ image: NSImage?, to url: URL) -> Bool {
        guard let image, let data = QuickPrintTemplateStore.pngData(from: image) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func writeRTFD(_ body: NSAttributedString, to url: URL) {
        try? FileManager.default.removeItem(at: url)
        let range = NSRange(location: 0, length: body.length)
        if let wrapper = try? body.fileWrapper(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) {
            try? wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            return
        }
        if let data = try? body.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
