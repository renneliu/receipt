import AppKit
import Foundation
import AuthenticationServices

enum GmailAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case tokenExchangeFailed(String)
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置 Google Client ID 和 Secret"
        case .cancelled: return "授权已取消"
        case .tokenExchangeFailed(let msg): return "获取 Token 失败: \(msg)"
        case .noRefreshToken: return "无 Refresh Token，请重新授权"
        }
    }
}

struct GmailTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String?
}

@MainActor
final class GmailAuthService: NSObject, ObservableObject {
    @Published var isAuthenticated = false
    @Published var accountEmail: String?

    private var tokens: GmailTokens?
    private var authSession: ASWebAuthenticationSession?
    private let keychainKey = "ReceiptPrinter.GmailTokens"

    override init() {
        super.init()
        loadTokens()
    }

    func signIn(clientID: String, clientSecret: String, redirectURI: String) async throws {
        guard !clientID.isEmpty else { throw GmailAuthError.notConfigured }
        let scope = "https://www.googleapis.com/auth/gmail.readonly"
        let authURL = URL(string:
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=\(clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientID)&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)&response_type=code&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope)&access_type=offline&prompt=consent"
        )!

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: URL(string: redirectURI)?.scheme) { [weak self] callbackURL, error in
                self?.authSession = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: GmailAuthError.cancelled)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            self.authSession = session
            session.start()
        }

        try await exchangeCode(code, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI)
    }

    func signOut() {
        tokens = nil
        isAuthenticated = false
        accountEmail = nil
        KeychainHelper.delete(key: keychainKey)
    }

    func validAccessToken(clientID: String, clientSecret: String) async throws -> String {
        guard var current = tokens else { throw GmailAuthError.notConfigured }
        if current.expiresAt.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        guard let refresh = current.refreshToken else { throw GmailAuthError.noRefreshToken }
        current = try await refreshToken(refresh, clientID: clientID, clientSecret: clientSecret)
        tokens = current
        saveTokens()
        return current.accessToken
    }

    private func exchangeCode(_ code: String, clientID: String, clientSecret: String, redirectURI: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw GmailAuthError.tokenExchangeFailed(msg)
        }
        tokens = GmailTokens(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: nil
        )
        saveTokens()
        isAuthenticated = true
    }

    private func refreshToken(_ refresh: String, clientID: String, clientSecret: String) async throws -> GmailTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "refresh_token=\(refresh)&client_id=\(clientID)&client_secret=\(clientSecret)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw GmailAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return GmailTokens(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: tokens?.email
        )
    }

    private func loadTokens() {
        guard let data = KeychainHelper.load(key: keychainKey),
              let saved = try? JSONDecoder().decode(GmailTokens.self, from: data) else { return }
        tokens = saved
        isAuthenticated = true
        accountEmail = saved.email
    }

    private func saveTokens() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        KeychainHelper.save(key: keychainKey, data: data)
        isAuthenticated = true
    }
}

extension GmailAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

enum KeychainHelper {
    static func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
