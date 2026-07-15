import AppKit
import Foundation

/// Draft persistence for Quick Print logos / background / auto-number (separate from body RTFD).
final class QuickPrintMediaStore {
    static let draftBackgroundFilename = "quick-print-background.png"
    static let draftLogosFolderName = "quick-print-logos"
    static let draftMetaFilename = "quick-print-media.json"

    struct DraftMeta: Codable, Equatable {
        var logos: [SequenceLogoItem] = []
        var hasBackground: Bool = false
        var backgroundScalePercent: Double = 100
        var autoNumber: QuickPrintAutoNumber = QuickPrintAutoNumber()
    }

    private let draftDir: URL
    private let draftMetaURL: URL
    private let draftBackgroundURL: URL
    private let draftLogosDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        draftDir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        draftMetaURL = draftDir.appendingPathComponent(Self.draftMetaFilename)
        draftBackgroundURL = draftDir.appendingPathComponent(Self.draftBackgroundFilename)
        draftLogosDir = draftDir.appendingPathComponent(Self.draftLogosFolderName, isDirectory: true)
    }

    func loadMeta() -> DraftMeta {
        guard let data = try? Data(contentsOf: draftMetaURL),
              let meta = try? JSONDecoder().decode(DraftMeta.self, from: data) else {
            return DraftMeta()
        }
        return meta
    }

    func loadBackgroundImage() -> NSImage? {
        NSImage(contentsOf: draftBackgroundURL)
    }

    func loadLogoImages(items: [SequenceLogoItem]) -> [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        try? FileManager.default.createDirectory(at: draftLogosDir, withIntermediateDirectories: true)
        for item in items {
            let url = draftLogosDir.appendingPathComponent(item.imageFilename)
            if let img = NSImage(contentsOf: url) {
                result[item.id] = img
            }
        }
        return result
    }

    func save(
        logos: [(item: SequenceLogoItem, image: NSImage)],
        backgroundImage: NSImage?,
        backgroundScalePercent: Double,
        autoNumber: QuickPrintAutoNumber
    ) {
        let hasBG = writePNG(backgroundImage, to: draftBackgroundURL)
        if !hasBG { try? FileManager.default.removeItem(at: draftBackgroundURL) }

        try? FileManager.default.createDirectory(at: draftLogosDir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: draftLogosDir,
            includingPropertiesForKeys: nil
        ) {
            for url in existing {
                try? FileManager.default.removeItem(at: url)
            }
        }

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
        var number = autoNumber
        number.clampBatch()
        number.clampFontSize()

        let meta = DraftMeta(
            logos: saved,
            hasBackground: hasBG,
            backgroundScalePercent: hasBG ? clampedBG : 100,
            autoNumber: number
        )
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: draftMetaURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: draftMetaURL)
        try? FileManager.default.removeItem(at: draftBackgroundURL)
        try? FileManager.default.removeItem(at: draftLogosDir)
    }

    @discardableResult
    private func writePNG(_ image: NSImage?, to url: URL) -> Bool {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
