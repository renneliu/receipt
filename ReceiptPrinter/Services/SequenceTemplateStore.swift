import AppKit
import Foundation

/// Persists Excel-sequence templates: `meta.json` + `body.rtfd` per id.
final class SequenceTemplateStore {
    private let root: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("ReceiptPrinter/SequenceTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    func save(document: SpreadsheetSequenceDocument, body: NSAttributedString) {
        var doc = document
        doc.touch()
        let dir = root.appendingPathComponent(doc.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Draft placeholders (alongside RTFD draft)

    private var draftMetaURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spreadsheet-sequence-placeholders.json")
    }

    func loadDraftPlaceholders() -> [SequencePlaceholder] {
        guard let data = try? Data(contentsOf: draftMetaURL),
              let list = try? JSONDecoder().decode([SequencePlaceholder].self, from: data) else {
            return []
        }
        return list
    }

    func saveDraftPlaceholders(_ placeholders: [SequencePlaceholder]) {
        guard let data = try? JSONEncoder().encode(placeholders) else { return }
        try? data.write(to: draftMetaURL, options: .atomic)
    }

    func clearDraftPlaceholders() {
        try? FileManager.default.removeItem(at: draftMetaURL)
    }
}
