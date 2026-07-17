import SwiftUI

struct MovieTicketRootView: View {
    @StateObject private var session = MovieTicketSession()
    @State private var pane: Pane = .main

    private enum Pane: String, CaseIterable, Identifiable {
        case main = "主页面"
        case template = "模板"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $pane) {
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
        .onChange(of: pane) { _, newValue in
            session.settings.lastPane = newValue == .template ? "template" : "main"
            session.settings.save()
            if newValue == .template, session.editingTemplate == nil, let t = session.activeTemplate {
                session.beginEditing(t)
            }
            if newValue == .main {
                session.syncEditingIntoTemplates()
                if let t = session.activeTemplate {
                    session.loadImages(for: t)
                }
            }
        }
    }
}
