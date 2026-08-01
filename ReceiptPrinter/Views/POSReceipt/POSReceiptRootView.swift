import SwiftUI

struct POSReceiptRootView: View {
    @StateObject private var session = POSReceiptSession()
    @State private var pane: Pane = .main

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
                Picker("", selection: $pane) {
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
                    POSReceiptMainView()
                        .onAppear {
                            if let t = session.activeTemplate {
                                session.loadImages(for: t)
                            }
                        }
                case .template:
                    POSReceiptTemplateView()
                }
            }
            .environmentObject(session)
        }
        // Title owned by MainView (keep-alive stack).
        .onAppear {
            // Always land on 主页面 when opening POS 小票.
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
                    session.reloadExcelCatalog(for: t)
                }
            }
        }
    }
}
