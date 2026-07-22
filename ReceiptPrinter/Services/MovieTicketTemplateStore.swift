import AppKit
import Foundation

/// Persists movie-ticket templates and PDF recognition rules under Application Support.
final class MovieTicketTemplateStore {
    static let backgroundFilename = "background.png"

    static func logoFilename(for id: UUID) -> String {
        "logo-\(id.uuidString).png"
    }

    private let templatesRoot: URL
    private let rulesRoot: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        templatesRoot = base.appendingPathComponent("MovieTicketTemplates", isDirectory: true)
        rulesRoot = base.appendingPathComponent("MovieTicketPDFRules", isDirectory: true)
        try? FileManager.default.createDirectory(at: templatesRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rulesRoot, withIntermediateDirectories: true)
        seedIfNeeded()
    }

    func folder(for id: UUID) -> URL {
        templatesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func rulesFolder(for id: UUID) -> URL {
        rulesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: Templates

    func loadAll() -> [MovieTicketTemplate] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: templatesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return dirs.compactMap { dir -> MovieTicketTemplate? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(MovieTicketTemplate.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveMeta(_ template: MovieTicketTemplate) {
        var t = template
        t.touch()
        let dir = folder(for: t.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encodeTemplate(t) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    private func encodeTemplate(_ t: MovieTicketTemplate) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(t)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    func loadBackground(for template: MovieTicketTemplate) -> NSImage? {
        guard template.backgroundImageFilename != nil else { return nil }
        let url = folder(for: template.id).appendingPathComponent(Self.backgroundFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    func saveBackground(_ image: NSImage, for templateId: UUID) -> String? {
        let dir = folder(for: templateId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.backgroundFilename)
        guard writePNG(image, to: url) else { return nil }
        return Self.backgroundFilename
    }

    func loadLogoImages(template: MovieTicketTemplate) -> [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        let dir = folder(for: template.id)
        for el in template.elements where el.kind == .logo {
            guard let name = el.imageFilename,
                  let img = NSImage(contentsOf: dir.appendingPathComponent(name)) else { continue }
            result[el.id] = img
        }
        return result
    }

    /// Writes logo PNGs under the template folder and updates `imageFilename` on logo elements.
    @discardableResult
    func saveLogos(template: MovieTicketTemplate, logos: [UUID: NSImage]) -> MovieTicketTemplate {
        var doc = template
        doc.touch()
        let dir = folder(for: doc.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("logo-") {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var nextElements = doc.elements
        for i in nextElements.indices where nextElements[i].kind == .logo {
            let elId = nextElements[i].id
            guard let image = logos[elId] else {
                nextElements[i].imageFilename = nil
                continue
            }
            let name = Self.logoFilename(for: elId)
            guard writePNG(image, to: dir.appendingPathComponent(name)) else {
                nextElements[i].imageFilename = nil
                continue
            }
            nextElements[i].imageFilename = name
        }
        doc.elements = nextElements
        saveMeta(doc)
        return doc
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

    // MARK: PDF rules

    func loadAllRules() -> [MovieTicketPDFRule] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: rulesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir -> MovieTicketPDFRule? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let metaURL = dir.appendingPathComponent("rule.json")
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            return try? decoder.decode(MovieTicketPDFRule.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveRule(_ rule: MovieTicketPDFRule) {
        var r = rule
        r.touch()
        let dir = rulesFolder(for: r.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(r) {
            try? data.write(to: dir.appendingPathComponent("rule.json"), options: .atomic)
        }
    }

    func deleteRule(_ id: UUID) {
        try? FileManager.default.removeItem(at: rulesFolder(for: id))
    }

    func samplePDFURL(for rule: MovieTicketPDFRule) -> URL? {
        guard let name = rule.samplePDFFilename else { return nil }
        let url = rulesFolder(for: rule.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy an external PDF into the rule folder; returns stored filename.
    func importSamplePDF(from source: URL, for ruleId: UUID) -> String? {
        let dir = rulesFolder(for: ruleId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "sample.pdf"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return name
        } catch {
            return nil
        }
    }

    private static let ritzSampleLayoutVersionKey = "ReceiptPrinter.MovieTicket.RitzSampleLayoutVersion"
    private static let ritzSampleLayoutVersion = 5
    private static let imaxSydneySeedVersionKey = "ReceiptPrinter.MovieTicket.IMAXSydneySeedVersion"
    /// v4: hall field uses `.asRecognized` so "IMAX 1" is not rewritten to "Cinema 1".
    private static let imaxSydneySeedVersion = 4

    private static let orpheumSeedVersionKey = "ReceiptPrinter.MovieTicket.OrpheumSeedVersion"
    private static let orpheumSeedVersion = 1

    private static let dendySeedVersionKey = "ReceiptPrinter.MovieTicket.DendySeedVersion"
    /// v6: title↔cinema gaps follow canvas Y; tighter stock vertical layout.
    private static let dendySeedVersion = 6

    private static let cutFeedMigrateKey = "ReceiptPrinter.MovieTicket.CutFeedDefaultV1"

    private func seedIfNeeded() {
        let existing = loadAll()
        if existing.isEmpty {
            saveMeta(MovieTicketTemplate.makeRitz(name: "示例影票"))
            UserDefaults.standard.set(Self.ritzSampleLayoutVersion, forKey: Self.ritzSampleLayoutVersionKey)
            seedIMAXSydneyIfNeeded(existing: [])
            seedOrpheumIfNeeded(existing: [])
            seedDendyIfNeeded(existing: [])
            migrateCutFeedDefaultsIfNeeded()
            return
        }
        // One-time migrate stock sample to the Ritz dual-stub layout.
        let applied = UserDefaults.standard.integer(forKey: Self.ritzSampleLayoutVersionKey)
        if applied < Self.ritzSampleLayoutVersion,
           let old = existing.first(where: { $0.name == "示例影票" }) {
            var ritz = MovieTicketTemplate.makeRitz(name: "示例影票")
            ritz.id = old.id
            ritz.createdAt = old.createdAt
            ritz.pdfRuleId = old.pdfRuleId
            saveMeta(ritz)
            UserDefaults.standard.set(Self.ritzSampleLayoutVersion, forKey: Self.ritzSampleLayoutVersionKey)
        }
        seedIMAXSydneyIfNeeded(existing: existing)
        seedOrpheumIfNeeded(existing: existing)
        seedDendyIfNeeded(existing: existing)
        migrateCutFeedDefaultsIfNeeded()
    }

    /// Existing templates had no per-template cut feed and inherited the global 12-line
    /// printer default (long tails). Seed a shorter movie-ticket default once.
    private func migrateCutFeedDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.cutFeedMigrateKey) else { return }
        for var t in loadAll() where t.feedLinesBeforeCut == nil {
            t.feedLinesBeforeCut = 4
            saveMeta(t)
        }
        UserDefaults.standard.set(true, forKey: Self.cutFeedMigrateKey)
    }

    /// Install / refresh the bundled IMAX SYDNEY template + logo.
    private func seedIMAXSydneyIfNeeded(existing: [MovieTicketTemplate]) {
        let applied = UserDefaults.standard.integer(forKey: Self.imaxSydneySeedVersionKey)
        guard applied < Self.imaxSydneySeedVersion else { return }

        let made = MovieTicketTemplate.makeIMAXSydney()
        if let old = existing.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("IMAX SYDNEY") == .orderedSame
        }) {
            // Refresh stock layout while preserving id / PDF rule / createdAt.
            var t = made.template
            t.id = old.id
            t.createdAt = old.createdAt
            t.pdfRuleId = old.pdfRuleId
            // Keep existing logo files if present; rewrite element ids would orphan them,
            // so re-attach bundled logo onto the new logo element id.
            saveMeta(t)
            if let logo = Self.bundledIMAXSydneyLogo() {
                let mono = ImagePreprocessor.toBinaryBlackWhite(logo)
                _ = saveLogos(template: t, logos: [made.logoElementId: mono])
            }
        } else {
            let t = made.template
            saveMeta(t)
            if let logo = Self.bundledIMAXSydneyLogo() {
                let mono = ImagePreprocessor.toBinaryBlackWhite(logo)
                _ = saveLogos(template: t, logos: [made.logoElementId: mono])
            }
        }
        UserDefaults.standard.set(Self.imaxSydneySeedVersion, forKey: Self.imaxSydneySeedVersionKey)
    }

    /// Install / refresh the bundled Orpheum dual-stub template.
    private func seedOrpheumIfNeeded(existing: [MovieTicketTemplate]) {
        let applied = UserDefaults.standard.integer(forKey: Self.orpheumSeedVersionKey)
        guard applied < Self.orpheumSeedVersion else { return }

        let made = MovieTicketTemplate.makeOrpheum()
        if let old = existing.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Orpheum") == .orderedSame
                || $0.layoutStyle == "orpheum"
        }) {
            var t = made
            t.id = old.id
            t.name = old.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? made.name : old.name
            t.createdAt = old.createdAt
            t.pdfRuleId = old.pdfRuleId
            t.backgroundImageFilename = old.backgroundImageFilename
            t.backgroundScalePercent = old.backgroundScalePercent
            t.feedLinesBeforeCut = old.feedLinesBeforeCut ?? made.feedLinesBeforeCut
            saveMeta(t)
        } else {
            saveMeta(made)
        }
        UserDefaults.standard.set(Self.orpheumSeedVersion, forKey: Self.orpheumSeedVersionKey)
    }

    /// Install / refresh the bundled Dendy centered-QR template.
    private func seedDendyIfNeeded(existing: [MovieTicketTemplate]) {
        let applied = UserDefaults.standard.integer(forKey: Self.dendySeedVersionKey)
        guard applied < Self.dendySeedVersion else { return }

        let made = MovieTicketTemplate.makeDendy()
        if let old = existing.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Dendy") == .orderedSame
                || $0.layoutStyle == "dendy"
        }) {
            var t = made
            t.id = old.id
            t.name = old.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? made.name : old.name
            t.createdAt = old.createdAt
            t.pdfRuleId = old.pdfRuleId
            t.backgroundImageFilename = old.backgroundImageFilename
            t.backgroundScalePercent = old.backgroundScalePercent
            t.feedLinesBeforeCut = old.feedLinesBeforeCut ?? made.feedLinesBeforeCut
            saveMeta(t)
        } else {
            saveMeta(made)
        }
        UserDefaults.standard.set(Self.dendySeedVersion, forKey: Self.dendySeedVersionKey)
    }

    private static func bundledIMAXSydneyLogo() -> NSImage? {
        let candidates: [URL?] = [
            Bundle.module.url(
                forResource: "IMAXSydneyLogo",
                withExtension: "png",
                subdirectory: "MovieTicket"
            ),
            Bundle.module.url(forResource: "IMAXSydneyLogo", withExtension: "png"),
            // `build-debug-app.sh` copies Resources into the .app Contents/Resources tree.
            Bundle.main.url(
                forResource: "IMAXSydneyLogo",
                withExtension: "png",
                subdirectory: "MovieTicket"
            ),
            Bundle.main.url(forResource: "IMAXSydneyLogo", withExtension: "png")
        ]
        for url in candidates {
            if let url, let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }
}

enum MovieTicketPrintHistoryStore {
    private static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("ReceiptPrinter", isDirectory: true)
            .appendingPathComponent("MovieTicketPrintHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    static func loadAll() -> [MovieTicketPrintHistoryRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([MovieTicketPrintHistoryRecord].self, from: data)) ?? []
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    static func saveAll(_ records: [MovieTicketPrintHistoryRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func append(_ record: MovieTicketPrintHistoryRecord, limit: Int = 100) {
        var all = loadAll()
        all.insert(record, at: 0)
        if all.count > limit { all = Array(all.prefix(limit)) }
        saveAll(all)
    }

    static func delete(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
    }

    static func clear() {
        saveAll([])
    }
}
