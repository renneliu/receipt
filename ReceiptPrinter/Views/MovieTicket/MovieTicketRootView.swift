import SwiftUI

struct MovieTicketRootView: View {
    @StateObject private var session = MovieTicketSession()
    @State private var pane: Pane = .main
    @State private var showUnsavedDialog = false
    @State private var pendingPane: Pane?

    private enum Pane: String, CaseIterable, Identifiable {
        case main
        case template
        var id: String { rawValue }
        var title: String {
            switch self {
            case .main: return L10n.ui("主页面")
            case .template: return L10n.ui("模板")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: Binding(
                    get: { pane },
                    set: { requestPaneChange($0) }
                )) {
                    ForEach(Pane.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer()

                if let name = session.activeTemplate?.name {
                    Text("\(L10n.ui("当前模板："))\(name)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.ui("未选择模板"))
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
        .navigationTitle(L10n.ui("影票打印"))
        .onAppear {
            pane = .main
            session.settings.lastPane = "main"
            session.settings.save()
        }
        .confirmationDialog(
            L10n.ui("模板有未保存的更改，是否保存？"),
            isPresented: $showUnsavedDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.ui("保存")) {
                session.saveEditingTemplate()
                if let next = pendingPane {
                    pendingPane = nil
                    applyPaneChange(next)
                }
            }
            Button(L10n.ui("不保存"), role: .destructive) {
                session.discardEditingChanges()
                if let next = pendingPane {
                    pendingPane = nil
                    applyPaneChange(next)
                }
            }
            Button(L10n.ui("取消"), role: .cancel) {
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
