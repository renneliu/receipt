import Foundation

/// Comparison report between two diagnostic records — classifies the LIKELY failing layer
/// strictly from the captured data (never guesses beyond the evidence).
struct PrintDiagnosticComparison: Identifiable {
    let id = UUID()
    let classification: String
    let detail: String

    static func compare(
        _ a: PrintDiagnosticRecord,
        _ b: PrintDiagnosticRecord,
        payloadA: Data?,
        payloadB: Data?
    ) -> PrintDiagnosticComparison {
        var lines: [String] = []

        func cmp(_ label: String, _ x: String, _ y: String) {
            let mark = x == y ? "== SAME" : "!= DIFF"
            lines.append("\(label): \(mark)\n  A: \(x)\n  B: \(y)")
        }

        lines.append("A = \(a.id) [\(a.result.displayName)]")
        lines.append("B = \(b.id) [\(b.result.displayName)]")
        lines.append("")

        cmp("source SHA", a.sourceSHA256, b.sourceSHA256)
        cmp("image SHA", a.imageSHA256, b.imageSHA256)
        cmp("raster SHA", a.rasterSHA256, b.rasterSHA256)
        cmp("payload SHA", a.payloadSHA256, b.payloadSHA256)
        cmp("payload bytes", String(a.payloadBytes), String(b.payloadBytes))
        cmp("raster dims", "\(a.rasterWidthBytes)x\(a.rasterHeight)", "\(b.rasterWidthBytes)x\(b.rasterHeight)")
        cmp("GS v 0 header", "\(a.headerXL)/\(a.headerXH)/\(a.headerYL)/\(a.headerYH)", "\(b.headerXL)/\(b.headerXH)/\(b.headerYL)/\(b.headerYH)")
        cmp("write calls", String(a.writeCallCount), String(b.writeCallCount))
        cmp("disk SHA", a.diskSHA256, b.diskSHA256)
        cmp("integrity OK", String(a.payloadIntegrityOK), String(b.payloadIntegrityOK))
        cmp("lp exit", String(a.lpExitCode), String(b.lpExitCode))
        cmp("pad bytes", String(a.padBytes), String(b.padBytes))
        cmp("clear queue", String(a.didClearQueue), String(b.didClearQueue))
        cmp("status polling active", String(a.statusPollingPausedDuringJob), String(b.statusPollingPausedDuringJob))
        cmp("observed concurrency", String(a.observedConcurrency), String(b.observedConcurrency))
        cmp("transport error", a.transportError ?? "none", b.transportError ?? "none")
        lines.append("")

        // Byte-by-byte payload diff (only meaningful when both payloads exist).
        if let pa = payloadA, let pb = payloadB {
            lines.append(byteDiffReport(pa, pb))
            lines.append("")
        }

        let classification = classify(a, b, payloadA: payloadA, payloadB: payloadB, extra: &lines)

        return PrintDiagnosticComparison(
            classification: classification,
            detail: lines.joined(separator: "\n")
        )
    }

    private static func classify(
        _ a: PrintDiagnosticRecord,
        _ b: PrintDiagnosticRecord,
        payloadA: Data?,
        payloadB: Data?,
        extra: inout [String]
    ) -> String {
        if a.sourceSHA256 != b.sourceSHA256 {
            return "Case 1 — 内容/样式模型在渲染前就不同。两次打印的源内容不一致（source hash 不同），先确认输入内容/样式相同。"
        }
        if a.imageSHA256 != b.imageSHA256 {
            return "Case 2 — 渲染过程不确定。相同内容产生了不同图像。可能原因：可变属性字符串、字体回退、共享状态、线程使用不当、布局宽度或缩放变化。"
        }
        if a.rasterSHA256 != b.rasterSHA256 {
            return "Case 3 — 位图→单色转换不确定。相同图像产生了不同 raster。可能原因：未初始化内存、阈值不一致、行填充不一致、可变图像缓冲、色彩空间转换错误。"
        }
        if a.payloadSHA256 != b.payloadSHA256 {
            return "Case 4 — ESC/POS 载荷构建不确定。相同 raster 产生了不同 payload。可能原因：残留样式命令、随机/可变头、初始化不正确、文本与 raster 混用、共享输出缓冲。"
        }
        // payloads identical
        let transportDiffers = a.diskSHA256 != b.diskSHA256
            || a.payloadIntegrityOK != b.payloadIntegrityOK
            || a.lpExitCode != b.lpExitCode
            || (a.transportError ?? "") != (b.transportError ?? "")
            || a.observedConcurrency != b.observedConcurrency
        if transportDiffers {
            return "Case 5 — 问题很可能在传输层。载荷字节相同但传输行为不同（落盘哈希/完整性/退出码/并发/错误不同）。可能原因：部分写入、丢字节、重复块、作业重叠、异步写完成 bug、指针生命周期、连接过早关闭。"
        }
        return "Case 6 — 应用生成并传输了完全相同的字节，且传输日志一致。若物理结果仍有一张乱码，请排查打印机固件、USB 连接/线材、转接口或 HUB、供电、打印机缓冲与硬件状态（非软件层）。"
    }

    private static func byteDiffReport(_ a: Data, _ b: Data) -> String {
        if a == b {
            return "byte diff: payloads are byte-identical (\(a.count) bytes)."
        }
        var lines: [String] = []
        lines.append("byte diff: A=\(a.count) bytes, B=\(b.count) bytes (Δ=\(a.count - b.count))")
        let n = min(a.count, b.count)
        var firstDiff = -1
        var diffCount = 0
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)
        for i in 0..<n where aBytes[i] != bBytes[i] {
            if firstDiff < 0 { firstDiff = i }
            diffCount += 1
        }
        diffCount += abs(a.count - b.count)
        if firstDiff >= 0 {
            lines.append("first differing offset: \(firstDiff) (0x\(String(firstDiff, radix: 16)))")
            let lo = max(0, firstDiff - 4)
            let hiA = min(a.count, firstDiff + 8)
            let hiB = min(b.count, firstDiff + 8)
            lines.append("  A[\(lo)..]: " + aBytes[lo..<hiA].map { String(format: "%02x", $0) }.joined(separator: " "))
            lines.append("  B[\(lo)..]: " + bBytes[lo..<hiB].map { String(format: "%02x", $0) }.joined(separator: " "))
        } else {
            lines.append("common prefix identical; difference is only trailing length.")
        }
        lines.append("differing bytes (within overlap + length delta): \(diffCount)")
        return lines.joined(separator: "\n")
    }
}
