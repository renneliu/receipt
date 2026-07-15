import AppKit
import Foundation

/// Persists Excel-sequence templates: `meta.json` + `body.rtfd` + optional images per id.
final class SequenceTemplateStore {
    static let draftBackgroundFilename = "sequence-draft-background.png"
    static let draftLegacyLogoFilename = "sequence-draft-logo.png"
    static let draftLogosFolderName = "sequence-draft-logos"

    private let root: URL
    private let draftDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("ReceiptPrinter/SequenceTemplates", isDirectory: true)
        draftDir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private var draftLogosDir: URL {
        draftDir.appendingPathComponent(Self.draftLogosFolderName, isDirectory: true)
    }

    func loadAll() -> [(document: SpreadsheetSequenceDocument, body: NSAttributedString)] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return dirs.compactMap { dir -> (SpreadsheetSequenceDocument, NSAttributedString)? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var doc = try? JSONDecoder().decode(SpreadsheetSequenceDocument.self, from: data) else {
                return nil
            }
            doc.normalizeLogos()
            let bodyURL = dir.appendingPathComponent("body.rtfd", isDirectory: true)
            let body: NSAttributedString
            if FileManager.default.fileExists(atPath: bodyURL.path),
               let loaded = try? NSAttributedString(
                url: bodyURL,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
               ) {
                body = loaded
            } else {
                body = NSAttributedString(string: "", attributes: AttributedTextView.defaultTypingAttributes())
            }
            return (doc, body)
        }
        .sorted { $0.document.updatedAt > $1.document.updatedAt }
    }

    func loadBackground(document: SpreadsheetSequenceDocument) -> NSImage? {
        guard let name = document.backgroundImageFilename else { return nil }
        return NSImage(contentsOf: folder(for: document.id).appendingPathComponent(name))
    }

    func loadLogoImages(document: SpreadsheetSequenceDocument) -> [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        let dir = folder(for: document.id)
        for item in document.logos {
            if let img = NSImage(contentsOf: dir.appendingPathComponent(item.imageFilename)) {
                result[item.id] = img
            }
        }
        return result
    }

    func save(
        document: SpreadsheetSequenceDocument,
        body: NSAttributedString,
        backgroundImage: NSImage?,
        logos: [(item: SequenceLogoItem, image: NSImage)]
    ) {
        var doc = document
        doc.normalizeLogos()
        doc.touch()
        let dir = folder(for: doc.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bgURL = dir.appendingPathComponent(SpreadsheetSequenceDocument.backgroundFilename)
        if writePNG(backgroundImage, to: bgURL) {
            doc.backgroundImageFilename = SpreadsheetSequenceDocument.backgroundFilename
        } else {
            try? FileManager.default.removeItem(at: bgURL)
            doc.backgroundImageFilename = nil
        }

        // Remove previous logo-*.png / legacy logo.png, then write current set.
        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing {
                let name = url.lastPathComponent
                if name == SpreadsheetSequenceDocument.logoFilename || name.hasPrefix("logo-") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        var savedItems: [SequenceLogoItem] = []
        for entry in logos {
            var item = entry.item
            let name = SpreadsheetSequenceDocument.logoFilename(for: item.id)
            let url = dir.appendingPathComponent(name)
            guard writePNG(entry.image, to: url) else { continue }
            item.imageFilename = name
            savedItems.append(item)
        }
        doc.logos = savedItems
        doc.logoImageFilename = nil
        doc.logoFrame = nil

        let metaURL = dir.appendingPathComponent("meta.json")
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: metaURL, options: .atomic)
        }

        let bodyURL = dir.appendingPathComponent("body.rtfd", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodyURL, withIntermediateDirectories: true)
        let range = NSRange(location: 0, length: body.length)
        if let data = try? body.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) {
            let temp = dir.appendingPathComponent("body.rtfd.tmp")
            try? data.write(to: temp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(bodyURL, withItemAt: temp)
        }
    }

    func delete(id: UUID) {
        let dir = folder(for: id)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Draft

    private var draftMetaURL: URL {
        draftDir.appendingPathComponent("spreadsheet-sequence-placeholders.json")
    }

    private var draftBackgroundURL: URL {
        draftDir.appendingPathComponent(Self.draftBackgroundFilename)
    }

    private var draftLegacyLogoURL: URL {
        draftDir.appendingPathComponent(Self.draftLegacyLogoFilename)
    }

    func loadDraftMeta() -> SequenceDraftMeta {
        guard let data = try? Data(contentsOf: draftMetaURL) else { return SequenceDraftMeta() }
        if var meta = try? JSONDecoder().decode(SequenceDraftMeta.self, from: data) {
            meta.normalizeLogos()
            return meta
        }
        if let list = try? JSONDecoder().decode([SequencePlaceholder].self, from: data) {
            return SequenceDraftMeta(
                placeholders: list,
                logos: [],
                hasBackground: FileManager.default.fileExists(atPath: draftBackgroundURL.path),
                logoFrame: nil,
                hasLogo: FileManager.default.fileExists(atPath: draftLegacyLogoURL.path)
            )
        }
        return SequenceDraftMeta()
    }

    func loadDraftPlaceholders() -> [SequencePlaceholder] {
        loadDraftMeta().placeholders
    }

    func loadDraftBackgroundImage() -> NSImage? {
        NSImage(contentsOf: draftBackgroundURL)
    }

    func loadDraftLogoImages(items: [SequenceLogoItem]) -> [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        try? FileManager.default.createDirectory(at: draftLogosDir, withIntermediateDirectories: true)
        for item in items {
            let primary = draftLogosDir.appendingPathComponent(item.imageFilename)
            if let img = NSImage(contentsOf: primary) {
                result[item.id] = img
                continue
            }
            // Legacy single draft logo.
            if item.imageFilename == Self.draftLegacyLogoFilename,
               let img = NSImage(contentsOf: draftLegacyLogoURL) {
                result[item.id] = img
            }
        }
        return result
    }

    func saveDraft(
        placeholders: [SequencePlaceholder],
        logos: [(item: SequenceLogoItem, image: NSImage)],
        backgroundImage: NSImage?,
        backgroundScalePercent: Double = 100
    ) {
        let hasBG = writePNG(backgroundImage, to: draftBackgroundURL)
        if !hasBG { try? FileManager.default.removeItem(at: draftBackgroundURL) }

        try? FileManager.default.createDirectory(at: draftLogosDir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(at: draftLogosDir, includingPropertiesForKeys: nil) {
            for url in existing {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: draftLegacyLogoURL)

        var saved: [SequenceLogoItem] = []
        for entry in logos {
            var item = entry.item
            let name = SpreadsheetSequenceDocument.logoFilename(for: item.id)
            let url = draftLogosDir.appendingPathComponent(name)
            guard writePNG(entry.image, to: url) else { continue }
            item.imageFilename = name
            saved.append(item)
        }

        let clampedBG = min(
            SequenceLogoItem.maxScalePercent,
            max(SequenceLogoItem.minScalePercent, backgroundScalePercent.rounded())
        )
        let meta = SequenceDraftMeta(
            placeholders: placeholders,
            logos: saved,
            hasBackground: hasBG,
            backgroundScalePercent: hasBG ? clampedBG : 100,
            logoFrame: nil,
            hasLogo: !saved.isEmpty
        )
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: draftMetaURL, options: .atomic)
    }

    func saveDraftPlaceholders(_ placeholders: [SequencePlaceholder]) {
        var meta = loadDraftMeta()
        meta.placeholders = placeholders
        meta.hasBackground = FileManager.default.fileExists(atPath: draftBackgroundURL.path)
        meta.hasLogo = !meta.logos.isEmpty
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: draftMetaURL, options: .atomic)
    }

    func clearDraftPlaceholders() {
        try? FileManager.default.removeItem(at: draftMetaURL)
        try? FileManager.default.removeItem(at: draftBackgroundURL)
        try? FileManager.default.removeItem(at: draftLegacyLogoURL)
        try? FileManager.default.removeItem(at: draftLogosDir)
    }

    // MARK: - PNG helpers

    @discardableResult
    private func writePNG(_ image: NSImage?, to url: URL) -> Bool {
        guard let image, let data = pngData(from: image) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
