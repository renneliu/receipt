import CryptoKit
import Foundation

/// Persists diagnostic records (index.json) and the exact per-job artifact files.
/// Thread-safe file I/O; safe to call from the `PrintController` actor's executor.
struct PrintDiagnosticStore: Sendable {
    let rootDirectory: URL
    private let indexURL: URL

    init() {
        let dir = AppPaths.subdirectory("PrintDiagnostics")
        rootDirectory = dir
        indexURL = dir.appendingPathComponent("index.json")
    }

    func folder(for id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Index

    func loadAll() -> [PrintDiagnosticRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([PrintDiagnosticRecord].self, from: data)) ?? []
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func saveIndex(_ records: [PrintDiagnosticRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func upsert(_ record: PrintDiagnosticRecord) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == record.id }) {
            all[idx] = record
        } else {
            all.append(record)
        }
        saveIndex(all)
    }

    // MARK: - Artifacts

    /// Writes every artifact file for one job into its own folder and returns the record's
    /// per-job metadata written to disk. Called ONCE, before/around transmission.
    func writeArtifacts(id: String, artifacts: PrintArtifacts) {
        let dir = folder(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try? artifacts.sourceText.data(using: .utf8)?.write(to: dir.appendingPathComponent("source-content.txt"))
        if let rtfd = artifacts.attributedRTFD {
            try? rtfd.write(to: dir.appendingPathComponent("attributed-content.rtfd"))
        }
        try? artifacts.pngData.write(to: dir.appendingPathComponent("final-rendered-image.png"))
        try? artifacts.rasterData.write(to: dir.appendingPathComponent("monochrome-raster.bin"))
        try? artifacts.payload.write(to: dir.appendingPathComponent("complete-escpos-payload.bin"))
        try? Self.hexPreview(artifacts.payload).data(using: .utf8)?
            .write(to: dir.appendingPathComponent("payload-hex-preview.txt"))
    }

    func writeTransportLog(id: String, text: String) {
        let dir = folder(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent("transport-log.txt"))
    }

    func writeMetadata(_ record: PrintDiagnosticRecord) {
        let dir = folder(for: record.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: dir.appendingPathComponent("metadata.json"))
        }
    }

    func payload(for id: String) -> Data? {
        try? Data(contentsOf: folder(for: id).appendingPathComponent("complete-escpos-payload.bin"))
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveIndex(all)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hexPreview(_ data: Data, maxBytes: Int = 4096) -> String {
        let bytes = Array(data.prefix(maxBytes))
        var lines: [String] = []
        for chunk in stride(from: 0, to: bytes.count, by: 16) {
            let end = min(chunk + 16, bytes.count)
            let row = bytes[chunk..<end]
            var hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            hex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = row.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %@  %@", chunk, hex, ascii))
        }
        if data.count > maxBytes {
            lines.append("... (\(data.count - maxBytes) more bytes truncated)")
        }
        return lines.joined(separator: "\n")
    }
}
