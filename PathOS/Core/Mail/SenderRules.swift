import Foundation

/// Who matters in your mail. A rule is one address, or a whole domain written "@college.edu",
/// which also covers its departments ("@cse.college.edu").
nonisolated enum SenderRules {
    /// What you typed, as a rule: lowercased, and a bare "college.edu" read as the domain. Nil when
    /// it's neither an address nor a domain.
    static func normalized(_ text: String) -> String? {
        var rule = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rule.hasPrefix("<"), rule.hasSuffix(">") {
            rule = String(rule.dropFirst().dropLast())
        }
        guard !rule.isEmpty, !rule.contains(" ") else { return nil }
        if !rule.contains("@") {
            rule = "@" + rule
        }
        let parts = rule.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return rule
    }

    static func matches(_ rule: String, address: String) -> Bool {
        let address = address.lowercased()
        guard rule.hasPrefix("@") else { return address == rule }
        let domain = rule.dropFirst()
        return address.hasSuffix("@" + domain) || address.hasSuffix("." + domain)
    }

    static func matchesAny(_ rules: [String], address: String) -> Bool {
        rules.contains { matches($0, address: address) }
    }

    /// Your mail in the order you'd read it: priority senders first, then everyone else, each
    /// newest first as given. Muted senders are left out and counted.
    static func arrange<Item>(
        _ items: [Item],
        address: (Item) -> String,
        priority: [String],
        muted: [String]
    ) -> (priority: [Item], others: [Item], mutedCount: Int) {
        var first: [Item] = [], others: [Item] = [], mutedCount = 0
        for item in items {
            let sender = address(item)
            if matchesAny(muted, address: sender) {
                mutedCount += 1
            } else if matchesAny(priority, address: sender) {
                first.append(item)
            } else {
                others.append(item)
            }
        }
        return (first, others, mutedCount)
    }
}
