import Foundation

enum GmailOAuthConfig {
    /// Loopback redirect for Google「桌面应用」OAuth client (ASWebAuthenticationSession + callbackURLScheme "http").
    static let defaultRedirectURI = "http://127.0.0.1:8765/"
    static let defaultLoopbackPort: UInt16 = 8765

    /// Legacy custom-scheme redirect; Google Web clients reject it, Desktop clients don't use it.
    static let legacyCustomSchemeRedirectURI = "com.receiptprinter:/oauth2redirect"

    static func callbackURLScheme(for redirectURI: String) -> String {
        URL(string: redirectURI.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme ?? "http"
    }

    static func normalizedRedirectURI(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == legacyCustomSchemeRedirectURI || trimmed.hasPrefix("com.receiptprinter:") {
            return defaultRedirectURI
        }
        return trimmed.isEmpty ? defaultRedirectURI : trimmed
    }

    static func isLoopbackRedirect(_ uri: String) -> Bool {
        let lower = uri.lowercased()
        return lower.hasPrefix("http://127.0.0.1") || lower.hasPrefix("http://localhost")
    }

    static func loopbackPort(from uri: String) -> UInt16 {
        if let port = URL(string: uri)?.port, port > 0, port <= Int(UInt16.max) {
            return UInt16(port)
        }
        return defaultLoopbackPort
    }

    /// Google「桌面应用」凭据自动接受 127.0.0.1 / localhost 回环地址，无需在 Console 手动登记重定向 URI。
    static let googleConsoleSteps = """
    1. Google Cloud → API 和服务 → 凭据
    2. 创建 OAuth 客户端 ID → 类型选「桌面应用」（不要选 iOS / Web 应用）
    3. 无需填写「已授权的重定向 URI」（桌面应用自动支持 http://127.0.0.1）
    4. 将 Client ID / Secret 填入本应用「设置」
    5. Redirect URI 保持默认：\(defaultRedirectURI)
    6. OAuth 同意屏幕 → 测试用户 → 添加你要登录的 Gmail 邮箱（见下方说明）
    """

    static let testUserAccessDeniedMessage = """
    Google 报错 403 access_denied：应用处于「测试」状态，当前 Google 账号不在测试用户列表中。

    解决步骤：
    1. Google Cloud Console → API 和服务 → OAuth 同意屏幕
    2. 确认发布状态为「测试中」（个人项目默认如此）
    3. 在「测试用户」→「添加用户」中填入你要登录的 Gmail 地址
    4. 保存后等待 1–2 分钟，再在应用中重新「连接 Gmail」

    注意：测试用户必须与你浏览器里选择的 Google 账号完全一致。
    """
}
