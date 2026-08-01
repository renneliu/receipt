import Foundation
import SwiftUI

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    /// Prefer system UI language (zh* → Chinese, otherwise English).
    static var systemPreferred: AppLanguage {
        for id in Locale.preferredLanguages {
            let lower = id.lowercased()
            if lower.hasPrefix("zh") { return .chinese }
        }
        return .english
    }

    /// Default for new installs: App Store follows system; local/dev stays Chinese.
    static var installDefault: AppLanguage {
        #if APPSTORE
        systemPreferred
        #else
        .chinese
        #endif
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .installDefault
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

/// App language + string tables. Use `L10n.t` for keyed chrome; `L10n.ui("中文原文")` for feature copy.
enum L10n {
    /// Mirrored from saved settings so non-View code (models, AppState) can localize.
    static var current: AppLanguage = .installDefault

    static func t(_ key: String, _ language: AppLanguage) -> String {
        let table = language == .english ? keyedEN : keyedZH
        return table[key] ?? keyedZH[key] ?? key
    }

    /// Localize a Chinese (or already-keyed) UI string for the given / current language.
    static func ui(_ text: String, _ language: AppLanguage? = nil) -> String {
        let lang = language ?? current
        if lang == .chinese {
            return keyedZH[text] ?? text
        }
        if let keyed = keyedEN[text] { return keyed }
        if let mapped = enFromZh[text] { return mapped }
        return text
    }

    // MARK: - Keyed chrome (settings / nav / shared alerts)

    private static let keyedZH: [String: String] = [
        "nav.quickPrint": "快速打印",
        "nav.spreadsheetSequence": "Excel表格序列打印",
        "nav.posReceipt": "POS小票打印",
        "nav.templatePrint": "影票打印",
        "nav.pdfPrint": "PDF打印",
        "nav.templates": "模板管理",
        "nav.designer": "模板设计",
        "nav.diagnostics": "打印诊断",
        "nav.settings": "设置",

        "settings.title": "设置",
        "settings.subtitle": "打印机、语言与启动偏好。修改后请点保存。",
        "settings.general": "常规",
        "settings.firstRun": "首次设置",
        "settings.firstRunHint": "1. 在系统设置中添加 USB 热敏打印机（Generic 驱动）\n2. 下方选择打印机名称",
        "settings.firstRunDone": "我已完成打印机配置",
        "settings.printer": "打印机",
        "settings.cupsPrinter": "CUPS 打印机",
        "settings.none": "未选择",
        "settings.refreshPrinters": "刷新打印机列表",
        "settings.paperEncoding": "纸张与编码",
        "settings.paperWidth": "纸宽",
        "settings.columns": "每行字符宽度",
        "settings.columns32": "32（58mm 推荐）",
        "settings.columns48": "48（80mm 推荐）",
        "settings.encoding": "文本编码",
        "settings.cutPaper": "打印后切纸",
        "settings.startup": "启动",
        "settings.defaultPage": "打开软件时默认功能页",
        "settings.language": "语言",
        "settings.appLanguage": "软件语言",
        "settings.retainWorkingContent": "退出时保留已输入内容",
        "settings.retainWorkingContentHint": "关闭后，退出软件会清空快速打印 / Excel / POS 的草稿内容。",
        "settings.tmdb": "TMDB",
        "settings.apiKey": "API Key",
        "settings.apiKeyHint": "用于「匹配片长」。在 themoviedb.org 申请 API Key。可在此单独保存或重置。",
        "settings.apiKeyStored": "已保存到钥匙串",
        "settings.apiKeyEmpty": "尚未保存 Key",
        "settings.apiKeyDirty": "Key 已修改，尚未保存",
        "settings.saveKey": "保存 Key",
        "settings.resetKey": "重置",
        "settings.keySaved": "API Key 已保存",
        "settings.keyReset": "API Key 已清除",
        "settings.showKey": "显示",
        "settings.hideKey": "隐藏",
        "settings.about": "关于",
        "settings.version": "版本",
        "settings.author": "作者",
        "settings.authorName": "Xiaoyu Liu",
        "settings.save": "保存",
        "settings.restoreDefaults": "还原至默认设置",
        "settings.saved": "已保存",
        "settings.unsavedTitle": "未保存的设置",
        "settings.unsavedMessage": "设置已修改但尚未保存，是否保存？",
        "settings.saveAndLeave": "保存",
        "settings.discardAndLeave": "不保存",
        "settings.cancelLeave": "取消",
        "settings.dirtyHint": "有未保存的更改",
        "error.title": "错误",
        "error.ok": "确定",
        "error.selectPrinter": "请先在设置中选择打印机",
        "error.templateMissing": "找不到关联模板",
        "common.featureRemoved": "此功能已移除",
    ]

    private static let keyedEN: [String: String] = [
        "nav.quickPrint": "Quick Print",
        "nav.spreadsheetSequence": "Excel Sequence Print",
        "nav.posReceipt": "POS Receipt",
        "nav.templatePrint": "Movie Tickets",
        "nav.pdfPrint": "PDF Print",
        "nav.templates": "Templates",
        "nav.designer": "Template Designer",
        "nav.diagnostics": "Print Diagnostics",
        "nav.settings": "Settings",

        "settings.title": "Settings",
        "settings.subtitle": "Printer, language, and startup preferences. Click Save to apply.",
        "settings.general": "General",
        "settings.firstRun": "First-time setup",
        "settings.firstRunHint": "1. Add your USB thermal printer in System Settings (Generic driver)\n2. Select the printer name below",
        "settings.firstRunDone": "I’ve finished printer setup",
        "settings.printer": "Printer",
        "settings.cupsPrinter": "CUPS printer",
        "settings.none": "None",
        "settings.refreshPrinters": "Refresh printer list",
        "settings.paperEncoding": "Paper & encoding",
        "settings.paperWidth": "Paper width",
        "settings.columns": "Characters per line",
        "settings.columns32": "32 (recommended for 58mm)",
        "settings.columns48": "48 (recommended for 80mm)",
        "settings.encoding": "Text encoding",
        "settings.cutPaper": "Cut paper after print",
        "settings.startup": "Startup",
        "settings.defaultPage": "Default page on launch",
        "settings.language": "Language",
        "settings.appLanguage": "App language",
        "settings.retainWorkingContent": "Keep entered content when quitting",
        "settings.retainWorkingContentHint": "When off, quitting clears Quick Print / Excel / POS drafts.",
        "settings.tmdb": "TMDB",
        "settings.apiKey": "API Key",
        "settings.apiKeyHint": "Used for matching movie runtime. Get an API key at themoviedb.org. Save or reset the key here independently.",
        "settings.apiKeyStored": "Saved in Keychain",
        "settings.apiKeyEmpty": "No key saved yet",
        "settings.apiKeyDirty": "Key edited, not saved yet",
        "settings.saveKey": "Save Key",
        "settings.resetKey": "Reset",
        "settings.keySaved": "API Key saved",
        "settings.keyReset": "API Key cleared",
        "settings.showKey": "Show",
        "settings.hideKey": "Hide",
        "settings.about": "About",
        "settings.version": "Version",
        "settings.author": "Author",
        "settings.authorName": "Xiaoyu Liu",
        "settings.save": "Save",
        "settings.restoreDefaults": "Restore defaults",
        "settings.saved": "Saved",
        "settings.unsavedTitle": "Unsaved settings",
        "settings.unsavedMessage": "You have unsaved changes. Save before leaving?",
        "settings.saveAndLeave": "Save",
        "settings.discardAndLeave": "Don’t save",
        "settings.cancelLeave": "Cancel",
        "settings.dirtyHint": "Unsaved changes",
        "error.title": "Error",
        "error.ok": "OK",
        "error.selectPrinter": "Please select a printer in Settings first",
        "error.templateMissing": "Linked template not found",
        "common.featureRemoved": "This feature has been removed",
    ]
}
