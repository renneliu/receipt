import Foundation

final class CinemaRuleStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cinema_rules.json")
    }

    func loadAll() -> [CinemaRule] {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode([CinemaRule].self, from: data) else { return [] }
        return rules
    }

    func save(_ rule: CinemaRule) {
        var rules = loadAll()
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        persist(rules)
    }

    func delete(_ rule: CinemaRule) {
        var rules = loadAll()
        rules.removeAll { $0.id == rule.id }
        persist(rules)
    }

    private func persist(_ rules: [CinemaRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: fileURL)
        }
    }
}

final class OrderStore {
    private let fileURL: URL
    private var processedMessageIds: Set<String> = []

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("orders.json")
        let idsURL = dir.appendingPathComponent("processed_message_ids.json")
        if let data = try? Data(contentsOf: idsURL),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            processedMessageIds = ids
        }
    }

    func loadAll() -> [PendingOrder] {
        guard let data = try? Data(contentsOf: fileURL),
              let orders = try? JSONDecoder().decode([PendingOrder].self, from: data) else { return [] }
        return orders.sorted { $0.receivedAt > $1.receivedAt }
    }

    func save(_ order: PendingOrder) {
        var orders = loadAll()
        if let idx = orders.firstIndex(where: { $0.id == order.id }) {
            orders[idx] = order
        } else {
            orders.append(order)
        }
        persist(orders)
        markProcessed(order.messageId)
    }

    func hasOrder(messageId: String) -> Bool {
        loadAll().contains { $0.messageId == messageId }
    }

    func hasProcessed(messageId: String) -> Bool {
        processedMessageIds.contains(messageId)
    }

    private func markProcessed(_ messageId: String) {
        processedMessageIds.insert(messageId)
        let dir = fileURL.deletingLastPathComponent()
        let idsURL = dir.appendingPathComponent("processed_message_ids.json")
        if let data = try? JSONEncoder().encode(processedMessageIds) {
            try? data.write(to: idsURL)
        }
    }

    private func persist(_ orders: [PendingOrder]) {
        if let data = try? JSONEncoder().encode(orders) {
            try? data.write(to: fileURL)
        }
    }
}
