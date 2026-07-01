import Foundation

struct MatchRules: Codable, Equatable {
    var senders: [String] = []
    var subjectContains: [String] = []
    var bodyContains: [String] = []

    func matches(sender: String, subject: String, body: String) -> Bool {
        let senderLower = sender.lowercased()
        if !senders.isEmpty {
            let senderMatch = senders.contains { pattern in
                let p = pattern.lowercased()
                if p.hasPrefix("@") { return senderLower.hasSuffix(p) }
                return senderLower.contains(p)
            }
            if !senderMatch { return false }
        }
        if !subjectContains.isEmpty {
            if !subjectContains.contains(where: { subject.localizedCaseInsensitiveContains($0) }) {
                return false
            }
        }
        if !bodyContains.isEmpty {
            if !bodyContains.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
                return false
            }
        }
        return true
    }
}

enum FieldSource: String, Codable, CaseIterable, Identifiable {
    case plainText, html
    var id: String { rawValue }
}

enum FieldPick: String, Codable {
    case first, last, all
}

struct FieldExtractor: Codable, Equatable {
    var pattern: String
    var source: FieldSource = .plainText
    var pick: FieldPick = .first
}

struct CinemaRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var cinemaName: String
    var enabled: Bool = true
    var matchRules: MatchRules = MatchRules()
    var templateId: UUID
    var fieldExtractors: [String: FieldExtractor] = [:]
    var updatedAt: Date = Date()
}
