import Foundation

enum PrintError: LocalizedError {
    case noPrinterSelected
    case printerNotFound(String)
    case processFailed(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noPrinterSelected: return "未选择打印机"
        case .printerNotFound(let name): return "找不到打印机: \(name)"
        case .processFailed(let msg): return "打印失败: \(msg)"
        case .writeFailed: return "写入打印数据失败"
        }
    }
}

struct CUPSPrintService {
    func listPrinters() throws -> [String] {
        let output = try runCommand(executable: "/usr/bin/lpstat", arguments: ["-p"])
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("printer ") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return String(parts[1])
        }
    }

    func printRaw(printerName: String, data: Data) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-\(UUID().uuidString).bin")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        process.arguments = ["-d", printerName, "-o", "raw", tempURL.path]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "未知错误"
            throw PrintError.processFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func runCommand(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
