import SwiftUI

/// Edits movie ticket fields using local state so parent re-renders do not steal TextField focus on each keystroke.
struct MovieTicketDataEditorView: View {
    @Binding var data: MovieTicketData
    let templateId: UUID
    var onFieldEdit: () -> Void = {}

    @State private var local = MovieTicketData.sample
    @State private var loadedTemplateId: UUID?
    @State private var fullBarcodeDraft = ""
    @State private var syncTask: Task<Void, Never>?
    @FocusState private var fullBarcodeFocused: Bool

    var body: some View {
        Group {
            Section("影院与场次") {
                TextField("影院名", text: $local.venueName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.venueName) { _, _ in
                        scheduleSyncToParent()
                    }
                TextField("影厅号", text: $local.hallNumber)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.hallNumber) { _, _ in scheduleSyncToParent() }
                TextField("影片名", text: $local.movieTitle)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.movieTitle) { _, _ in scheduleSyncToParent() }
            }

            Section("放映时间") {
                DatePicker("开始时间", selection: $local.showStartTime, displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: local.showStartTime) { _, _ in scheduleSyncToParent() }
                Stepper("广告时长: \(local.adDurationMinutes) 分钟", value: $local.adDurationMinutes, in: 0...120)
                    .onChange(of: local.adDurationMinutes) { _, _ in scheduleSyncToParent() }
                Text("广告时长不打印在票上，仅用于推算结束时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("影片时长: \(local.movieDurationMinutes) 分钟", value: $local.movieDurationMinutes, in: 1...300)
                    .onChange(of: local.movieDurationMinutes) { _, _ in scheduleSyncToParent() }
                Text("影片时长不打印在票上，仅用于推算结束时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("结束时间") {
                    Text(endTimeLabel)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("票面条目") {
                    Text(local.showDateTime)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("票价") {
                TextField("票种", text: $local.ticketType)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.ticketType) { _, _ in scheduleSyncToParent() }
                HStack {
                    Text("金额")
                    TextField("金额", text: $local.ticketPrice)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: local.ticketPrice) { _, _ in scheduleSyncToParent() }
                }
                LabeledContent("打印显示") {
                    Text(local.formattedTicketPrice)
                        .foregroundStyle(.secondary)
                }
            }

            Section("条码与 DEBI 流水号") {
                TextField("条码前 8 位", text: $local.barcodeBase)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.barcodeBase) { _, _ in scheduleSyncToParent() }
                TextField("流水号后 3 位", text: $local.ticketSerial)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.ticketSerial) { _, _ in scheduleSyncToParent() }
                TextField("完整条码（11 位）", text: $fullBarcodeDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fullBarcodeFocused)
                    .onSubmit(applyFullBarcodeDraft)
                Text("输入完成后回车或切换字段，自动拆分同步")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("条码") {
                    Text(local.barcode)
                        .font(.system(.caption, design: .monospaced))
                }
                LabeledContent("票号 DEBI") {
                    Text(local.ticketCode)
                        .font(.system(.caption, design: .monospaced))
                }
                LabeledContent("条码下方文字") {
                    Text(local.barcodeLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .onAppear { loadLocalIfNeeded() }
        .onChange(of: templateId) { _, _ in
            loadedTemplateId = nil
            loadLocalIfNeeded()
        }
        .onChange(of: local.barcodeBase) { _, _ in syncFullBarcodeDraftFromLocal() }
        .onChange(of: local.ticketSerial) { _, _ in syncFullBarcodeDraftFromLocal() }
        .onChange(of: fullBarcodeFocused) { _, focused in
            if !focused {
                applyFullBarcodeDraft()
                scheduleSyncToParent()
            }
        }
        .onDisappear {
            flushSyncToParent()
        }
    }

    private var endTimeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE MMM d, yyyy h:mm a"
        return formatter.string(from: local.showEndTime)
    }

    private func loadLocalIfNeeded() {
        guard loadedTemplateId != templateId else { return }
        local = data
        fullBarcodeDraft = local.barcode
        loadedTemplateId = templateId
    }

    private func scheduleSyncToParent() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                flushSyncToParent()
                onFieldEdit()
            }
        }
    }

    private func flushSyncToParent() {
        data = local
    }

    private func syncFullBarcodeDraftFromLocal() {
        guard !fullBarcodeFocused else { return }
        fullBarcodeDraft = local.barcode
    }

    private func applyFullBarcodeDraft() {
        let digits = fullBarcodeDraft.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        local.syncBarcodeFromFullCode(digits)
        fullBarcodeDraft = local.barcode
    }
}
