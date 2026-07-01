import Foundation
import Network

enum OAuthLoopbackError: LocalizedError {
    case portInUse(UInt16)
    case timedOut
    case invalidCallback

    var errorDescription: String? {
        switch self {
        case .portInUse(let port):
            return "无法在 127.0.0.1:\(port) 启动 OAuth 回调服务，端口可能被占用。"
        case .timedOut:
            return "等待 Google 授权超时，请重试。"
        case .invalidCallback:
            return "OAuth 回调无效。"
        }
    }
}

final class OAuthLoopbackServer {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(port: UInt16) {
        self.port = port
    }

    func waitForAuthorizationCode(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fail(with: OAuthLoopbackError.timedOut)
            }
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
    }

    private func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fail(with: OAuthLoopbackError.invalidCallback)
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            fail(with: OAuthLoopbackError.portInUse(port))
            return
        }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.fail(with: OAuthLoopbackError.portInUse(self?.port ?? 0))
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (code, oauthError) = Self.parseAuthorization(from: request)
            let body = "<html><body style=\"font-family:sans-serif;text-align:center;padding:48px\"><h1>授权成功</h1><p>可以关闭此窗口并返回 ReceiptPrinter。</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if let code {
                self.succeed(with: code)
            } else if oauthError == "access_denied" {
                self.fail(with: GmailAuthError.testUserAccessDenied)
            } else if let oauthError {
                self.fail(with: GmailAuthError.tokenExchangeFailed(oauthError))
            } else {
                self.fail(with: OAuthLoopbackError.invalidCallback)
            }
        }
    }

    private func succeed(with code: String) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(returning: code)
    }

    private func fail(with error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(throwing: error)
    }

    private static func parseAuthorization(from request: String) -> (code: String?, error: String?) {
        guard let firstLine = request.split(separator: "\n", maxSplits: 1).first else {
            return (nil, nil)
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return (nil, nil) }
        var pathAndQuery = String(parts[1])
        if !pathAndQuery.hasPrefix("/") { pathAndQuery = "/" + pathAndQuery }
        guard let url = URL(string: "http://127.0.0.1\(pathAndQuery)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil)
        }
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let error = components.queryItems?.first(where: { $0.name == "error" })?.value
        return (code, error)
    }
}
