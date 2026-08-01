import AppKit
import Combine
import SwiftUI

/// Editable snapshot of settings that only commits on Save.
struct SettingsDraft: Equatable {
    var selectedPrinterName: String?
    var printerConfig: PrinterConfig
    var hasCompletedSetup: Bool
    var defaultStartupPage: SidebarItem
    var appLanguage: AppLanguage
    var tmdbAPIKey: String
    var retainWorkingContentOnQuit: Bool

    static func from(settings: AppSettings) -> SettingsDraft {
        SettingsDraft(
            selectedPrinterName: settings.selectedPrinterName,
            printerConfig: settings.printerConfig,
            hasCompletedSetup: settings.hasCompletedSetup,
            defaultStartupPage: settings.defaultStartupPage,
            appLanguage: settings.appLanguage,
            tmdbAPIKey: settings.tmdbAPIKey,
            retainWorkingContentOnQuit: settings.retainWorkingContentOnQuit
        )
    }
}

@MainActor
final class SettingsDraftStore: ObservableObject {
    @Published var draft: SettingsDraft
    @Published var baseline: SettingsDraft
    @Published var statusMessage: String?

    var isDirty: Bool { draft != baseline }

    var isTMDBKeyDirty: Bool {
        draft.tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            != baseline.tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(settings: AppSettings = AppSettings()) {
        let snap = SettingsDraft.from(settings: settings)
        draft = snap
        baseline = snap
    }

    func reload(from settings: AppSettings) {
        let snap = SettingsDraft.from(settings: settings)
        draft = snap
        baseline = snap
        statusMessage = nil
    }

    func discard() {
        draft = baseline
        statusMessage = nil
    }

    func restoreDefaults() {
        let defaults = AppSettings.uiDefaults(keepingPrinter: draft.selectedPrinterName)
        draft.printerConfig = defaults.printerConfig
        draft.defaultStartupPage = defaults.defaultStartupPage
        draft.appLanguage = defaults.appLanguage
        draft.tmdbAPIKey = defaults.tmdbAPIKey
        draft.retainWorkingContentOnQuit = true
        statusMessage = nil
    }

    func save(into appState: AppState) {
        appState.settings.selectedPrinterName = draft.selectedPrinterName
        appState.settings.printerConfig = draft.printerConfig
        appState.settings.hasCompletedSetup = draft.hasCompletedSetup
        appState.settings.defaultStartupPage = draft.defaultStartupPage
        appState.settings.appLanguage = draft.appLanguage
        appState.settings.tmdbAPIKey = draft.tmdbAPIKey
        appState.settings.retainWorkingContentOnQuit = draft.retainWorkingContentOnQuit
        appState.settings.save()
        L10n.current = draft.appLanguage
        baseline = draft
        statusMessage = L10n.t("settings.saved", draft.appLanguage)
        appState.settingsHasUnsavedChanges = false
        appState.objectWillChange.send()
    }

    /// Persist only the TMDB key (Keychain); leave other draft fields untouched.
    func saveTMDBKey(into appState: AppState) {
        let key = draft.tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.tmdbAPIKey = key
        appState.settings.tmdbAPIKey = key
        baseline.tmdbAPIKey = key
        statusMessage = L10n.t("settings.keySaved", draft.appLanguage)
        appState.settingsHasUnsavedChanges = isDirty
        appState.objectWillChange.send()
    }

    /// Clear the TMDB key in the draft and Keychain immediately.
    func resetTMDBKey(into appState: AppState) {
        draft.tmdbAPIKey = ""
        appState.settings.tmdbAPIKey = ""
        baseline.tmdbAPIKey = ""
        statusMessage = L10n.t("settings.keyReset", draft.appLanguage)
        appState.settingsHasUnsavedChanges = isDirty
        appState.objectWillChange.send()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsForm(store: appState.settingsDraftStore)
    }
}

private struct SettingsForm: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: SettingsDraftStore
    @State private var printers: [String] = []
    @State private var loadError: String?
    @State private var showAPIKey = false

