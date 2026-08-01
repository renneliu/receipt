import Foundation

/// Clears on-disk working drafts for Quick Print, Excel sequence, and POS cart.
enum WorkingContentDrafts {
    static func clearAll() {
        QuickPrintStore().clear()
        QuickPrintMediaStore().clear()
        QuickPrintStore(filename: "spreadsheet-sequence-draft.rtfd").clear()
        SequenceTemplateStore().clearDraftPlaceholders()
        POSCartDraftStore.clear()
    }
}
