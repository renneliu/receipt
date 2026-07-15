import Foundation
import CoreGraphics

/// Freestyle placeholder bound to an Excel column on the sequence-print page.
struct SequencePlaceholder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bindingKey: String
    var frame: SequencePlaceholderFrame
    var fontSize: CGFloat = AttributedTextView.defaultFontSize
    var alignment: Int = 0 // NSTextAlignment raw-ish: 0 left, 1 center, 2 right
    var zIndex: Int = 0

    var escposAlign: ESCPOSAlign {
        switch alignment {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }
}

struct SequencePlaceholderFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    static let `default` = SequencePlaceholderFrame(x: 12, y: 12, width: 160, height: 36)

    func clamped(to paper: CGSize, minSize: CGSize = CGSize(width: 40, height: 22)) -> SequencePlaceholderFrame {
        var w = max(minSize.width, width)
        var h = max(minSize.height, height)
        w = min(w, max(minSize.width, paper.width))
        h = min(h, max(minSize.height, paper.height))
        let maxX = max(0, paper.width - w)
        let maxY = max(0, paper.height - h)
        let x = min(max(0, self.x), maxX)
        let y = min(max(0, self.y), maxY)
        return SequencePlaceholderFrame(x: x, y: y, width: w, height: h)
    }
}

/// One logo on the sequence canvas: file + rect + scale percent of its base size.
struct SequenceLogoItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Relative filename inside the template / draft logos folder (e.g. `logo-<uuid>.png`).
    var imageFilename: String
    var frame: SequencePlaceholderFrame
    /// Size relative to `baseWidth` × `baseHeight` (100 = base). Clamped in UI to 10…400.
    var scalePercent: Double = 100
    var baseWidth: CGFloat
    var baseHeight: CGFloat
    var zIndex: Int = 0

    static let minScalePercent: Double = 10
    static let maxScalePercent: Double = 400

    mutating func applyScalePercent(_ percent: Double, paper: CGSize) {
        let p = min(Self.maxScalePercent, max(Self.minScalePercent, percent.rounded()))
        scalePercent = p
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        let w = max(36, baseWidth * p / 100)
        let h = max(24, baseHeight * p / 100)
        frame = SequencePlaceholderFrame(
            x: cx - w / 2,
            y: cy - h / 2,
            width: w,
            height: h
        ).clamped(to: paper, minSize: CGSize(width: 36, height: 24))
    }

    /// Sync scale from a newly dragged frame (keeps base; updates percent from width).
    mutating func syncScaleFromFrame(paper: CGSize) {
        guard baseWidth > 0 else { return }
        let aspect = baseHeight > 0 ? baseWidth / baseHeight : 1
        var w = max(36, frame.width)
        _ = max(24, w / max(aspect, 0.05))
        let p = min(Self.maxScalePercent, max(Self.minScalePercent, (Double(w / baseWidth) * 100).rounded()))
        scalePercent = p
        w = max(36, baseWidth * p / 100)
        let h = max(24, baseHeight * p / 100)
        frame = SequencePlaceholderFrame(x: frame.x, y: frame.y, width: w, height: h)
            .clamped(to: paper, minSize: CGSize(width: 36, height: 24))
    }

    static func makeDefault(
        id: UUID = UUID(),
        imageFilename: String,
        imageSize: CGSize,
        paperWidth: CGFloat,
        paperSize: CGSize,
        staggerIndex: Int,
        zIndex: Int
    ) -> SequenceLogoItem {
        let w = min(paperWidth * 0.35, max(80, imageSize.width * 0.5))
        let aspect = imageSize.height > 0 ? imageSize.width / imageSize.height : 2
        let h = max(36, w / max(aspect, 0.2))
        let offset = CGFloat(staggerIndex % 5) * 18
        let frame = SequencePlaceholderFrame(
            x: (paperWidth - w) / 2 + offset,
            y: 16 + offset,
            width: w,
            height: h
        ).clamped(to: paperSize, minSize: CGSize(width: 36, height: 24))
        return SequenceLogoItem(
            id: id,
            imageFilename: imageFilename,
            frame: frame,
            scalePercent: 100,
            baseWidth: frame.width,
            baseHeight: frame.height,
            zIndex: zIndex
        )
    }
}

/// Saved sequence-print template (body RTFD + optional images stored beside this JSON).
struct SpreadsheetSequenceDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var placeholders: [SequencePlaceholder] = []
    var paperWidthMM: Int = 80
    var editorFontSize: Double = AttributedTextView.defaultFontSize
    /// Relative filenames inside the template folder (e.g. `background.png`).
    var backgroundImageFilename: String? = nil
    /// Size relative to aspect-fit-on-paper (100 = fully fit-centered). Clamped 10…400 in UI.
    var backgroundScalePercent: Double = 100
    /// Multiple logos (files: `logo-<uuid>.png`).
    var logos: [SequenceLogoItem] = []
    /// Legacy single-logo fields (migrated into `logos` on load).
    var logoImageFilename: String? = nil
    var logoFrame: SequencePlaceholderFrame? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    static let backgroundFilename = "background.png"
    static let logoFilename = "logo.png"

    mutating func touch() {
        updatedAt = Date()
    }

    /// Fold legacy single logo into `logos` and drop obsolete fields before save.
    mutating func normalizeLogos() {
        if logos.isEmpty, let file = logoImageFilename {
            let f = logoFrame ?? SequencePlaceholderFrame(x: 40, y: 12, width: 120, height: 60)
            logos = [
                SequenceLogoItem(
                    id: UUID(),
                    imageFilename: file,
                    frame: f,
                    scalePercent: 100,
                    baseWidth: f.width,
                    baseHeight: f.height,
                    zIndex: 0
                )
            ]
        }
        logoImageFilename = nil
        logoFrame = nil
    }

    static func logoFilename(for id: UUID) -> String {
        "logo-\(id.uuidString).png"
    }
}

/// Session / draft meta for placeholders + logos (images stored as sibling files).
struct SequenceDraftMeta: Codable, Equatable {
    var placeholders: [SequencePlaceholder] = []
    var logos: [SequenceLogoItem] = []
    var hasBackground: Bool = false
    var backgroundScalePercent: Double = 100
    /// Legacy single-logo draft fields.
    var logoFrame: SequencePlaceholderFrame? = nil
    var hasLogo: Bool = false

    mutating func normalizeLogos() {
        if logos.isEmpty, hasLogo, let frame = logoFrame {
            logos = [
                SequenceLogoItem(
                    id: UUID(),
                    imageFilename: SequenceTemplateStore.draftLegacyLogoFilename,
                    frame: frame,
                    scalePercent: 100,
                    baseWidth: frame.width,
                    baseHeight: frame.height,
                    zIndex: 0
                )
            ]
        }
        logoFrame = nil
        hasLogo = !logos.isEmpty
    }
}