    /// Preview language from the draft so labels update before Save.
    private var language: AppLanguage { store.draft.appLanguage }
    private let contentWidth: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !store.draft.hasCompletedSetup {
                        settingsCard(title: L10n.t("settings.firstRun", language), systemImage: "checkmark.circle") {
                            Text(L10n.t("settings.firstRunHint", language))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L10n.t("settings.firstRunDone", language)) {
                                store.draft.hasCompletedSetup = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                    }

                    settingsCard(title: L10n.t("settings.general", language), systemImage: "slider.horizontal.3") {
                        settingsRow(L10n.t("settings.defaultPage", language)) {
                            Picker("", selection: $store.draft.defaultStartupPage) {
                                ForEach(SidebarItem.startupPageChoices) { item in
                                    Text(item.title(language)).tag(item)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        divider
                        settingsRow(L10n.t("settings.appLanguage", language)) {
                            Picker("", selection: $store.draft.appLanguage) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                        divider
                        Toggle(isOn: $store.draft.retainWorkingContentOnQuit) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("settings.retainWorkingContent", language))
                                Text(L10n.t("settings.retainWorkingContentHint", language))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    settingsCard(title: L10n.t("settings.printer", language), systemImage: "printer") {
                        settingsRow(L10n.t("settings.cupsPrinter", language)) {
                            Picker("", selection: Binding(
                                get: { store.draft.selectedPrinterName ?? "" },
                                set: { store.draft.selectedPrinterName = $0.isEmpty ? nil : $0 }
                            )) {
                                Text(L10n.t("settings.none", language)).tag("")
                                ForEach(printers, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            Spacer(minLength: 148)
                            Button(L10n.t("settings.refreshPrinters", language)) { refreshPrinters() }
                                .controlSize(.small)
                        }
                        if let loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    settingsCard(title: L10n.t("settings.paperEncoding", language), systemImage: "doc.plaintext") {
                        settingsRow(L10n.t("settings.paperWidth", language)) {
                            Picker("", selection: Binding(
                                get: { store.draft.printerConfig.paperWidthMM },
                                set: {
                                    store.draft.printerConfig.paperWidthMM = $0
                                    store.draft.printerConfig.dotsPerLine = $0 == 80 ? 576 : 384
                                    store.draft.printerConfig.columnsPerLine = $0 == 80 ? 48 : 32
                                }
                            )) {
                                Text("80mm").tag(80)
                                Text("58mm").tag(58)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 180, alignment: .leading)
                        }
                        divider
                        settingsRow(L10n.t("settings.columns", language)) {
                            Picker("", selection: $store.draft.printerConfig.columnsPerLine) {
                                Text(L10n.t("settings.columns32", language)).tag(32)
                                Text(L10n.t("settings.columns48", language)).tag(48)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        divider
                        settingsRow(L10n.t("settings.encoding", language)) {
                            Picker("", selection: $store.draft.printerConfig.encoding) {
                                ForEach(PrinterConfig.TextEncoding.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        divider
                        Toggle(isOn: $store.draft.printerConfig.cutPaper) {
                            Text(L10n.t("settings.cutPaper", language))
                                .font(.body)
                        }
                        .toggleStyle(.switch)
                    }

                    settingsCard(title: L10n.t("settings.tmdb", language), systemImage: "film") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.t("settings.apiKey", language))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Group {
                                    if showAPIKey {
                                        TextField("", text: $store.draft.tmdbAPIKey, prompt: Text("API Key"))
                                    } else {
                                        SecureField("", text: $store.draft.tmdbAPIKey, prompt: Text("API Key"))
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                Button(showAPIKey
                                       ? L10n.t("settings.hideKey", language)
                                       : L10n.t("settings.showKey", language)) {
                                    showAPIKey.toggle()
                                }
                                .controlSize(.regular)
                            }
                            Text(tmdbKeyStatusText)
                                .font(.caption)
                                .foregroundStyle(store.isTMDBKeyDirty ? .orange : .secondary)
                            Text(L10n.t("settings.apiKeyHint", language))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Button(L10n.t("settings.resetKey", language)) {
                                    store.resetTMDBKey(into: appState)
                                }
                                .disabled(
                                    store.draft.tmdbAPIKey.isEmpty
                                    && store.baseline.tmdbAPIKey.isEmpty
                                )
                                Button(L10n.t("settings.saveKey", language)) {
                                    store.saveTMDBKey(into: appState)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.isTMDBKeyDirty)
                                Spacer()
                            }
                        }
                    }

                    settingsCard(title: L10n.t("settings.about", language), systemImage: "info.circle") {
                        HStack(spacing: 14) {
                            Image(nsImage: aboutAppIcon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ReceiptPrinter")
                                    .font(.title3.weight(.semibold))
                                HStack {
                                    Text(L10n.t("settings.author", language))
                                        .foregroundStyle(.secondary)
                                    Text(L10n.t("settings.authorName", language))
                                }
                                HStack {
                                    Text(L10n.t("settings.version", language))
                                        .foregroundStyle(.secondary)
                                    Text(AppVersion.display)
                                        .font(.body.monospacedDigit())
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }

            footerBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.t("settings.title", appState.settings.appLanguage))
        .onAppear {
            store.reload(from: appState.settings)
            refreshPrinters()
            appState.settingsHasUnsavedChanges = false
        }
        .onChange(of: store.draft) { _, _ in
            appState.settingsHasUnsavedChanges = store.isDirty
        }
    }

    private var tmdbKeyStatusText: String {
        if store.isTMDBKeyDirty {
            return L10n.t("settings.apiKeyDirty", language)
        }
        if store.baseline.tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t("settings.apiKeyEmpty", language)
        }
        return L10n.t("settings.apiKeyStored", language)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("settings.title", language))
                .font(.largeTitle.weight(.semibold))
            Text(L10n.t("settings.subtitle", language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Group {
                    if store.isDirty {
                        Label(L10n.t("settings.dirtyHint", language), systemImage: "pencil.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if let statusMessage = store.statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L10n.t("settings.restoreDefaults", language)) {
                    store.restoreDefaults()
                    appState.settingsHasUnsavedChanges = store.isDirty
                }
                .controlSize(.large)
                Button(L10n.t("settings.save", language)) {
                    store.save(into: appState)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.isDirty)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var divider: some View {
        Divider().opacity(0.55)
    }

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aboutAppIcon: NSImage {
        Self.resolvedAppIcon()
    }

    /// Prefer bundled artwork over `NSApp.applicationIconImage` (often a generic placeholder).
    private static func resolvedAppIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        #endif
        return NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 64, height: 64))
    }

    private func refreshPrinters() {
        do {
            printers = try appState.printService.listPrinters()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
