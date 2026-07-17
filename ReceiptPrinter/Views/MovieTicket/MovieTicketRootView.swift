import SwiftUI

struct MovieTicketRootView: View {
    @StateObject private var session = MovieTicketSession()
    @State private var pane: Pane = .main
    @State private var showUnsavedDialog = false
    @State private var pendingPane: Pane?

    private enum Pane: String, CaseIterable, Identifiable {
        case main = "主页面"
        case template = "模板"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: Binding(
                    get: { pane },
                    set: { requestPaneChange($0) }
                )) {
                    ForEach(Pane.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer()

                if let name = session.activeTemplate?.name {
                    Text("当前模板：\(name)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("未选择模板")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch pane {
                case .main:
                    MovieTicketMainView()
                        .onAppear {
                            if let t = session.activeTemplate {
                                session.loadImages(for: t)
                            }
                        }
                case .template:
                    MovieTicketTemplateView()
                }
            }
            .environmentObject(session)
        }
        .navigationTitle("影票打印")
        .onAppear {
            pane = .main
            session.settings.lastPane = "main"
            session.settings.save()
        }
        .confirmationDialog(
            "模板有未保存的更改，是否保存？",
            isPresented: $showUnsavedDialog,
            titleVisibility: .visible
        ) {
            Button("保存") {
                session.saveEditingTemplate()
                if let next = pendingPane {
                    pendingPane = nil
                    applyPaneChange(next)
                }
            }
            Button("不保存", role: .destructive) {
                session.discardEditingChanges()
                if let next = pendingPane {
                    pendingPane = nil
                    applyPaneChange(next)
                }
            }
            Button("取消", role: .cancel) {
                pendingPane = nil
            }
        }
    }

    private func requestPaneChange(_ newPane: Pane) {
        guard newPane != pane else { return }
        if pane == .template && newPane == .main && session.isEditingDirty {
            pendingPane = newPane
            showUnsavedDialog = true
            return
        }
        applyPaneChange(newPane)
    }

    private func applyPaneChange(_ newPane: Pane) {
        pane = newPane
        session.settings.lastPane = newPane == .template ? "template" : "main"
        session.settings.save()
        if newPane == .template, session.editingTemplate == nil, let t = session.activeTemplate {
            session.beginEditing(t)
        }
        if newPane == .main {
            if !session.isEditingDirty {
                session.syncEditingIntoTemplates()
            }
            if let t = session.activeTemplate {
                session.loadImages(for: t)
            }
        }
    }
}
