import AppKit
import Foundation
import AuthenticationServices

enum GmailAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case tokenExchangeFailed(String)
    case noRefreshToken
    case redirectURIMismatch(expected: String)
    case testUserAccessDenied
    case missingClientCredentials

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置 Google Client ID 和 Secret"
        case .cancelled: return "授权已取消"
        case .tokenExchangeFailed(let msg): return "获取 Token 失败: \(msg)"
        case .noRefreshToken: return "无 Refresh Token，请重新授权"
        case .missingClientCredentials:
            return "设置中的 Google Client ID 或 Secret 为空。请在「设置」重新填写，然后在 Gmail 页断开并重新连接。"
        case .testUserAccessDenied: return GmailOAuthConfig.testUserAccessDeniedMessage
        case .redirectURIMismatch(let expected):
            return """
            Google 报错 redirect_uri_mismatch：重定向 URI 与 OAuth 客户端类型不匹配。

            本应用使用回环地址：\(expected)
            请在 Google Cloud 创建「桌面应用」OAuth 客户端（Web 应用只接受 http/https，不能填自定义 scheme）。

            \(GmailOAuthConfig.googleConsoleSteps)
            """
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
        let normalizedRedirect = GmailOAuthConfig.normalizedRedirectURI(redirectURI)
        let callbackScheme = GmailOAuthConfig.callbackURLScheme(for: normalizedRedirect)
        let scope = "https://www.googleapis.com/auth/gmail.readonly"
        let authURL = URL(string:
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=\(clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientID)&redirect_uri=\(normalizedRedirect.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? normalizedRedirect)&response_type=code&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope)&access_type=offline&prompt=consent"
        )!

        let code: String
        if GmailOAuthConfig.isLoopbackRedirect(normalizedRedirect) {
            code = try await signInWithLoopbackServer(
                authURL: authURL,
                port: GmailOAuthConfig.loopbackPort(from: normalizedRedirect),
                normalizedRedirect: normalizedRedirect
            )
        } else {
            code = try await signInWithWebSession(
                authURL: authURL,
                callbackScheme: callbackScheme,
                normalizedRedirect: normalizedRedirect
            )
        }

        try await exchangeCode(code, clientID: clientID, clientSecret: clientSecret, redirectURI: normalizedRedirect)
    }

    private func signInWithLoopbackServer(authURL: URL, port: UInt16, normalizedRedirect: String) async throws -> String {
        let server = OAuthLoopbackServer(port: port)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await server.waitForAuthorizationCode()
            }
            group.addTask { @MainActor in
                try await self.presentWebAuthSession(
                    authURL: authURL,
                    callbackScheme: GmailOAuthConfig.callbackURLScheme(for: normalizedRedirect),
                    normalizedRedirect: normalizedRedirect
                )
            }
            defer {
                group.cancelAll()
                server.stop()
                authSession?.cancel()
            }
            guard let code = try await group.next() else {
                throw GmailAuthError.cancelled
            }
            return code
        }
    }

    private func signInWithWebSession(authURL: URL, callbackScheme: String, normalizedRedirect: String) async throws -> String {
        try await presentWebAuthSession(
            authURL: authURL,
            callbackScheme: callbackScheme,
            normalizedRedirect: normalizedRedirect
        )
    }

    private func presentWebAuthSession(authURL: URL, callbackScheme: String, normalizedRedirect: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.authSession = nil
                if let error {
                    let desc = error.localizedDescription
                    if desc.localizedCaseInsensitiveContains("redirect_uri_mismatch")
                        || desc.localizedCaseInsensitiveContains("invalid request") {
                        continuation.resume(throwing: GmailAuthError.redirectURIMismatch(expected: normalizedRedirect))
                    } else if (error as NSError).domain == ASWebAuthenticationSessionErrorDomain,
                              (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: GmailAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    if let callbackURL,
                       let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                       let oauthError = components.queryItems?.first(where: { $0.name == "error" })?.value {
                        if oauthError == "redirect_uri_mismatch" {
                            continuation.resume(throwing: GmailAuthError.redirectURIMismatch(expected: normalizedRedirect))
                            return
                        }
                        if oauthError == "access_denied" {
                            continuation.resume(throwing: GmailAuthError.testUserAccessDenied)
                            return
                        }
                    }
                    continuation.resume(throwing: GmailAuthError.cancelled)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            self.authSession = session
            if !session.start() {
                continuation.resume(throwing: GmailAuthError.cancelled)
            }
        }
    }

    func signOut() {
        tokens = nil
        isAuthenticated = false
        accountEmail = nil
        KeychainHelper.delete(key: keychainKey)
    }

    func validAccessToken(clientID: String, clientSecret: String) async throws -> String {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var current = tokens else { throw GmailAuthError.notConfigured }
        if current.expiresAt.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else {
            throw GmailAuthError.missingClientCredentials
        }
        guard let refresh = current.refreshToken else { throw GmailAuthError.noRefreshToken }
        current = try await refreshToken(refresh, clientID: trimmedID, clientSecret: trimmedSecret)
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
        let body = [
            "refresh_token": refresh,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            if raw.localizedCaseInsensitiveContains("Could not determine client ID") {
                throw GmailAuthError.missingClientCredentials
            }
            throw GmailAuthError.tokenExchangeFailed(raw)
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
