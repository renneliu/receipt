import Foundation

enum OrderStatus: String, Codable, CaseIterable, Identifiable {
    case pending, printed, ignored
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return L10n.ui("待打印")
        case .printed: return L10n.ui("已打印")
        case .ignored: return L10n.ui("已忽略")
        }
    }
}

struct PendingOrder: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var messageId: String
    var ruleId: UUID
    var ruleName: String
    var templateId: UUID
    var cinemaName: String
    var subject: String
    var sender: String
    var receivedAt: Date
    var fields: [String: String]
    var missingFields: [String] = []
    var manualFields: [String: String] = [:]
    var emailSnippet: String = ""
    var emailPlainBody: String = ""
    var status: OrderStatus = .pending
    var printedAt: Date?

    var displayTitle: String {
        fields["movieTitle"] ?? fields["movieName"] ?? subject
    }
}
