import Foundation

/// Gmail date filter presets; merged into search `q` via `after:` / `before:` (epoch days).
enum GmailTimeRange: String, Codable, CaseIterable, Identifiable {
    case any
    case sixMonths
    case threeMonths
    case oneMonth
    case sevenDays
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "不限"
        case .sixMonths: return "近 6 个月"
        case .threeMonths: return "近 3 个月"
        case .oneMonth: return "近 1 个月"
        case .sevenDays: return "近 7 天"
        case .custom: return "自定义"
        }
    }

    /// Gmail `after:YYYY/MM/DD` fragment (inclusive start of day, local calendar).
    func afterClause(customStart: Date? = nil, now: Date = Date()) -> String? {
        switch self {
        case .any:
            return nil
        case .sixMonths:
            return Self.afterClause(monthsAgo: 6, now: now)
        case .threeMonths:
            return Self.afterClause(monthsAgo: 3, now: now)
        case .oneMonth:
            return Self.afterClause(monthsAgo: 1, now: now)
        case .sevenDays:
            return Self.afterClause(daysAgo: 7, now: now)
        case .custom:
            guard let customStart else { return nil }
            return "after:\(Self.gmailDateString(customStart))"
        }
    }

    /// Optional `before:` for custom end date.
    func beforeClause(customEnd: Date? = nil) -> String? {
        guard self == .custom, let customEnd else { return nil }
        return "before:\(Self.gmailDateString(customEnd))"
    }

    func queryFragment(customStart: Date? = nil, customEnd: Date? = nil, now: Date = Date()) -> String? {
        let parts = [afterClause(customStart: customStart, now: now), beforeClause(customEnd: customEnd)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func afterClause(monthsAgo: Int, now: Date) -> String? {
        guard let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: now) else { return nil }
        return "after:\(gmailDateString(date))"
    }

    private static func afterClause(daysAgo: Int, now: Date) -> String? {
        guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) else { return nil }
        return "after:\(gmailDateString(date))"
    }

    static func gmailDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

/// Extended Gmail filter fields (reserved for sender/subject; time range lives in AppSettings).
struct GmailFilter: Codable, Equatable {
    var senderContains: String = ""
    var subjectContains: String = ""

    func queryFragment() -> String? {
        var clauses: [String] = []
        let sender = senderContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sender.isEmpty {
            clauses.append("from:\(GmailSearchQueryBuilder.escapeGmailTerm(sender))")
        }
        let subject = subjectContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subject.isEmpty {
            clauses.append("subject:\(GmailSearchQueryBuilder.escapeGmailTerm(subject))")
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " ")
    }
}
