import SwiftUI

/// Edits movie ticket fields using local draft state.
/// Preview updates do NOT write through the Binding on each keystroke (that remounts this Form
/// child and resets @State to sample / steals focus). Binding is committed on disappear.
struct MovieTicketDataEditorView: View {
    @Binding var data: MovieTicketData
    let templateId: UUID
    /// Called with the current draft so the parent can refresh preview without taking ownership mid-edit.
    var onDraftChange: (MovieTicketData) -> Void = { _ in }

    @State private var local: MovieTicketData
    @State private var loadedTemplateId: UUID?
    @State private var fullBarcodeDraft: String
    @State private var previewTask: Task<Void, Never>?
    @FocusState private var fullBarcodeFocused: Bool

    init(
        data: Binding<MovieTicketData>,
        templateId: UUID,
        onDraftChange: @escaping (MovieTicketData) -> Void = { _ in }
    ) {
        self._data = data
        self.templateId = templateId
        self.onDraftChange = onDraftChange
        self._local = State(initialValue: data.wrappedValue)
        self._loadedTemplateId = State(initialValue: templateId)
        self._fullBarcodeDraft = State(initialValue: data.wrappedValue.barcode)
    }

    var body: some View {
        Group {
            Section("影院与场次") {
                TextField("影院名", text: $local.venueName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.venueName) { _, _ in schedulePreviewOnly() }
                TextField("影厅号", text: $local.hallNumber)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.hallNumber) { _, _ in schedulePreviewOnly() }
                TextField("影片名", text: $local.movieTitle)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.movieTitle) { _, _ in schedulePreviewOnly() }
            }

            Section("放映时间") {
                DatePicker("开始时间", selection: $local.showStartTime, displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: local.showStartTime) { _, _ in schedulePreviewOnly() }
                Stepper("广告时长: \(local.adDurationMinutes) 分钟", value: $local.adDurationMinutes, in: 0...120)
                    .onChange(of: local.adDurationMinutes) { _, _ in schedulePreviewOnly() }
                Text("广告时长不打印在票上，仅用于推算结束时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("影片时长: \(local.movieDurationMinutes) 分钟", value: $local.movieDurationMinutes, in: 1...300)
                    .onChange(of: local.movieDurationMinutes) { _, _ in schedulePreviewOnly() }
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
                    .onChange(of: local.ticketType) { _, _ in schedulePreviewOnly() }
                HStack {
                    Text("金额")
                    TextField("金额", text: $local.ticketPrice)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: local.ticketPrice) { _, _ in schedulePreviewOnly() }
                }
                LabeledContent("打印显示") {
                    Text(local.formattedTicketPrice)
                        .foregroundStyle(.secondary)
                }
            }

            Section("条码与 DEBI 流水号") {
                TextField("条码前 8 位", text: $local.barcodeBase)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.barcodeBase) { _, _ in schedulePreviewOnly() }
                TextField("流水号后 3 位", text: $local.ticketSerial)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: local.ticketSerial) { _, _ in schedulePreviewOnly() }
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
        .id(templateId)
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
                commitToBinding()
                schedulePreviewOnly()
            }
        }
        .onDisappear {
            commitToBinding()
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

    /// Refresh parent preview from draft only — do not write @Binding (avoids remount/focus loss).
    private func schedulePreviewOnly() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                onDraftChange(local)
            }
        }
    }

    private func commitToBinding() {
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
