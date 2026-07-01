import Foundation

enum DebugLog {
    static let path = "/Users/xiaoyuliu/Projects/ReceiptPrinter/.cursor/debug-cc81de.log"

    static func write(hypothesisId: String, location: String, message: String, data: [String: String] = [:]) {
        // #region agent log
        var payload: [String: Any] = [
            "sessionId": "cc81de",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if !data.isEmpty { payload["data"] = data }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            try? (line + "\n").write(to: url, atomically: false, encoding: .utf8)
        }
        // #endregion
    }
}
