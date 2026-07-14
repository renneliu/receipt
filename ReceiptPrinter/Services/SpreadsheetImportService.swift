import Foundation

/// Imported spreadsheet (CSV / TSV / basic XLSX) for sequence printing.
struct SpreadsheetTable: Equatable {
    var headers: [String]
    var rows: [[String]]

    var isEmpty: Bool { headers.isEmpty || rows.isEmpty }

    func value(row: Int, column: String) -> String {
        guard let index = headers.firstIndex(of: column), rows.indices.contains(row) else { return "" }
        let cells = rows[row]
        guard cells.indices.contains(index) else { return "" }
        return cells[index]
    }
}

enum SpreadsheetImportError: LocalizedError {
    case unsupportedType
    case emptyFile
    case invalidXLSX
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "仅支持 CSV、TSV 或 .xlsx"
        case .emptyFile: return "表格为空"
        case .invalidXLSX: return "无法解析 Excel 文件"
        case .unzipFailed(let msg): return "解压 Excel 失败: \(msg)"
        }
    }
}

enum SpreadsheetImportService {
    static func load(from url: URL) throws -> SpreadsheetTable {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "csv", "txt":
            return try loadDelimited(from: url, delimiter: ",")
        case "tsv":
            return try loadDelimited(from: url, delimiter: "\t")
        case "xlsx":
            return try loadXLSX(from: url)
        default:
            throw SpreadsheetImportError.unsupportedType
        }
    }

    private static func loadDelimited(from url: URL, delimiter: Character) throws -> SpreadsheetTable {
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerLine = lines.first else { throw SpreadsheetImportError.emptyFile }
        let headers = parseCSVLine(headerLine, delimiter: delimiter).map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = lines.dropFirst().map { line in
            var cells = parseCSVLine(line, delimiter: delimiter)
            while cells.count < headers.count { cells.append("") }
            if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
            return cells
        }
        guard !headers.isEmpty else { throw SpreadsheetImportError.emptyFile }
        return SpreadsheetTable(headers: headers, rows: rows)
    }

    /// Minimal CSV parser with quotes.
    private static func parseCSVLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == delimiter {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    private static func loadXLSX(from url: URL) throws -> SpreadsheetTable {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", url.path, "-d", tmp.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SpreadsheetImportError.unzipFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let stringsURL = tmp.appendingPathComponent("xl/sharedStrings.xml")
        let sheetURL = tmp.appendingPathComponent("xl/worksheets/sheet1.xml")
        guard FileManager.default.fileExists(atPath: sheetURL.path) else {
            throw SpreadsheetImportError.invalidXLSX
        }

        let shared = FileManager.default.fileExists(atPath: stringsURL.path)
            ? try parseSharedStrings(XMLDocument(contentsOf: stringsURL, options: []))
            : []
        let sheetDoc = try XMLDocument(contentsOf: sheetURL, options: [])
        return try parseSheet(sheetDoc, sharedStrings: shared)
    }

    private static func parseSharedStrings(_ doc: XMLDocument) -> [String] {
        guard let root = doc.rootElement() else { return [] }
        var result: [String] = []
        let nodes = (try? root.nodes(forXPath: ".//*[local-name()='si']")) as? [XMLElement] ?? []
        for si in nodes {
            let texts = ((try? si.nodes(forXPath: ".//*[local-name()='t']")) ?? []).compactMap(\.stringValue)
            result.append(texts.joined())
        }
        return result
    }

    private static func parseSheet(_ doc: XMLDocument, sharedStrings: [String]) throws -> SpreadsheetTable {
        guard let root = doc.rootElement() else { throw SpreadsheetImportError.invalidXLSX }
        let rows = (try? root.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']")) as? [XMLElement] ?? []
        var matrix: [[String]] = []
        for row in rows {
            let cells = (try? row.nodes(forXPath: "./*[local-name()='c']")) as? [XMLElement] ?? []
            guard !cells.isEmpty else { continue }
            var maxCol = 0
            var values: [Int: String] = [:]
            for cell in cells {
                guard let ref = cell.attribute(forName: "r")?.stringValue else { continue }
                let col = columnIndex(from: ref)
                maxCol = max(maxCol, col)
                let type = cell.attribute(forName: "t")?.stringValue
                let raw = ((try? cell.nodes(forXPath: "./*[local-name()='v']")) as? [XMLElement])?
                    .first?.stringValue ?? ""
                if type == "s", let idx = Int(raw), sharedStrings.indices.contains(idx) {
                    values[col] = sharedStrings[idx]
                } else if type == "inlineStr" {
                    let texts = ((try? cell.nodes(forXPath: ".//*[local-name()='t']")) ?? []).compactMap(\.stringValue)
                    values[col] = texts.joined()
                } else {
                    values[col] = raw
                }
            }
            var line: [String] = []
            for i in 0...maxCol {
                line.append(values[i] ?? "")
            }
            if line.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                matrix.append(line)
            }
        }
        guard let header = matrix.first else { throw SpreadsheetImportError.emptyFile }
        let width = header.count
        let body = matrix.dropFirst().map { row -> [String] in
            var r = row
            while r.count < width { r.append("") }
            return Array(r.prefix(width))
        }
        return SpreadsheetTable(headers: header, rows: Array(body))
    }

    /// A1 → 0, B1 → 1, …
    private static func columnIndex(from cellRef: String) -> Int {
        let letters = cellRef.prefix { $0.isLetter }
        var index = 0
        for ch in letters.uppercased() {
            index = index * 26 + Int(ch.asciiValue! - Character("A").asciiValue!) + 1
        }
        return max(0, index - 1)
    }
}

enum QuickPrintMerge {
    /// Replace `{{name}}` tokens using a dictionary (exact key match).
    static func apply(_ template: String, values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    static func apply(_ attributed: NSAttributedString, values: [String: String]) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let plain = mutable.string as NSString
        // Replace from end so ranges stay valid
        let pattern = #"\{\{([^{}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        let matches = regex.matches(in: mutable.string, range: NSRange(location: 0, length: plain.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let keyRange = Range(match.range(at: 1), in: mutable.string) else { continue }
            let key = String(mutable.string[keyRange]).trimmingCharacters(in: .whitespaces)
            let replacement = values[key] ?? ""
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable
    }
}
