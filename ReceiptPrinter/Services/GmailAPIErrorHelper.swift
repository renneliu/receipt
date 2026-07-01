import Foundation

enum GmailAPIErrorHelper {
    static func userMessage(for error: Error) -> String {
        userMessage(forAPIError: error.localizedDescription)
    }

    static func userMessage(forAPIError message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("gmail api has not been used") || lower.contains("gmail.googleapis.com") && lower.contains("disabled") {
            return """
            未启用 Gmail API。请在 Google Cloud Console 中：
            1. 打开 API 和服务 → 库
            2. 搜索「Gmail API」→ 启用
            3. 等待 1–2 分钟后重试同步
            （须与 OAuth 客户端同一项目）
            """
        }
        if lower.contains("insufficient permission") || lower.contains("access_not_configured") {
            return "Gmail 权限不足。请断开 Gmail 后重新连接，并确认 OAuth 范围包含 gmail.readonly。"
        }
        return message
    }
}
