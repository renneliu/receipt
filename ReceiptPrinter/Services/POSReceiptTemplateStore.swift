import AppKit
import Foundation

/// Persists POS templates: `meta.json` + optional background/logo PNGs per id.
final class POSReceiptTemplateStore {
    static let backgroundFilename = "background.png"

    private let root: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("ReceiptPrinter/POSReceiptTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func logoFilename(for id: UUID) -> String {
        "logo-\(id.uuidString).png"
    }

    func loadAll() -> [POSReceiptTemplate] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return dirs.compactMap { dir -> POSReceiptTemplate? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            // Migrate missing keys so older templates still decode after schema additions.
            let migrated: Data
            if var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if obj["nameCharsPerLine"] == nil { obj["nameCharsPerLine"] = 8 }
                // Element-level defaults for older templates.
                if var elements = obj["elements"] as? [[String: Any]] {
                    let nameY: CGFloat = {
                        for el in elements {
                            guard (el["kind"] as? String) == "fieldPlaceholder",
                                  (el["fieldKind"] as? String) == "name",
                                  let frame = el["frame"] as? [String: Any],
                                  let y = frame["y"] as? Double else { continue }
                            return CGFloat(y)
                        }
                        return 80
                    }()
                    for i in elements.indices {
                        if elements[i]["isDashed"] == nil { elements[i]["isDashed"] = false }
                        if elements[i]["isLocked"] == nil { elements[i]["isLocked"] = false }
                        if elements[i]["ticketSection"] == nil {
                            let kindRaw = elements[i]["kind"] as? String ?? ""
                            let fieldRaw = elements[i]["fieldKind"] as? String
                            let frame = elements[i]["frame"] as? [String: Any] ?? [:]
                            let fy = CGFloat((frame["y"] as? Double) ?? 0)
                            let fh = CGFloat((frame["height"] as? Double) ?? 28)
                            let kind = POSElementKind(rawValue: kindRaw) ?? .textBox
                            let fieldKind = fieldRaw.flatMap { POSFieldKind(rawValue: $0) }
                            let section = POSReceiptElement.defaultTicketSection(
                                kind: kind,
                                fieldKind: fieldKind,
                                frame: SequencePlaceholderFrame(x: 0, y: fy, width: 10, height: fh),
                                nameRowY: nameY
                            )
                            elements[i]["ticketSection"] = section.rawValue
                        }
                    }
                    obj["elements"] = elements
                }
                migrated = (try? JSONSerialization.data(withJSONObject: obj)) ?? data
            } else {
                migrated = data
            }
            guard let doc = try? JSONDecoder().decode(POSReceiptTemplate.self, from: migrated) else {
                return nil
            }
            return doc
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadBackground(template: POSReceiptTemplate) -> NSImage? {
        guard let name = template.backgroundImageFilename else { return nil }
        return NSImage(contentsOf: folder(for: template.id).appendingPathComponent(name))
    }

    func loadLogoImages(template: POSReceiptTemplate) -> [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        let dir = folder(for: template.id)
        for el in template.elements where el.kind == .logo {
            guard let name = el.imageFilename,
                  let img = NSImage(contentsOf: dir.appendingPathComponent(name)) else { continue }
            result[el.id] = img
        }
        return result
    }

    func save(
        template: POSReceiptTemplate,
        backgroundImage: NSImage?,
        logos: [(id: UUID, image: NSImage)]
    ) -> POSReceiptTemplate {
        var doc = template
        doc.touch()
        let dir = folder(for: doc.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bgURL = dir.appendingPathComponent(Self.backgroundFilename)
        if writePNG(backgroundImage, to: bgURL) {
            doc.backgroundImageFilename = Self.backgroundFilename
        } else {
            try? FileManager.default.removeItem(at: bgURL)
            doc.backgroundImageFilename = nil
        }

        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("logo-") {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var nextElements = doc.elements
        for i in nextElements.indices where nextElements[i].kind == .logo {
            let elId = nextElements[i].id
            guard let entry = logos.first(where: { $0.id == elId }) else {
                nextElements[i].imageFilename = nil
                continue
            }
            let name = Self.logoFilename(for: elId)
            let url = dir.appendingPathComponent(name)
            guard writePNG(entry.image, to: url) else {
                nextElements[i].imageFilename = nil
                continue
            }
            nextElements[i].imageFilename = name
        }
        doc.elements = nextElements

        let metaURL = dir.appendingPathComponent("meta.json")
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: metaURL, options: .atomic)
        }
        return doc
    }

    /// Save meta-only updates (Excel map, toggles) without rewriting images.
    func saveMeta(_ template: POSReceiptTemplate) {
        var doc = template
        doc.touch()
        let dir = folder(for: doc.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let metaURL = dir.appendingPathComponent("meta.json")
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    func delete(_ template: POSReceiptTemplate) {
        try? FileManager.default.removeItem(at: folder(for: template.id))
    }

    private func writePNG(_ image: NSImage?, to url: URL) -> Bool {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
