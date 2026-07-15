import Foundation

enum POSExcelLookupService {
    struct ResolvedExcelURL {
        let url: URL
        let isStale: Bool
        let usedSecurityScope: Bool
    }

    /// App is not sandboxed (`com.apple.security.app-sandbox` = false). Security-scoped
    /// bookmarks often fail to resolve with Cocoa "incorrect format"; prefer plain bookmarks
    /// and fall back across resolution options for older saved bindings.
    static func resolveBookmark(_ bookmark: Data) throws -> ResolvedExcelURL {
        var lastError: Error?
        let attempts: [(URL.BookmarkResolutionOptions, Bool)] = [
            ([.withSecurityScope], true),
            ([], false)
        ]
        for (options, securityScoped) in attempts {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: options,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return ResolvedExcelURL(url: url, isStale: isStale, usedSecurityScope: securityScoped)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? POSExcelLookupError.noExcel
    }

    /// Resolve bookmark and load spreadsheet for a template.
    static func loadTable(for template: POSReceiptTemplate) throws -> SpreadsheetTable {
        guard let bookmark = template.excelBookmarkData else {
            throw POSExcelLookupError.noExcel
        }
        let resolved = try resolveBookmark(bookmark)
        let accessed = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if accessed { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try SpreadsheetImportService.load(from: resolved.url)
    }

    static func makeBookmark(from url: URL) throws -> Data {
        // Prefer plain bookmarks — security-scoped ones break when the app is not sandboxed.
        if let plain = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return plain
        }
        return try url.bookmarkData(
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

    /// One catalog row per spreadsheet row with a non-empty mapped 项目名称.
    static func catalogEntries(table: SpreadsheetTable, map: POSExcelColumnMap) -> [POSExcelCatalogEntry] {
        guard let nameHeader = map.nameHeader, !nameHeader.isEmpty,
              table.headers.contains(nameHeader) else { return [] }
        return table.rows.enumerated().compactMap { index, row in
            let name = value(row: row, headers: table.headers, header: map.nameHeader)
            guard !name.isEmpty else { return nil }
            return POSExcelCatalogEntry(
                rowIndex: index,
                item: POSLineItem(
                    code: value(row: row, headers: table.headers, header: map.codeHeader),
                    name: name,
                    quantity: value(row: row, headers: table.headers, header: map.quantityHeader),
                    amount: value(row: row, headers: table.headers, header: map.amountHeader)
                )
            )
        }
    }

    static func row(at index: Int, table: SpreadsheetTable, map: POSExcelColumnMap) -> POSLineItem? {
        guard index >= 0, index < table.rows.count else { return nil }
        let row = table.rows[index]
        let name = value(row: row, headers: table.headers, header: map.nameHeader)
        guard !name.isEmpty else { return nil }
        return POSLineItem(
            code: value(row: row, headers: table.headers, header: map.codeHeader),
            name: name,
            quantity: value(row: row, headers: table.headers, header: map.quantityHeader),
            amount: value(row: row, headers: table.headers, header: map.amountHeader)
        )
    }
}

struct POSExcelCatalogEntry: Identifiable, Equatable, Sendable {
    var id: Int { rowIndex }
    let rowIndex: Int
    let item: POSLineItem

    var buttonTitle: String { item.name }
}

enum POSExcelLookupError: LocalizedError {
    case noExcel

    var errorDescription: String? {
        switch self {
        case .noExcel: return "当前模板未绑定 Excel"
        }
    }
}
