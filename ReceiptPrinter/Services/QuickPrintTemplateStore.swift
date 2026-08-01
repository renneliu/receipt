import AppKit
import Foundation

/// Quick Print named template (body + logos/background/auto-number).
struct QuickPrintTemplateDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var paperWidthMM: Int = 80
    var editorFontSize: Double = AttributedTextView.defaultFontSize
    var backgroundImageFilename: String? = nil
    var backgroundScalePercent: Double = 100
    var logos: [SequenceLogoItem] = []
    var autoNumber: QuickPrintAutoNumber = QuickPrintAutoNumber()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    mutating func touch() { updatedAt = Date() }
}

/// Persists Quick Print templates under Application Support (includes logos).
final class QuickPrintTemplateStore {
    private let root: URL

    init() {
        root = AppPaths.subdirectory("QuickPrintTemplates")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func loadAll() -> [(document: QuickPrintTemplateDocument, body: NSAttributedString)] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return dirs.compactMap { dir -> (QuickPrintTemplateDocument, NSAttributedString)? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let doc = try? JSONDecoder().decode(QuickPrintTemplateDocument.self, from: data) else {
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

    func loadBackground(document: QuickPrintTemplateDocument) -> NSImage? {
        guard let name = document.backgroundImageFilename else { return nil }
        return NSImage(contentsOf: folder(for: document.id).appendingPathComponent(name))
    }

    func loadLogoImages(document: QuickPrintTemplateDocument) -> [UUID: NSImage] {
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
        document: QuickPrintTemplateDocument,
        body: NSAttributedString,
        logos: [(item: SequenceLogoItem, image: NSImage)],
        backgroundImage: NSImage?,
        autoNumber: QuickPrintAutoNumber
    ) {
        var doc = document
        doc.autoNumber = autoNumber
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

        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("logo-") {
                try? FileManager.default.removeItem(at: url)
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

        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        NamedWorkingDraftStore.writeRTFD(body, to: dir.appendingPathComponent("body.rtfd", isDirectory: true))
    }

    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let metaURL = folder(for: id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              var doc = try? JSONDecoder().decode(QuickPrintTemplateDocument.self, from: data) else { return }
        doc.name = trimmed
        doc.touch()
        if let encoded = try? JSONEncoder().encode(doc) {
            try? encoded.write(to: metaURL, options: .atomic)
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    @discardableResult
    private func writePNG(_ image: NSImage?, to url: URL) -> Bool {
        guard let image, let data = Self.pngData(from: image) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// More resilient than tiffRepresentation alone (handles some B&W / lockFocus images).
    static func pngData(from image: NSImage) -> Data? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width)),
            pixelsHigh: max(1, Int(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
