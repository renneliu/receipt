import AppKit
import Foundation

/// Composes rich-text body + column-bound placeholder boxes onto a character grid,
/// then emits an attributed string for the native GBK print path (not whole-page GS v 0).
enum SequenceLayoutComposer {
    struct Metrics: Equatable {
        var columns: Int
        var unitWidth: CGFloat
        var lineHeight: CGFloat
        var contentOriginX: CGFloat
        var contentOriginY: CGFloat
    }

    static func metrics(
        config: PrinterConfig,
        fontSize: CGFloat,
        paperWidthPoints: CGFloat
    ) -> Metrics {
        let size = RichTextPrintRenderer.textSize(forPointSize: fontSize)
        let cols = RichTextPrintRenderer.effectiveColumns(for: size, config: config)
        let inset = AttributedTextView.editorInsetWidth
        let padding = AttributedTextView.editorLineFragmentPadding
        let contentWidth = max(1, paperWidthPoints - inset * 2 - padding * 2)
        let unit = contentWidth / CGFloat(max(cols, 1))
        let font = AttributedTextView.editorFont(ofSize: fontSize)
        // Match NSTextView monospaced line pitch (~pointSize); larger metrics mapped
        // boxes one row above labels (log: 姓名 frameY≈100 → row 2 while body label on line 3).
        let lineHeight = max(20, ceil(font.pointSize))
        return Metrics(
            columns: cols,
            unitWidth: unit,
            lineHeight: lineHeight,
            contentOriginX: inset + padding,
            contentOriginY: 12
        )
    }

    static func gridRect(
        for frame: SequencePlaceholderFrame,
        metrics: Metrics
    ) -> (col: Int, row: Int, maxCols: Int, maxLines: Int) {
        let localX = frame.x - metrics.contentOriginX
        let localY = frame.y - metrics.contentOriginY
        let col = max(0, Int(floor(localX / metrics.unitWidth)))
        let row = max(0, Int(floor(localY / metrics.lineHeight)))
        let maxCols = max(1, Int(floor(frame.width / metrics.unitWidth)))
        let maxLines = max(1, Int(floor(frame.height / metrics.lineHeight)))
        let clampedCols = min(maxCols, max(1, metrics.columns - col))
        return (col, row, clampedCols, maxLines)
    }

