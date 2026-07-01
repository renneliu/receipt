import SwiftUI

struct TemplateListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            ForEach(appState.templates) { template in
                HStack {
                    VStack(alignment: .leading) {
                        Text(template.name).font(.headline)
                        Text("\(template.blocks.count) 个块 · 更新于 \(template.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑") {
                        appState.designerTemplate = template
                        appState.selectedSidebarItem = .designer
                    }
                    Button("预览") {
                        appState.designerTemplate = template
                        appState.selectedSidebarItem = .designer
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    appState.deleteTemplate(appState.templates[index])
                }
            }
        }
        .toolbar {
            Button("新建模板") {
                let t = ReceiptTemplate(name: "新模板 \(appState.templates.count + 1)")
                appState.saveTemplate(t)
                appState.designerTemplate = t
                appState.selectedSidebarItem = .designer
            }
        }
        .navigationTitle("模板管理")
    }
}
