import Foundation

/// User-labeled physical outcome of a single print job.
enum PrintResultLabel: String, Codable, CaseIterable, Identifiable {
    case unknown
    case successful
    case garbled
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown: return L10n.ui("未标记")
        case .successful: return L10n.ui("打印正常")
        case .garbled: return L10n.ui("打印乱码")
        case .failed: return L10n.ui("打印失败")
        }
    }
}

enum PrintRenderMode: String, Codable {
    case raster
    case nativeText
    case mixed

    var displayName: String {
        switch self {
        case .raster: return L10n.ui("位图光栅 (raster)")
        case .nativeText: return L10n.ui("原生文本 (native text)")
        case .mixed: return L10n.ui("混合 (mixed)")
        }
    }
}

/// Complete objective record of ONE print job — captured before/at transmission so a
/// user-labeled "successful" job can be compared byte-for-byte against a "garbled" one.
struct PrintDiagnosticRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var createdAt: Date

    // Printer / transport environment
    var printerName: String
    var connectionType: String
    var printerModelHint: String?
    var dpi: Int
    var printableWidthDots: Int

    // Rendering
    var renderMode: PrintRenderMode
    var usedNativeText: Bool
    var usedRaster: Bool

    // Content + stage hashes (the heart of the comparison)
    var sourceTextPreview: String
    var sourceSHA256: String
    var imagePixelWidth: Int
    var imagePixelHeight: Int
    var imageSHA256: String
    var rasterWidthBytes: Int
    var rasterHeight: Int
    var rasterBytes: Int
    var rasterSHA256: String
    var payloadBytes: Int
    var payloadSHA256: String

    // GS v 0 header validation
    var headerXL: Int
    var headerXH: Int
    var headerYL: Int
    var headerYH: Int
    var expectedRasterBytes: Int
    var headerValid: Bool

    // Transport (byte-level)
    var writeCallCount: Int
    var diskBytes: Int
    var diskSHA256: String
    var payloadIntegrityOK: Bool
    var padBytes: Int
    var lpExitCode: Int
    var writeDurationSeconds: Double
    var didClearQueue: Bool
    var observedConcurrency: Int
    var statusPollingPausedDuringJob: Bool
    var transportError: String?

    // Outcome
    var result: PrintResultLabel
    var note: String?
    var artifactFolderPath: String

    /// Short hashes for compact UI display.
    static func short(_ hash: String) -> String { String(hash.prefix(12)) }
}

/// Sendable bundle of the exact bytes/metadata for one job, produced on the UI side and
/// handed to `PrintController` for saving + transmission (no NSImage crosses the boundary).
struct PrintArtifacts: Sendable {
    var sourceText: String
    var attributedRTFD: Data?
    var pngData: Data
    var rasterData: Data
    var payload: Data

    var imagePixelWidth: Int
    var imagePixelHeight: Int
    var rasterWidthBytes: Int
    var rasterHeight: Int

    var headerXL: Int
    var headerXH: Int
    var headerYL: Int
    var headerYH: Int
    var expectedRasterBytes: Int

    var renderMode: PrintRenderMode
    var usedNativeText: Bool
    var usedRaster: Bool

    var dpi: Int
    var printableWidthDots: Int
    var printerModelHint: String?
}
