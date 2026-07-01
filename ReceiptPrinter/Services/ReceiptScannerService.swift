import Foundation
import Vision
import AppKit

struct TextObservation {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

struct BarcodeObservation {
    let payload: String
    let symbology: VNBarcodeSymbology
    let boundingBox: CGRect
}

struct RecognizedBlock {
    let block: TemplateBlock
    let boundingBox: CGRect?
    let confidence: Double
}

enum ReceiptScannerService {
    static func scan(image: NSImage) async throws -> (observations: [RecognizedBlock], processedImage: NSImage) {
        let processed = ImagePreprocessor.preprocess(image)
        guard let cgImage = processed.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScanError.invalidImage
        }

        async let texts = recognizeText(in: cgImage)
        async let barcodes = detectBarcodes(in: cgImage)
        let (textResults, barcodeResults) = try await (texts, barcodes)

        let rows = LayoutAnalyzer.clusterRows(textResults)
        var blocks: [RecognizedBlock] = []

        for row in rows {
            if row.count == 1, let obs = row.first {
                let block = LayoutAnalyzer.textBlock(from: obs, imageWidth: CGFloat(cgImage.width))
                let inferred = TemplateInferrer.inferPlaceholder(for: block, observation: obs)
                blocks.append(RecognizedBlock(block: inferred.block, boundingBox: obs.boundingBox, confidence: inferred.confidence))
            } else if row.count >= 2 {
                let left = row.first!.text
                let content = "\(left) {{value}}"
                var block = TemplateBlock.text(content, align: .left)
                block = TemplateInferrer.inferFieldName(block: block, text: left)
                let box = row.map(\.boundingBox).reduce(row.first!.boundingBox) { $0.union($1) }
                blocks.append(RecognizedBlock(block: block, boundingBox: box, confidence: 0.7))
            }
        }

        for barcode in barcodeResults {
            let block: TemplateBlock
            if barcode.symbology == .qr {
                block = .qr("{{qrContent}}")
            } else {
                block = .barcode("{{barcode}}")
            }
            _ = barcode.payload
            blocks.append(RecognizedBlock(block: block, boundingBox: barcode.boundingBox, confidence: 0.9))
        }

        if blocks.isEmpty {
            blocks = textResults.map {
                RecognizedBlock(block: .text($0.text), boundingBox: $0.boundingBox, confidence: Double($0.confidence))
            }
        }

        return (blocks, processed)
    }

    private static func recognizeText(in image: CGImage) async throws -> [TextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { obs -> TextObservation? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return TextObservation(text: candidate.string, confidence: candidate.confidence, boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: observations)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func detectBarcodes(in image: CGImage) async throws -> [BarcodeObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = (request.results as? [VNBarcodeObservation] ?? []).compactMap { obs -> BarcodeObservation? in
                    guard let payload = obs.payloadStringValue else { return nil }
                    return BarcodeObservation(payload: payload, symbology: obs.symbology, boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: results)
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum ScanError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "无法读取图片" }
}

enum LayoutAnalyzer {
    static func clusterRows(_ observations: [TextObservation]) -> [[TextObservation]] {
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[TextObservation]] = []
        for obs in sorted {
            if let idx = rows.firstIndex(where: { abs($0[0].boundingBox.midY - obs.boundingBox.midY) < 0.02 }) {
                rows[idx].append(obs)
            } else {
                rows.append([obs])
            }
        }
        return rows.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }

    static func textBlock(from obs: TextObservation, imageWidth: CGFloat) -> TemplateBlock {
        let centerX = obs.boundingBox.midX
        let align: TextAlign
        if centerX > 0.35 && centerX < 0.65 {
            align = .center
        } else if centerX > 0.65 {
            align = .right
        } else {
            align = .left
        }
        let height = obs.boundingBox.height
        let size: TextSize = height > 0.04 ? .double : .normal
        return TemplateBlock.text(obs.text, align: align, size: size)
    }
}
