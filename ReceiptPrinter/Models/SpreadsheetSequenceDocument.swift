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
        let x = min(max(0, self.x), max(0, paper.width - w))
        let y = min(max(0, self.y), max(0, paper.height - h))
        return SequencePlaceholderFrame(x: x, y: y, width: w, height: h)
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
    var logoImageFilename: String? = nil
    var logoFrame: SequencePlaceholderFrame? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    static let backgroundFilename = "background.png"
    static let logoFilename = "logo.png"

    mutating func touch() {
        updatedAt = Date()
    }
}

/// Session / draft meta for placeholders + logo frame (images stored as sibling files).
struct SequenceDraftMeta: Codable, Equatable {
    var placeholders: [SequencePlaceholder] = []
    var logoFrame: SequencePlaceholderFrame? = nil
    var hasBackground: Bool = false
    var hasLogo: Bool = false
}
