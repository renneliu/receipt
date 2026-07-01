import Foundation

enum GmailSearchQueryBuilder {
    /// Builds Gmail `q` from enabled cinema rules plus optional extra filter (empty = no time limit).
    static func build(rules: [CinemaRule], baseQuery: String) -> BuildResult {
        let enabled = rules.filter(\.enabled)
        guard !enabled.isEmpty else {
            return .failure(.noEnabledRules)
        }

        let ruleFragments = enabled.compactMap { rule -> String? in
            guard let fragment = rule.matchRules.gmailSearchFragment() else { return nil }
            return "(\(fragment))"
        }

        let trimmedBase = baseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeOnly = trimmedBase.isEmpty ? nil : trimmedBase

        if ruleFragments.isEmpty {
            guard let timeOnly else {
                return .failure(.rulesMissingCriteria)
            }
            return .success(timeOnly, usedRuleCriteria: false)
        }

        let rulesPart = ruleFragments.count == 1
            ? ruleFragments[0]
            : "(\(ruleFragments.joined(separator: " OR ")))"

        if let timeOnly, !timeOnly.isEmpty {
            return .success("\(rulesPart) \(timeOnly)", usedRuleCriteria: true)
        }
        return .success(rulesPart, usedRuleCriteria: true)
    }

    enum BuildError: LocalizedError {
        case noEnabledRules
        case rulesMissingCriteria

        var errorDescription: String? {
            switch self {
            case .noEnabledRules:
                return "没有启用的影院规则，请先在「影院规则」添加并启用。"
            case .rulesMissingCriteria:
                return "影院规则未配置发件人/主题/正文关键词，无法构建 Gmail 搜索。请在规则中至少填写一项匹配条件。"
            }
        }
    }

    enum BuildResult {
        case success(String, usedRuleCriteria: Bool)
        case failure(BuildError)

        var query: String? {
            if case .success(let q, _) = self { return q }
            return nil
        }
    }
}

extension MatchRules {
    /// Gmail search fragment for this rule (AND between sender / subject / body clauses).
    func gmailSearchFragment() -> String? {
        var clauses: [String] = []

        if !senders.isEmpty {
            let fromClauses = senders.map { sender -> String in
                let trimmed = sender.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("@") {
                    return "from:\(trimmed)"
                }
                return "from:\(GmailSearchQueryBuilder.escapeGmailTerm(trimmed))"
            }
            clauses.append(fromClauses.count == 1 ? fromClauses[0] : "(\(fromClauses.joined(separator: " OR ")))")
        }

        if !subjectContains.isEmpty {
            let subjectClauses = subjectContains.map {
                "subject:\(GmailSearchQueryBuilder.escapeGmailTerm($0))"
            }
            clauses.append(subjectClauses.count == 1 ? subjectClauses[0] : "(\(subjectClauses.joined(separator: " OR ")))")
        }

        if !bodyContains.isEmpty {
            let bodyClauses = bodyContains.map { GmailSearchQueryBuilder.escapeGmailTerm($0) }
            clauses.append(bodyClauses.count == 1 ? bodyClauses[0] : "(\(bodyClauses.joined(separator: " OR ")))")
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : clauses.joined(separator: " ")
    }
}

extension GmailSearchQueryBuilder {
    static func escapeGmailTerm(_ term: String) -> String {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if t.contains(" ") || t.contains(":") {
            return "\"\(t.replacingOccurrences(of: "\"", with: ""))\""
        }
        return t
    }
}
