import Foundation

final class QuickPrintStore {
    private let fileURL: URL

    init(filename: String = "quick-print.rtfd") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(filename, isDirectory: true)
    }

    func load() -> NSAttributedString? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? NSAttributedString(
            url: fileURL,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
    }

    func save(_ attributedString: NSAttributedString) {
        try? FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let range = NSRange(location: 0, length: attributedString.length)
        if let data = try? attributedString.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) {
            let temp = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".tmp")
            try? data.write(to: temp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
