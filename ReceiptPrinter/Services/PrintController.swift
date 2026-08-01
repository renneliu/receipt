import Foundation

/// The ONE place printer transmission happens. Being an `actor`, it runs off the main actor and
/// guarantees only a single job transmits at a time (manual print, template,
/// retries all await here). No `Thread.sleep`, no drain loop, no auto-repeat.
actor PrintController {
    private let service = CUPSPrintService()
    private let store = PrintDiagnosticStore()

    /// Proves serialization in logs: must never observe > 1.
    private var inFlight = 0
    /// Set after a raster cut so the next job settles briefly (CUPS idle alone was not enough).
    private var needsPostRasterSettle = false

    struct Config: Sendable {
        var printerName: String
        var connectionType: String
        var statusPollingWasActive: Bool
        var clearStuckJobsFirst: Bool
    }

    /// Transmit exactly ONE job, capturing full diagnostics. Returns the persisted record.
    @discardableResult
    func printOnce(config: Config, artifacts: PrintArtifacts) async -> PrintDiagnosticRecord {
        inFlight += 1
        let observedConcurrency = inFlight
        defer { inFlight -= 1 }

        let jobId = Self.makeJobId()
        store.writeArtifacts(id: jobId, artifacts: artifacts)

        let sourceSHA = PrintDiagnosticStore.sha256Hex(artifacts.sourceText.data(using: .utf8) ?? Data())
        let imageSHA = PrintDiagnosticStore.sha256Hex(artifacts.pngData)
        let rasterSHA = PrintDiagnosticStore.sha256Hex(artifacts.rasterData)
        let payloadSHA = PrintDiagnosticStore.sha256Hex(artifacts.payload)

        let headerValid: Bool
        if artifacts.usedRaster {
            let singleRasterOK = artifacts.rasterData.count == artifacts.expectedRasterBytes
                && artifacts.rasterWidthBytes * artifacts.rasterHeight == artifacts.expectedRasterBytes
                && artifacts.expectedRasterBytes > 0
            // Multi-page sequence jobs embed several GS v 0 blocks in `payload` and may only
            // attach the first page's raster for diagnostics.
            let embeddedRasterOK = artifacts.payload.count > 64
                && artifacts.payload.range(of: Data([0x1D, 0x76, 0x30])) != nil
            headerValid = singleRasterOK || embeddedRasterOK
        } else {
            // Native text jobs have no GS v 0 payload to validate.
            headerValid = true
        }

        var record = PrintDiagnosticRecord(
            id: jobId,
            createdAt: Date(),
            printerName: config.printerName,
            connectionType: config.connectionType,
            printerModelHint: artifacts.printerModelHint,
            dpi: artifacts.dpi,
            printableWidthDots: artifacts.printableWidthDots,
            renderMode: artifacts.renderMode,
            usedNativeText: artifacts.usedNativeText,
            usedRaster: artifacts.usedRaster,
            sourceTextPreview: String(artifacts.sourceText.prefix(200)),
            sourceSHA256: sourceSHA,
            imagePixelWidth: artifacts.imagePixelWidth,
            imagePixelHeight: artifacts.imagePixelHeight,
            imageSHA256: imageSHA,
            rasterWidthBytes: artifacts.rasterWidthBytes,
            rasterHeight: artifacts.rasterHeight,
            rasterBytes: artifacts.rasterData.count,
            rasterSHA256: rasterSHA,
            payloadBytes: artifacts.payload.count,
            payloadSHA256: payloadSHA,
            headerXL: artifacts.headerXL,
            headerXH: artifacts.headerXH,
            headerYL: artifacts.headerYL,
            headerYH: artifacts.headerYH,
            expectedRasterBytes: artifacts.expectedRasterBytes,
            headerValid: headerValid,
            writeCallCount: 1,
            diskBytes: 0,
            diskSHA256: "",
            payloadIntegrityOK: false,
            padBytes: 0,
            lpExitCode: -1,
            writeDurationSeconds: 0,
            didClearQueue: false,
            observedConcurrency: observedConcurrency,
            statusPollingPausedDuringJob: config.statusPollingWasActive,
            transportError: nil,
            result: .unknown,
            note: nil,
            artifactFolderPath: store.folder(for: jobId).path
        )

        // Refuse to transmit a malformed raster payload — save the diagnostics and stop.
        guard headerValid else {
            record.transportError = "raster header invalid: rasterBytes=\(artifacts.rasterData.count) expected=\(artifacts.expectedRasterBytes)"
            record.result = .failed
            store.writeTransportLog(id: jobId, text: Self.transportLog(record: record, result: nil))
            store.writeMetadata(record)
            store.upsert(record)
            return record
        }

        // Serialize against the previous CUPS job; return after send so UI is not blocked.
        _ = await service.waitUntilIdle(printerName: config.printerName, timeoutSeconds: 90)
        if needsPostRasterSettle {
            // Short cut-recovery settle; payload already has triple ESC@/FS. + white warmup.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            needsPostRasterSettle = false
        }

        let result = service.transmit(
            printerName: config.printerName,
            data: artifacts.payload,
            clearStuckJobsFirst: config.clearStuckJobsFirst
        )

        record.diskBytes = result.diskBytes
        record.diskSHA256 = result.diskSHA256
        record.payloadIntegrityOK = result.integrityOK
        record.padBytes = result.padBytes
        record.lpExitCode = result.lpExitCode
        record.writeDurationSeconds = result.writeDurationSeconds
        record.didClearQueue = result.didClearQueue
        if !result.succeeded {
            record.transportError = result.stderr.isEmpty ? "lp exit \(result.lpExitCode)" : result.stderr
        }

        store.writeTransportLog(id: jobId, text: Self.transportLog(record: record, result: result))
        store.writeMetadata(record)
        store.upsert(record)

        if artifacts.usedRaster {
            needsPostRasterSettle = true
        }

        return record
    }

    /// Serialized single transmission of a prebuilt payload (template / raw ESC/POS).
    /// Captures a lightweight record + payload artifact — no image/raster breakdown available here.
    @discardableResult
    func printRawOnce(config: Config, payload: Data, sourceLabel: String, renderMode: PrintRenderMode) async -> PrintDiagnosticRecord {
        inFlight += 1
        let observedConcurrency = inFlight
        defer { inFlight -= 1 }

        let jobId = Self.makeJobId()
        let dir = store.folder(for: jobId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? payload.write(to: dir.appendingPathComponent("complete-escpos-payload.bin"))
        try? PrintDiagnosticStore.hexPreview(payload).data(using: .utf8)?
            .write(to: dir.appendingPathComponent("payload-hex-preview.txt"))
        try? sourceLabel.data(using: .utf8)?.write(to: dir.appendingPathComponent("source-content.txt"))

        let payloadSHA = PrintDiagnosticStore.sha256Hex(payload)
        let usesRaster = payload.range(of: Data([0x1D, 0x76, 0x30])) != nil

        let result = service.transmit(printerName: config.printerName, data: payload, clearStuckJobsFirst: config.clearStuckJobsFirst)

        let record = PrintDiagnosticRecord(
            id: jobId, createdAt: Date(),
            printerName: config.printerName, connectionType: config.connectionType, printerModelHint: nil,
            dpi: 203, printableWidthDots: 0,
            renderMode: renderMode, usedNativeText: !usesRaster, usedRaster: usesRaster,
            sourceTextPreview: sourceLabel, sourceSHA256: PrintDiagnosticStore.sha256Hex(sourceLabel.data(using: .utf8) ?? Data()),
            imagePixelWidth: 0, imagePixelHeight: 0, imageSHA256: "",
            rasterWidthBytes: 0, rasterHeight: 0, rasterBytes: 0, rasterSHA256: "",
            payloadBytes: payload.count, payloadSHA256: payloadSHA,
            headerXL: 0, headerXH: 0, headerYL: 0, headerYH: 0, expectedRasterBytes: 0, headerValid: usesRaster,
            writeCallCount: 1, diskBytes: result.diskBytes, diskSHA256: result.diskSHA256,
            payloadIntegrityOK: result.integrityOK, padBytes: result.padBytes, lpExitCode: result.lpExitCode,
            writeDurationSeconds: result.writeDurationSeconds, didClearQueue: result.didClearQueue,
            observedConcurrency: observedConcurrency, statusPollingPausedDuringJob: config.statusPollingWasActive,
            transportError: result.succeeded ? nil : (result.stderr.isEmpty ? "lp exit \(result.lpExitCode)" : result.stderr),
            result: .unknown, note: nil, artifactFolderPath: dir.path
        )
        store.writeTransportLog(id: jobId, text: Self.transportLog(record: record, result: result))
        store.writeMetadata(record)
        store.upsert(record)
        return record
    }

    private static func makeJobId() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(String(UUID().uuidString.prefix(4)))"
    }

    private static func transportLog(record: PrintDiagnosticRecord, result: PrintTransportResult?) -> String {
        var lines: [String] = []
        lines.append("jobId: \(record.id)")
        lines.append("createdAt: \(record.createdAt)")
        lines.append("printer: \(record.printerName) [\(record.connectionType)]")
        lines.append("renderMode: \(record.renderMode.rawValue) usedRaster=\(record.usedRaster) usedNativeText=\(record.usedNativeText)")
        lines.append("image: \(record.imagePixelWidth)x\(record.imagePixelHeight) sha=\(record.imageSHA256)")
        lines.append("raster: widthBytes=\(record.rasterWidthBytes) height=\(record.rasterHeight) bytes=\(record.rasterBytes) sha=\(record.rasterSHA256)")
        lines.append("header: xL=\(record.headerXL) xH=\(record.headerXH) yL=\(record.headerYL) yH=\(record.headerYH) expected=\(record.expectedRasterBytes) valid=\(record.headerValid)")
        lines.append("payload: bytes=\(record.payloadBytes) sha=\(record.payloadSHA256)")
        lines.append("statusPollingPausedDuringJob: \(record.statusPollingPausedDuringJob)")
        lines.append("observedConcurrency: \(record.observedConcurrency)")
        if let result {
            lines.append("--- transport ---")
            lines.append("writeCallCount: 1 (single file handoff to CUPS `lp`)")
            lines.append("padBytes: \(result.padBytes)")
            lines.append("diskBytes: \(result.diskBytes) diskSHA=\(result.diskSHA256)")
            lines.append("integrityOK (payload==disk): \(result.integrityOK)")
            lines.append("lpExitCode: \(result.lpExitCode)")
            lines.append("didClearQueue: \(result.didClearQueue)")
            lines.append("startedAt: \(result.startedAt)")
            lines.append("finishedAt: \(result.finishedAt)")
            lines.append("writeDurationSeconds: \(result.writeDurationSeconds)")
            if !result.succeeded { lines.append("stderr: \(result.stderr)") }
        } else {
            lines.append("--- transport skipped ---")
            lines.append("reason: \(record.transportError ?? "unknown")")
        }
        return lines.joined(separator: "\n")
    }
}