    /// Merge `{{col}}` in body, paint truncated placeholder values into a column grid, return print-ready text.
    static func compose(
        body: NSAttributedString,
        placeholders: [SequencePlaceholder],
        values: [String: String],
        config: PrinterConfig,
        fontSize: CGFloat,
        paperWidthPoints: CGFloat
    ) -> NSAttributedString {
        let mergedBody = QuickPrintMerge.apply(body, values: values)
        let m = metrics(config: config, fontSize: fontSize, paperWidthPoints: paperWidthPoints)
        let layout = RichTextPrintRenderer.layoutLines(from: mergedBody, config: config)

        var rows: [String] = layout.compactMap { line in
            switch line {
            case .text(let string, _, _, _, _): return string
            case .blank: return ""
            case .divider(let kind):
                return makeDividerLine(columns: m.columns, dashed: kind == .dashed)
            }
        }

        if rows.isEmpty { rows = [""] }

        // WYSIWYG: paint each box into the shared character grid at its (col,row).
        // Only the box column span is cleared — body text outside that span stays.
        let sorted = placeholders.sorted { $0.zIndex < $1.zIndex }
        for box in sorted {
            let key = box.bindingKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let raw = values[key] ?? ""
            let grid = gridRect(for: box.frame, metrics: m)
            let needed = grid.row + grid.maxLines
            while rows.count < needed { rows.append("") }
            let wrapped = ReceiptTextLayout.wrap(raw, maxColumns: grid.maxCols, asciiAsDoubleWidth: false)
            let lines = Array(wrapped.prefix(grid.maxLines))
            for (i, fragment) in lines.enumerated() {
                let r = grid.row + i
                rows[r] = paint(
                    into: rows[r],
                    startCol: grid.col,
                    maxCols: grid.maxCols,
                    text: fragment,
                    totalColumns: m.columns
                )
            }
        }

        var outputRows = rows.map { truncateToColumns($0, maxColumns: m.columns) }
        while outputRows.count > 1,
              outputRows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            outputRows.removeLast()
        }
        let joined = outputRows.joined(separator: "\n")
        let attrs = AttributedTextView.defaultTypingAttributes(fontSize: fontSize)
        return NSAttributedString(string: joined, attributes: attrs)
    }

    /// Paint free-form text overlays (e.g. Quick Print auto-number) into the character grid
    /// so they print with native GBK on the same lines as body text — never as GS v 0 ink.
    static func composeTextOverlays(
        body: NSAttributedString,
        overlays: [RichTextPrintRenderer.SequenceTextOverlay],
        config: PrinterConfig,
        fontSize: CGFloat,
        paperWidthPoints: CGFloat
    ) -> NSAttributedString {
        guard !overlays.isEmpty else { return body }
        let m = metrics(config: config, fontSize: fontSize, paperWidthPoints: paperWidthPoints)
        let layout = RichTextPrintRenderer.layoutLines(from: body, config: config)
        var rows: [String] = layout.compactMap { line in
            switch line {
            case .text(let string, _, _, _, _): return string
            case .blank: return ""
            case .divider(let kind):
                return makeDividerLine(columns: m.columns, dashed: kind == .dashed)
            }
        }
        if rows.isEmpty { rows = [""] }

        for overlay in overlays where !overlay.text.isEmpty {
            let grid = gridRect(for: overlay.frame, metrics: m)
            let needed = grid.row + grid.maxLines
            while rows.count < needed { rows.append("") }
            let wrapped = ReceiptTextLayout.wrap(overlay.text, maxColumns: grid.maxCols, asciiAsDoubleWidth: false)
            let lines = Array(wrapped.prefix(grid.maxLines))
            for (i, fragment) in lines.enumerated() {
                let r = grid.row + i
                rows[r] = paint(
                    into: rows[r],
                    startCol: grid.col,
                    maxCols: grid.maxCols,
                    text: fragment,
                    totalColumns: m.columns
                )
            }
        }

        var outputRows = rows.map { truncateToColumns($0, maxColumns: m.columns) }
        while outputRows.count > 1,
              outputRows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            outputRows.removeLast()
        }
        let joined = outputRows.joined(separator: "\n")
        let attrs = AttributedTextView.defaultTypingAttributes(fontSize: fontSize)
        return NSAttributedString(string: joined, attributes: attrs)
    }

    /// Clear character cells covered by logo frames so native text does not collide with GS v 0 logos.
    static func clearFrames(
        body: NSAttributedString,
        frames: [SequencePlaceholderFrame],
        config: PrinterConfig,
        fontSize: CGFloat,
        paperWidthPoints: CGFloat
    ) -> NSAttributedString {
        guard !frames.isEmpty else { return body }
        let m = metrics(config: config, fontSize: fontSize, paperWidthPoints: paperWidthPoints)
        let layout = RichTextPrintRenderer.layoutLines(from: body, config: config)
        var rows: [String] = layout.compactMap { line in
            switch line {
            case .text(let string, _, _, _, _): return string
            case .blank: return ""
            case .divider(let kind):
                return makeDividerLine(columns: m.columns, dashed: kind == .dashed)
            }
        }
        if rows.isEmpty { rows = [""] }
        for frame in frames {
            let grid = gridRect(for: frame, metrics: m)
            let needed = grid.row + max(1, grid.maxLines)
            while rows.count < needed { rows.append("") }
            for r in grid.row..<(grid.row + max(1, grid.maxLines)) where r < rows.count {
                rows[r] = paint(
                    into: rows[r],
                    startCol: grid.col,
                    maxCols: grid.maxCols,
                    text: "",
                    totalColumns: m.columns
                )
            }
        }
        var outputRows = rows.map { truncateToColumns($0, maxColumns: m.columns) }
        while outputRows.count > 1,
              outputRows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            outputRows.removeLast()
        }
        let attrs = AttributedTextView.defaultTypingAttributes(fontSize: fontSize)
        return NSAttributedString(string: outputRows.joined(separator: "\n"), attributes: attrs)
    }

    /// Truncate/pad a cell value for on-canvas preview inside a box.
    static func previewText(
        value: String,
        frame: SequencePlaceholderFrame,
        config: PrinterConfig,
        fontSize: CGFloat,
        paperWidthPoints: CGFloat
    ) -> String {
        let m = metrics(config: config, fontSize: fontSize, paperWidthPoints: paperWidthPoints)
        let grid = gridRect(for: frame, metrics: m)
        let wrapped = ReceiptTextLayout.wrap(value, maxColumns: grid.maxCols, asciiAsDoubleWidth: false)
        return Array(wrapped.prefix(grid.maxLines)).joined(separator: "\n")
    }

    // MARK: - Column paint helpers

    private static func paint(
        into line: String,
        startCol: Int,
        maxCols: Int,
        text: String,
        totalColumns: Int
    ) -> String {
        var units = toColumnUnits(line)
        while units.count < totalColumns { units.append(" ") }
        if units.count > totalColumns { units = Array(units.prefix(totalColumns)) }

        let end = min(totalColumns, startCol + maxCols)
        guard startCol < end else { return fromColumnUnits(units) }
        for i in startCol..<end { units[i] = " " }

        var cursor = startCol
        for ch in text {
            let w = ReceiptTextLayout.displayWidth(String(ch), asciiAsDoubleWidth: false)
            if cursor + w > end { break }
            if w == 2 {
                if cursor + 1 >= end { break }
                units[cursor] = String(ch)
                units[cursor + 1] = "" // continuation marker occupied by wide char
                cursor += 2
            } else {
                units[cursor] = String(ch)
                cursor += 1
            }
        }
        return fromColumnUnits(units)
    }

    /// Expand string into per-column slots (wide chars occupy slot + empty continuation).
    private static func toColumnUnits(_ string: String) -> [String] {
        var units: [String] = []
        for ch in string {
            let w = ReceiptTextLayout.displayWidth(String(ch), asciiAsDoubleWidth: false)
            units.append(String(ch))
            if w == 2 { units.append("") }
        }
        return units
    }

    private static func fromColumnUnits(_ units: [String]) -> String {
        var result = ""
        var i = 0
        while i < units.count {
            let u = units[i]
            if u.isEmpty {
                i += 1
                continue
            }
            result.append(contentsOf: u)
            let w = ReceiptTextLayout.displayWidth(u, asciiAsDoubleWidth: false)
            i += max(1, w)
        }
        return result
    }

    private static func truncateToColumns(_ string: String, maxColumns: Int) -> String {
        var out = ""
        var width = 0
        for ch in string {
            let w = ReceiptTextLayout.displayWidth(String(ch), asciiAsDoubleWidth: false)
            if width + w > maxColumns { break }
            out.append(ch)
            width += w
        }
        return out
    }

    private static func makeDividerLine(columns: Int, dashed: Bool) -> String {
        ReceiptTextLayout.dividerLine(columns: columns, dashed: dashed)
    }
}
