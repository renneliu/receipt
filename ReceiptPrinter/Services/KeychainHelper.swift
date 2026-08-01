import Foundation
import Security

/// Local secrets store (Application Support).
///
/// Unsigned / frequently rebuilt `.app` bundles change their code directory hash on every
/// build, so macOS Keychain ACLs no longer match and the "wants to use your confidential
/// information" dialog appears on every launch. File storage under Application Support
/// avoids Keychain entirely while keeping secrets off UserDefaults.
enum KeychainHelper {
    private static let service = "com.receiptprinter.app"

    private static var secretsDirectory: URL {
        AppPaths.subdirectory("Secrets")
    }

    private static func fileURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return secretsDirectory.appendingPathComponent("\(safe).bin")
    }

    static func save(key: String, data: Data) {
        let url = fileURL(for: key)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        deleteLegacyKeychainItem(key: key)
    }

    static func load(key: String) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    static func delete(key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
        deleteLegacyKeychainItem(key: key)
    }

    /// Best-effort cleanup of pre-1.1 Keychain entries. Does not read them (avoids the unlock dialog).
    static func abandonLegacyKeychainItems() {
        deleteLegacyKeychainItem(key: "ReceiptPrinter.GmailTokens")
        deleteLegacyKeychainItem(key: "ReceiptPrinter.TMDBAPIKey")
    }

    private static func deleteLegacyKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var withService = query
        withService[kSecAttrService as String] = service
        SecItemDelete(withService as CFDictionary)
    }
}
