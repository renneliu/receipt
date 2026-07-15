import CryptoKit
import Foundation

enum PrintError: LocalizedError {
    case noPrinterSelected
    case printerNotFound(String)
    case processFailed(String)
    case writeFailed
    case printerBusy(String)

    var errorDescription: String? {
        switch self {
        case .noPrinterSelected: return "未选择打印机"
        case .printerNotFound(let name): return "找不到打印机: \(name)"
        case .processFailed(let msg): return "打印失败: \(msg)"
        case .writeFailed: return "写入打印数据失败"
        case .printerBusy(let name): return "打印机忙碌或队列卡住: \(name)。请再试一次"
        }
    }
}

/// Byte-level transport result for one print job (fed into diagnostics).
struct PrintTransportResult {
    let payloadBytes: Int
    let diskBytes: Int
    let payloadSHA256: String
    let diskSHA256: String
    let integrityOK: Bool
    let padBytes: Int
    let lpExitCode: Int
    let stderr: String
    let didClearQueue: Bool
    let startedAt: Date
    let finishedAt: Date
    var writeDurationSeconds: Double { finishedAt.timeIntervalSince(startedAt) }
    var succeeded: Bool { integrityOK && lpExitCode == 0 }
}

struct CUPSPrintService {
    /// Tiny USB raw jobs can stall the POS-80 backend. Cap padding tightly —
    /// never pad with LF (0x0A): ~2000 LFs caused continuous paper feed (log evidence).
    /// Also never pad with raw `0x20`: after feed/cut that left the head mid-mode, trailing
    /// spaces were printed / desynced the next GBK job (diag `20260715-110113` 15-byte feed
    /// → +49 space pad; print after feed garbled despite clean `ESC d` payload).
    private static let tinyJobThreshold = 48
    private static let tinyJobPadTarget = 64
    /// Harmless filler: repeated `ESC @` resets toward a clean state for the next job.
    private static let tinyJobPadUnit: [UInt8] = [0x1B, 0x40]

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func listPrinters() throws -> [String] {
        let output = try runCommand(executable: "/usr/bin/lpstat", arguments: ["-p"])
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("printer ") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return String(parts[1])
        }
    }

    @discardableResult
    func clearQueue(printerName: String) -> String {
        (try? runCommand(executable: "/usr/bin/cancel", arguments: ["-a", printerName])) ?? ""
    }

    func hasActiveJobs(printerName: String) -> Bool {
        guard let out = try? runCommand(executable: "/usr/bin/lpstat", arguments: ["-o", printerName]) else {
            return false
        }
        return out.split(separator: "\n").contains { $0.contains(printerName) }
    }

    func waitUntilIdle(printerName: String, timeoutSeconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !hasActiveJobs(printerName: printerName) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !hasActiveJobs(printerName: printerName)
    }

    /// Thin throwing wrapper (legacy callers). Serialization is owned by `PrintController`.
    /// We NEVER auto-cancel an in-flight job — cancelling mid-raster truncates the payload
    /// and the tail is misread as commands (garble). `clearStuckJobsFirst` = explicit recovery only.
    func printRaw(printerName: String, data: Data, clearStuckJobsFirst: Bool = false) throws {
        let result = transmit(printerName: printerName, data: data, clearStuckJobsFirst: clearStuckJobsFirst)
        guard result.integrityOK else { throw PrintError.writeFailed }
        if result.lpExitCode != 0 {
            throw PrintError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Byte-exact transmission that reports a full transport result. Blocks the CALLING thread only
    /// for the (fast) `lp` spool — callers must invoke this off the main actor (see `PrintController`).
    /// No drain loop, no `Thread.sleep`: CUPS already serializes jobs per printer.
    func transmit(printerName: String, data: Data, clearStuckJobsFirst: Bool = false) -> PrintTransportResult {
        let startedAt = Date()

        var didClear = false
        if clearStuckJobsFirst {
            _ = clearQueue(printerName: printerName)
            didClear = true
        }

        var payload = data
        let padBytes: Int
        if payload.count < Self.tinyJobThreshold {
            var pad = Data()
            while payload.count + pad.count < Self.tinyJobPadTarget {
                pad.append(contentsOf: Self.tinyJobPadUnit)
            }
            padBytes = pad.count
            payload.append(pad)
        } else {
            padBytes = 0
        }

        let payloadSHA = Self.sha256Hex(payload)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-\(UUID().uuidString).bin")
        var diskBytes = 0
        var diskSHA = ""
        do {
            try payload.write(to: tempURL)
            let onDisk = (try? Data(contentsOf: tempURL)) ?? Data()
            diskBytes = onDisk.count
            diskSHA = Self.sha256Hex(onDisk)
        } catch {
            return PrintTransportResult(
                payloadBytes: payload.count, diskBytes: 0, payloadSHA256: payloadSHA, diskSHA256: "",
                integrityOK: false, padBytes: padBytes, lpExitCode: -1, stderr: error.localizedDescription,
                didClearQueue: didClear, startedAt: startedAt, finishedAt: Date()
            )
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let integrityOK = diskBytes == payload.count && diskSHA == payloadSHA
        guard integrityOK else {
            return PrintTransportResult(
                payloadBytes: payload.count, diskBytes: diskBytes, payloadSHA256: payloadSHA, diskSHA256: diskSHA,
                integrityOK: false, padBytes: padBytes, lpExitCode: -1, stderr: "payload integrity check failed",
                didClearQueue: didClear, startedAt: startedAt, finishedAt: Date()
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        process.arguments = [
            "-d", printerName,
            "-o", "raw",
            "-o", "document-format=application/vnd.cups-raw",
            tempURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        var exitCode = -1
        var stderr = ""
        do {
            try process.run()
            process.waitUntilExit()
            exitCode = Int(process.terminationStatus)
            if exitCode != 0 {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                stderr = String(data: errData, encoding: .utf8) ?? "未知错误"
            }
        } catch {
            stderr = error.localizedDescription
        }

        return PrintTransportResult(
            payloadBytes: payload.count, diskBytes: diskBytes, payloadSHA256: payloadSHA, diskSHA256: diskSHA,
            integrityOK: integrityOK, padBytes: padBytes, lpExitCode: exitCode, stderr: stderr,
            didClearQueue: didClear, startedAt: startedAt, finishedAt: Date()
        )
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
