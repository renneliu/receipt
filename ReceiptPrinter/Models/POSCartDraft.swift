import Foundation

/// Persisted POS main-page working cart (survives sidebar leave / relaunch when retain is on).
struct POSCartDraft: Codable, Equatable {
    var lineItems: [POSLineItem] = []
    var draftCode: String = ""
    var draftName: String = ""
    var draftQuantity: String = ""
    var draftAmount: String = ""
    var surcharge: String = "0"
    var surchargePercentLabel: String?
    var nextAutoCode: Int = 1
    var prefersNameFieldForNextLine: Bool = false
    var activeTemplateId: UUID?
    var editingLineItemId: UUID?
}

enum POSCartDraftStore {
    private static var url: URL {
        AppPaths.subdirectory("POSDraft").appendingPathComponent("cart.json")
    }

    static func load() -> POSCartDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(POSCartDraft.self, from: data)
    }

    static func save(_ draft: POSCartDraft) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(draft) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
