import AppKit
import Foundation

/// Persists Excel-sequence templates: `meta.json` + `body.rtfd` + optional images per id.
final class SequenceTemplateStore {
    static let draftBackgroundFilename = "sequence-draft-background.png"
    static let draftLogoFilename = "sequence-draft-logo.png"

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
                  let doc = try? JSONDecoder().decode(SpreadsheetSequenceDocument.self, from: data) else {
                return nil
            }
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

    func loadImage(document: SpreadsheetSequenceDocument, kind: SequenceImageKind) -> NSImage? {
        guard let name = kind.filename(in: document) else { return nil }
        let url = folder(for: document.id).appendingPathComponent(name)
        return NSImage(contentsOf: url)
    }

    func save(
        document: SpreadsheetSequenceDocument,
        body: NSAttributedString,
        backgroundImage: NSImage?,
        logoImage: NSImage?
    ) {
        var doc = document
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

        let logoURL = dir.appendingPathComponent(SpreadsheetSequenceDocument.logoFilename)
        if writePNG(logoImage, to: logoURL) {
            doc.logoImageFilename = SpreadsheetSequenceDocument.logoFilename
        } else {
            try? FileManager.default.removeItem(at: logoURL)
            doc.logoImageFilename = nil
            doc.logoFrame = nil
        }

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

    // MARK: - Draft (placeholders + logo frame + images)

    private var draftMetaURL: URL {
        draftDir.appendingPathComponent("spreadsheet-sequence-placeholders.json")
    }

    private var draftBackgroundURL: URL {
        draftDir.appendingPathComponent(Self.draftBackgroundFilename)
    }

    private var draftLogoURL: URL {
        draftDir.appendingPathComponent(Self.draftLogoFilename)
    }

    func loadDraftMeta() -> SequenceDraftMeta {
        // Migrate legacy `[SequencePlaceholder]` JSON → SequenceDraftMeta
        guard let data = try? Data(contentsOf: draftMetaURL) else { return SequenceDraftMeta() }
        if let meta = try? JSONDecoder().decode(SequenceDraftMeta.self, from: data) {
            return meta
        }
        if let list = try? JSONDecoder().decode([SequencePlaceholder].self, from: data) {
            return SequenceDraftMeta(
                placeholders: list,
                logoFrame: nil,
                hasBackground: FileManager.default.fileExists(atPath: draftBackgroundURL.path),
                hasLogo: FileManager.default.fileExists(atPath: draftLogoURL.path)
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

    func loadDraftLogoImage() -> NSImage? {
        NSImage(contentsOf: draftLogoURL)
    }

    func saveDraft(
        placeholders: [SequencePlaceholder],
        logoFrame: SequencePlaceholderFrame?,
        backgroundImage: NSImage?,
        logoImage: NSImage?
    ) {
        let hasBG = writePNG(backgroundImage, to: draftBackgroundURL)
        let hasLogo = writePNG(logoImage, to: draftLogoURL)
        if !hasBG { try? FileManager.default.removeItem(at: draftBackgroundURL) }
        if !hasLogo { try? FileManager.default.removeItem(at: draftLogoURL) }

        let meta = SequenceDraftMeta(
            placeholders: placeholders,
            logoFrame: hasLogo ? logoFrame : nil,
            hasBackground: hasBG,
            hasLogo: hasLogo
        )
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: draftMetaURL, options: .atomic)
    }

    func saveDraftPlaceholders(_ placeholders: [SequencePlaceholder]) {
        var meta = loadDraftMeta()
        meta.placeholders = placeholders
        meta.hasBackground = FileManager.default.fileExists(atPath: draftBackgroundURL.path)
        meta.hasLogo = FileManager.default.fileExists(atPath: draftLogoURL.path)
        if !meta.hasLogo { meta.logoFrame = nil }
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: draftMetaURL, options: .atomic)
    }

    func clearDraftPlaceholders() {
        try? FileManager.default.removeItem(at: draftMetaURL)
        try? FileManager.default.removeItem(at: draftBackgroundURL)
        try? FileManager.default.removeItem(at: draftLogoURL)
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

enum SequenceImageKind {
    case background
    case logo

    func filename(in document: SpreadsheetSequenceDocument) -> String? {
        switch self {
        case .background: return document.backgroundImageFilename
        case .logo: return document.logoImageFilename
        }
    }
}
