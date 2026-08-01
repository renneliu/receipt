import Foundation

/// Isolates App Store builds from the local/dev Application Support tree.
///
/// - Local / debug (`dist/ReceiptPrinter.app`): `~/Library/Application Support/ReceiptPrinter`
/// - App Store (`-DAPPSTORE`, `dist/ReceiptPrinterStore.app`): `…/ReceiptPrinterStore`
enum AppPaths {
    /// Folder name under Application Support.
    static var supportFolderName: String {
        #if APPSTORE
        "ReceiptPrinterStore"
        #else
        "ReceiptPrinter"
        #endif
    }

    static var applicationSupportRoot: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let root = appSupport.appendingPathComponent(supportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func subdirectory(_ name: String) -> URL {
        let url = applicationSupportRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    #if APPSTORE
    static let isAppStoreBuild = true
    #else
    static let isAppStoreBuild = false
    #endif
}
