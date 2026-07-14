import SwiftUI

/// Template print: select template, edit fields, live preview, print.
struct TemplatePrintView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTemplateId: UUID?
    @State private var fieldValues: [String: String] = [:]
    @State private var movieTicket = MovieTicketData.sample
    @State private var previewImage: NSImage?
    @State private var isPrinting = false
    @State private var showPreviewSheet = false
    @State private var movieSearchResults: [MovieSearchResult] = []
    @State private var showMovieSearch = false
    @State private var isSearchingMovies = false
    @State private var selectedExtractionSchemaId: UUID?

    private var selectedTemplate: ReceiptTemplate? {
        if let id = selectedTemplateId {
            return appState.templates.first { $0.id == id }
        }
        return appState.templates.first
    }

    private var isMovieTicket: Bool {
        guard let template = selectedTemplate else { return false }
        return MovieTicketData.isMovieTicketTemplate(template)
    }

    var body: some View {
        HSplitView {
            templateListColumn
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

            fieldFormColumn
                .frame(minWidth: 280, idealWidth: 340)

            previewColumn
                .frame(minWidth: 280)
        }
        .navigationTitle("模板打印")
        .onAppear { bootstrapSelection() }
        .onChange(of: selectedTemplateId) { _, _ in reloadFields() }
        .onChange(of: fieldValues) { _, _ in refreshPreview() }
        .sheet(isPresented: $showPreviewSheet) {
            if let image = previewImage {
                BitmapPrintPreviewView(image: image)
                    .frame(width: 400, height: 600)
            }
        }
        .sheet(isPresented: $showMovieSearch) {
            movieSearchSheet
        }
    }

    private var templateListColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模板").font(.headline)
            if appState.templates.isEmpty {
                ContentUnavailableView("无模板", systemImage: "doc")
            } else {
                List(appState.templates, selection: $selectedTemplateId) { template in
                    Text(template.name).tag(template.id as UUID?)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var fieldFormColumn: some View {
        ScrollView {
            if let template = selectedTemplate {
                if isMovieTicket {
                    Form {
                        MovieTicketDataEditorView(
                            data: $movieTicket,
                            templateId: template.id,
                            onDraftChange: { draft in
                                movieTicket = draft
                                syncMovieTicketToFields()
                                refreshPreview()
                            }
                        )
                        movieDurationSection
                    }
                    .formStyle(.grouped)
                } else {
                    Form {
                        if !appState.extractionSchemas.isEmpty {
                            Section("邮件抓取") {
                                Picker("规则", selection: $selectedExtractionSchemaId) {
                                    Text("无").tag(UUID?.none)
                                    ForEach(appState.extractionSchemas) { schema in
                                        Text(schema.name).tag(UUID?.some(schema.id))
                                    }
                                }
                            }
                        }
                        Section("字段") {
                            ForEach(template.placeholders(), id: \.self) { key in
                                TextField(key, text: binding(for: key))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            } else {
                ContentUnavailableView("选择模板", systemImage: "doc.text")
            }
        }
        .padding(.vertical)
    }

    private var movieDurationSection: some View {
        Section("片长查询") {
            Button(isSearchingMovies ? "查询中..." : "匹配片长 (TMDB)") {
                Task { await searchMovieDuration() }
            }
            .disabled(movieTicket.movieTitle.trimmingCharacters(in: .whitespaces).isEmpty || isSearchingMovies)
            if !appState.settings.tmdbAPIKeyStored {
                Text("请先在设置中配置 TMDB API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 12) {
            Text("预览").font(.headline)
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView("预览", systemImage: "doc.richtext")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                if let printer = appState.settings.selectedPrinterName {
                    Text("打印机: \(printer)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("预览") { showPreviewSheet = true }
                    .disabled(previewImage == nil)
                Button(isPrinting ? "打印中..." : "打印") {
                    Task { await printTemplate() }
                }
                .disabled(isPrinting || selectedTemplate == nil || appState.settings.selectedPrinterName == nil)
            }
            .padding(.horizontal)
        }
        .padding()
    }

    private var movieSearchSheet: some View {
        NavigationStack {
            List(movieSearchResults) { result in
                Button {
                    applyMovieResult(result)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if let urlString = result.posterURL, let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFit()
                                } else {
                                    Color.gray.opacity(0.2)
                                }
                            }
                            .frame(width: 40, height: 60)
                        }
                        VStack(alignment: .leading) {
                            Text(result.title).font(.headline)
                            if let original = result.originalTitle, original != result.title {
                                Text(original).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(result.year) · \(result.runtimeMinutes) 分钟")
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("选择影片")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showMovieSearch = false }
                }
            }
        }
        .frame(width: 480, height: 400)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { fieldValues[key] ?? "" },
            set: { fieldValues[key] = $0 }
        )
    }

    private func bootstrapSelection() {
        if selectedTemplateId == nil {
            selectedTemplateId = appState.templates.first?.id
        }
        reloadFields()
    }

    private func reloadFields() {
        guard let template = selectedTemplate else { return }
        let context = TemplateDataContext(
            manual: template.defaultData,
            settings: appState.settings,
            gmailFields: [:],
            movieFields: [:]
        )
        fieldValues = PlaceholderResolutionService.resolve(template: template, context: context)

        if MovieTicketData.isMovieTicketTemplate(template) {
            movieTicket = MovieTicketData.from(dictionary: fieldValues)
            if movieTicket.adDurationMinutes == 0 {
                movieTicket.adDurationMinutes = appState.settings.defaultAdvertisingMinutes
            }
            syncMovieTicketToFields()
        }
        refreshPreview()
    }

    private func syncMovieTicketToFields() {
        let rendered = movieTicket.renderedDictionary()
        for (k, v) in rendered { fieldValues[k] = v }
    }

    private func refreshPreview() {
        guard let template = selectedTemplate else {
            previewImage = nil
            return
        }
        let data = resolvedPrintData(for: template)
        previewImage = TemplateRenderer.renderPreviewImage(
            template: template,
            data: data,
            config: appState.settings.printerConfig
        )
    }

    private func resolvedPrintData(for template: ReceiptTemplate) -> [String: String] {
        var gmailFields: [String: String] = [:]
        if let schemaId = selectedExtractionSchemaId,
           let schema = appState.extractionSchemas.first(where: { $0.id == schemaId }),
           let body = fieldValues["gmail.body"] ?? fieldValues["_emailBody"] {
            gmailFields = EmailExtractionEngine.extractFields(from: body, schema: schema)
        }
        let context = TemplateDataContext(
            manual: fieldValues,
            settings: appState.settings,
            gmailFields: gmailFields,
            movieFields: [:]
        )
        return PlaceholderResolutionService.resolve(template: template, context: context)
    }

    private func printTemplate() async {
        guard let template = selectedTemplate else { return }
        isPrinting = true
        defer { isPrinting = false }
        let data = resolvedPrintData(for: template)
        await appState.printTemplate(template, data: data)
    }

    private func searchMovieDuration() async {
        isSearchingMovies = true
        defer { isSearchingMovies = false }
        do {
            let service = TMDBMovieMetadataProvider(settings: appState.settings)
            movieSearchResults = try await service.search(title: movieTicket.movieTitle)
            showMovieSearch = !movieSearchResults.isEmpty
            if movieSearchResults.isEmpty {
                appState.lastError = "未找到匹配的影片"
            }
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func applyMovieResult(_ result: MovieSearchResult) {
        movieTicket.movieDurationMinutes = result.runtimeMinutes
        syncMovieTicketToFields()
        refreshPreview()
        showMovieSearch = false
    }
}
