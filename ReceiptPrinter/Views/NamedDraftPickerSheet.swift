import SwiftUI

/// Shared picker for named working drafts (per-module libraries).
struct NamedDraftPickerSheet: View {
    let title: String
    let module: String
    let onLoad: (NamedWorkingDraft) -> Void
    var onClose: () -> Void

    @State private var drafts: [NamedWorkingDraft] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.ui("刷新")) { reload() }
                Button(L10n.ui("清理全部"), role: .destructive) {
                    NamedWorkingDraftStore.clear(module: module)
                    reload()
                }
                .disabled(drafts.isEmpty)
                Button(L10n.ui("关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            if drafts.isEmpty {
                ContentUnavailableView(
                    L10n.ui("暂无草稿"),
                    systemImage: "doc.text",
                    description: Text(L10n.ui("点「保存草稿」可将当前内容存入列表"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(drafts) { draft in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(draft.name).font(.headline).lineLimit(1)
                                Spacer()
                                Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(draft.previewText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            HStack {
                                Button(L10n.ui("载入")) { onLoad(draft) }
                                Spacer()
                                Button(L10n.ui("删除"), role: .destructive) {
                                    NamedWorkingDraftStore.delete(id: draft.id, module: module)
                                    reload()
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear { reload() }
    }

    private func reload() {
        drafts = NamedWorkingDraftStore.loadAll(module: module)
    }
}

struct NamePromptSheet: View {
    let title: String
    let nameLabel: String
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(nameLabel, text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.ui("取消"), action: onCancel)
                Button(L10n.ui("保存")) {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
