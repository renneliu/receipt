import SwiftUI

struct CinemaRulesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingRule: CinemaRule?

    var body: some View {
        Group {
            if appState.cinemaRules.isEmpty {
                ContentUnavailableView("暂无影院规则", systemImage: "film", description: Text("添加规则以匹配 Gmail 订单邮件并绑定打印模板"))
            } else {
                List {
                    ForEach(appState.cinemaRules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.cinemaName).font(.headline)
                                    Text("发件人: \(rule.matchRules.senders.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rule.enabled {
                                    Text("启用").font(.caption).foregroundStyle(.green)
                                } else {
                                    Text("禁用").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for i in indexSet { appState.deleteRule(appState.cinemaRules[i]) }
                    }
                }
            }
        }
        .toolbar {
            Button("添加规则") { createRule() }
        }
        .navigationTitle("影院规则")
        .sheet(item: $editingRule) { rule in
            CinemaRuleEditorView(rule: rule) { saved in
                appState.saveRule(saved)
                editingRule = nil
            }
            .environmentObject(appState)
        }
    }

    private func createRule() {
        if let orpheum = appState.templates.first(where: { MovieTicketData.isMovieTicketTemplate($0) }) {
            var rule = CinemaRule(cinemaName: "Hayden Orpheum", templateId: orpheum.id)
            rule.matchRules.senders = ["Hayden Orpheum Picture Palace", "@orpheum.com"]
            rule.matchRules.subjectContains = ["Booking"]
            editingRule = rule
            return
        }
        let templateId = appState.templates.first?.id ?? UUID()
        editingRule = CinemaRule(cinemaName: "新影院", templateId: templateId)
    }
}
