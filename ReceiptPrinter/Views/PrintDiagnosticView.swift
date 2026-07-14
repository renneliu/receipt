import AppKit
import SwiftUI

struct PrintDiagnosticView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedId: String?
    @State private var compareSelection: [String] = []
    @State private var comparison: PrintDiagnosticComparison?

    private var records: [PrintDiagnosticRecord] { appState.diagnosticRecords }

    var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 320, idealWidth: 360)
            detailColumn
                .frame(minWidth: 420)
        }
        .navigationTitle("打印诊断")
        .onAppear { appState.reloadDiagnostics() }
        .sheet(item: $comparison) { report in
            ComparisonReportView(report: report)
                .frame(width: 640, height: 640)
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("打印作业 (\(records.count))")
                    .font(.headline)
                Spacer()
                Button {
                    appState.reloadDiagnostics()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(8)

            if compareSelection.count == 2 {
                Button("对比选中的两个作业") { runComparison() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 6)
            } else {
                Text("勾选一个「正常」和一个「乱码」作业进行对比")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }

            List(selection: $selectedId) {
                ForEach(records) { record in
                    row(record)
                        .tag(record.id)
                }
            }
        }
    }

    private func row(_ record: PrintDiagnosticRecord) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { compareSelection.contains(record.id) },
                set: { on in
                    if on {
                        if !compareSelection.contains(record.id) { compareSelection.append(record.id) }
                        if compareSelection.count > 2 { compareSelection.removeFirst() }
                    } else {
                        compareSelection.removeAll { $0 == record.id }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.id)
                    .font(.system(.caption, design: .monospaced))
                Text(record.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            resultBadge(record.result)
        }
        .padding(.vertical, 2)
    }

    private func resultBadge(_ result: PrintResultLabel) -> some View {
        let color: Color = switch result {
        case .successful: .green
        case .garbled: .red
        case .failed: .orange
        case .unknown: .gray
        }
        return Text(result.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedId, let record = records.first(where: { $0.id == id }) {
            DiagnosticDetailView(record: record)
        } else {
            VStack {
                Image(systemName: "stethoscope")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("选择一个打印作业查看诊断详情")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func runComparison() {
        guard compareSelection.count == 2,
              let a = records.first(where: { $0.id == compareSelection[0] }),
              let b = records.first(where: { $0.id == compareSelection[1] }) else { return }
        let payloadA = appState.diagnosticStore.payload(for: a.id)
        let payloadB = appState.diagnosticStore.payload(for: b.id)
        comparison = PrintDiagnosticComparison.compare(a, b, payloadA: payloadA, payloadB: payloadB)
    }
}

private struct DiagnosticDetailView: View {
    @EnvironmentObject private var appState: AppState
    let record: PrintDiagnosticRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(record.id)
                        .font(.system(.title3, design: .monospaced))
                    Spacer()
                    Text(record.result.displayName)
                        .font(.headline)
                }

                HStack(spacing: 8) {
                    Button("标记正常") { mark(.successful) }
                    Button("标记乱码") { mark(.garbled) }
                    Button("标记失败") { mark(.failed) }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("打开诊断文件夹") { openFolder() }
                    Button("导出诊断包") { exportPackage() }
                    Button(role: .destructive) { appState.deleteDiagnostic(id: record.id) } label: { Text("删除") }
                }

                Divider()
                group("阶段哈希 (SHA-256)") {
                    kv("内容 source", record.sourceSHA256)
                    kv("图像 image", record.imageSHA256)
                    kv("光栅 raster", record.rasterSHA256)
                    kv("载荷 payload", record.payloadSHA256)
                    kv("落盘 disk", record.diskSHA256)
                }
                group("渲染") {
                    kv("模式", record.renderMode.displayName)
                    kv("用原生文本", String(record.usedNativeText))
                    kv("用光栅", String(record.usedRaster))
                    kv("图像像素", "\(record.imagePixelWidth) × \(record.imagePixelHeight)")
                }
                group("光栅 / GS v 0 头") {
                    kv("每行字节 widthBytes", String(record.rasterWidthBytes))
                    kv("高度 height", String(record.rasterHeight))
                    kv("raster 字节数", String(record.rasterBytes))
                    kv("xL/xH/yL/yH", "\(record.headerXL)/\(record.headerXH)/\(record.headerYL)/\(record.headerYH)")
                    kv("期望字节数", String(record.expectedRasterBytes))
                    kv("头有效", String(record.headerValid))
                }
                group("载荷 / 传输") {
                    kv("载荷字节", String(record.payloadBytes))
                    kv("落盘字节", String(record.diskBytes))
                    kv("补齐字节", String(record.padBytes))
                    kv("写调用次数", String(record.writeCallCount))
                    kv("完整性校验通过", String(record.payloadIntegrityOK))
                    kv("lp 退出码", String(record.lpExitCode))
                    kv("写入耗时(秒)", String(format: "%.3f", record.writeDurationSeconds))
                    kv("并发观测值", String(record.observedConcurrency))
                    kv("清队列", String(record.didClearQueue))
                    kv("作业期间状态轮询", String(record.statusPollingPausedDuringJob))
                    if let err = record.transportError { kv("传输错误", err) }
                }
                group("打印机") {
                    kv("名称", record.printerName)
                    kv("连接", record.connectionType)
                    kv("DPI", String(record.dpi))
                    kv("可打印宽度(点)", String(record.printableWidthDots))
                }
                if !record.sourceTextPreview.isEmpty {
                    group("内容预览") {
                        Text(record.sourceTextPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
    }

    private func mark(_ result: PrintResultLabel) {
        appState.markDiagnosticResult(id: record.id, result: result)
    }

    private func openFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: record.artifactFolderPath))
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(record.id)-diagnostic"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let src = URL(fileURLWithPath: record.artifactFolderPath)
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }
}

private struct ComparisonReportView: View {
    let report: PrintDiagnosticComparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("对比报告").font(.title3).bold()
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("结论").font(.headline)
                        Text(report.classification)
                            .font(.body)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(report.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
        }
    }
}
