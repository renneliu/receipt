import Foundation

enum POSExcelLookupService {
    /// Resolve security-scoped bookmark and load spreadsheet for a template.
    static func loadTable(for template: POSReceiptTemplate) throws -> SpreadsheetTable {
        guard let bookmark = template.excelBookmarkData else {
            throw POSExcelLookupError.noExcel
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try SpreadsheetImportService.load(from: url)
    }

    static func makeBookmark(from url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Find first row whose mapped code column equals `code` (trimmed, case-sensitive).
    static func lookup(
        code: String,
        table: SpreadsheetTable,
        map: POSExcelColumnMap
    ) -> POSLineItem? {
        let needle = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let codeHeader = map.codeHeader, !codeHeader.isEmpty else { return nil }
        guard let codeIdx = table.headers.firstIndex(of: codeHeader) else { return nil }

        for row in table.rows {
            let cell = codeIdx < row.count ? row[codeIdx] : ""
            if cell.trimmingCharacters(in: .whitespacesAndNewlines) == needle {
                return POSLineItem(
                    code: needle,
                    name: value(row: row, headers: table.headers, header: map.nameHeader),
                    quantity: value(row: row, headers: table.headers, header: map.quantityHeader),
                    amount: value(row: row, headers: table.headers, header: map.amountHeader)
                )
            }
        }
        return nil
    }

    private static func value(row: [String], headers: [String], header: String?) -> String {
        guard let header, !header.isEmpty,
              let idx = headers.firstIndex(of: header),
              idx < row.count else { return "" }
        return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum POSExcelLookupError: LocalizedError {
    case noExcel

    var errorDescription: String? {
        switch self {
        case .noExcel: return "当前模板未绑定 Excel"
        }
    }
}
