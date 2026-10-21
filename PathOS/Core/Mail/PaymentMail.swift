import Foundation

/// Money that's left your accounts, as the mail confirming it says: a bank's debit alert, a card's
/// spend alert, a UPI app's "paid", a shop's own receipt.
///
/// Only what a mail says was paid counts — never an offer, a bill that's due, an OTP, a refund or
/// a payment that failed. Mail from a bank or a payments app is read for any debit; mail from
/// anyone else only when it reads like an alert, with the account or the UPI reference in it.
nonisolated enum PaymentMail {
    nonisolated enum Method: String, Codable, Sendable {
        case upi
        case card
        case transfer
        case wallet
        case other

        var label: String {
            switch self {
            case .upi: "UPI"
            case .card: "Card"
            case .transfer: "Bank transfer"
            case .wallet: "Wallet"
            case .other: "Paid"
            }
        }
    }

    nonisolated struct Payment: Equatable, Sendable {
        var amount: Double
        /// Who it went to: "Swiggy", "Ramesh Kumar".
        var payee: String?
        var method: Method
        /// The UPI reference, or the bank's or shop's own number for it.
        var reference: String?
        /// "1234": the account or card it left, as the alert masks it.
        var account: String?
    }

    /// Banks and payments apps, by the domains their mail comes from.
    static let senders: [(name: String, domains: [String])] = [
        ("HDFC Bank", ["hdfcbank.net", "hdfcbank.com", "hdfcbank.bank.in"]),
        ("ICICI Bank", ["icicibank.com", "icici.bank.in"]),
        ("SBI", ["sbi.co.in", "sbicard.com", "sbi.bank.in"]),
        ("Axis Bank", ["axisbank.com", "axis.bank.in"]),
        ("Kotak", ["kotak.com", "kotak.bank.in"]),
        ("Yes Bank", ["yesbank.in"]),
        ("IDFC FIRST Bank", ["idfcfirstbank.com"]),
        ("IndusInd Bank", ["indusind.com"]),
        ("Bank of Baroda", ["bankofbaroda.com", "bankofbaroda.co.in"]),
        ("Canara Bank", ["canarabank.com", "canarabank.in"]),
        ("Union Bank", ["unionbankofindia.co.in", "unionbankofindia.bank.in"]),
        ("PNB", ["pnb.co.in"]),
        ("Federal Bank", ["federalbank.co.in"]),
        ("AU Bank", ["aubank.in"]),
        ("RBL Bank", ["rblbank.com"]),
        ("Standard Chartered", ["sc.com"]),
        ("HSBC", ["hsbc.co.in"]),
        ("Google Pay", ["google.com"]),
        ("PhonePe", ["phonepe.com"]),
        ("Paytm", ["paytm.com", "paytmbank.com"]),
        ("Amazon Pay", ["amazonpay.in"]),
        ("CRED", ["cred.club"]),
        ("Jupiter", ["jupiter.money"]),
        ("Fi", ["fi.money"]),
        ("OneCard", ["getonecard.app"]),
        ("slice", ["sliceit.com"]),
    ]

    /// The bank or payments app a mail is from, by the address's domain or a subdomain of it.
    static func sender(of address: String) -> String? {
        guard let domain = address.lowercased().split(separator: "@").last.map(String.init) else { return nil }
        return senders.first { sender in
            sender.domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }?.name
    }

    /// The Gmail search for payment mail. A payments app's receipts can land in Promotions, which
    /// the everyday search leaves out, so they're asked for by sender as well.
    static func searchQuery(since: Date?, now: Date = Date()) -> String {
        let window = since.map { "after:\(Int(min($0.addingTimeInterval(-5 * 60), now).timeIntervalSince1970))" } ?? "newer_than:3d"
        // Google sends far more than Google Pay's receipts; its search is by what they say.
        let banks = senders.flatMap(\.domains).filter { $0 != "google.com" }.map { "from:\($0)" }
        return "\(window) {\(banks.joined(separator: " ")) \"debited\" \"you paid\" \"paid to\"} -in:spam -in:trash"
    }

    // MARK: Reading one

    /// What a debit alert, a UPI receipt or a card alert says was paid. `isKnownSender` is a bank or
    /// a payments app; anything else has to look like an alert to be believed.
    static func payment(subject: String, body: String, isKnownSender: Bool) -> Payment? {
        let lines = (subject + "\n" + body).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The line that says money went, and the sentence on it that does: a whole alert can
        // arrive as one line, footer and all.
        guard let index = lines.firstIndex(where: isDebit),
              let sentence = sentences(lines[index]).first(where: isDebit) ?? lines[safe: index],
              let amount = amount(on: sentence) ?? amount(on: lines[index]) ?? lines[safe: index + 1].flatMap(amount(on:))
        else { return nil }
        // Said of this payment — in the subject or the sentence — not of anything in a footer.
        let said = (subject + " " + sentence).lowercased()
        guard !notSpent.contains(where: { mentions($0, in: said) }) else { return nil }
        let text = lines[index...min(lines.count - 1, index + 6)].joined(separator: "\n")
        let account = account(in: text)
        let reference = reference(in: text)
        let lower = text.lowercased()
        guard isKnownSender || account != nil || reference != nil || lower.contains("upi") else { return nil }
        return Payment(amount: amount, payee: payee(in: text), method: method(lower), reference: reference, account: account)
    }

    /// What a shop's own receipt says was paid: "Order Total", "Amount paid", "Grand Total". Only
    /// an amount that's labelled as the total counts — not an offer further down.
    static func receiptTotal(subject: String, body: String) -> Double? {
        let lower = (subject + "\n" + body.prefix(1_500)).lowercased()
        guard !["cancelled", "canceled", "refund", "failed"].contains(where: subject.lowercased().contains),
              !lower.contains("payment pending") else { return nil }
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard ["order total", "grand total", "total paid", "amount paid", "total amount", "paid via", "you paid", "total payable"]
                    .contains(where: lower.contains), !lower.contains("subtotal") else { continue }
            if let total = amounts(in: line).last ?? lines[safe: index + 1].flatMap({ amounts(in: $0).first }) {
                return total
            }
        }
        return nil
    }

    // MARK: Parts

    /// A line's sentences: "…debited for Rs 250.00 on 21-Oct-26. Info: …" is two.
    private static func sentences(_ line: String) -> [String] {
        line.split(separator: #/[.!?]\s+/#).map(String.init)
    }

    /// The phrase as words of its own: "atm" isn't in "treatment".
    private static func mentions(_ phrase: String, in text: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b", options: .regularExpression) != nil
    }

    /// Phrases that say money went out, as banks and apps put it.
    static let debitPhrases = [
        "debited", "debit of", "has a debit", "amount debited", "you paid", "paid to", "paid ₹", "paid rs", "paid inr",
        "payment of", "payment successful", "paid successfully", "successfully paid", "sent rs", "sent ₹", "sent inr",
        "money sent", "transaction of", "used for a transaction", "has been used", "spent", "txn of", "purchase of",
        "for using your", "transaction at",
    ]

    /// Said of a payment that wasn't one, or isn't yet: left out wherever it's said near the amount.
    static let notSpent = [
        "otp", "one time password", "verification code", "refund", "reversed", "reversal", "cashback", "failed",
        "declined", "unsuccessful", "could not be", "not processed", "payment request", "requested you", "is due",
        "due on", "due date", "minimum amount due", "statement", "mandate", "will be debited", "scheduled",
        "credited to your", "has been credited", "received from", "withdrawn", "atm", "payment received",
        "has been received", "card bill", "towards your credit card",
    ]

    private static func isDebit(_ line: String) -> Bool {
        let lower = line.lowercased()
        return debitPhrases.contains(where: lower.contains) && amount(on: line) != nil
    }

    /// The amount on a line, past any balance or limit it also mentions.
    static func amount(on line: String) -> Double? {
        for match in line.matches(of: #/(?i)(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/#) {
            let before = line[..<match.range.lowerBound].suffix(28).lowercased()
            guard !["bal", "balance", "available", "avl", "limit"].contains(where: before.contains),
                  let value = Double(match.1.replacingOccurrences(of: ",", with: "")), value > 0, value < 10_00_000 else { continue }
            return value
        }
        return nil
    }

    static func amounts(in text: String) -> [Double] {
        text.matches(of: #/(?i)(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/#).compactMap {
            Double($0.1.replacingOccurrences(of: ",", with: ""))
        }.filter { $0 > 0 && $0 < 10_00_000 }
    }

    /// "XX1234", "**1234", "ending 1234", "A/c no. XX1234": the last digits of the account or card.
    static func account(in text: String) -> String? {
        if let match = text.firstMatch(of: #/(?i)\b(?:a\/c|acct|account|ac|card)\b[^0-9\n]{0,24}?[x*•]+\s?([0-9]{3,6})\b/#) {
            return String(match.1)
        }
        return text.firstMatch(of: #/(?i)ending\s*(?:with|in)?\s*[x*]*([0-9]{4})\b/#).map { String($0.1) }
    }

    /// The UPI reference or the transaction's number.
    static func reference(in text: String) -> String? {
        for match in text.matches(of: #/(?i)(?:upi\s*)?(?:ref(?:erence)?\.?\s*(?:no\.?|number|id)?|utr(?:\s*no\.?)?|transaction\s*(?:reference\s*)?(?:id|number|no\.?)|txn\s*(?:id|no\.?))\s*(?:is)?\s*[:#\-]?\s*([A-Z0-9]{8,22})\b/#)
        where match.1.contains(where: \.isNumber) {
            return String(match.1)
        }
        // Folded into the description: "UPI/P2M/429512345678/SWIGGY", "UPI-429512345678-SWIGGY".
        return text.firstMatch(of: #/(?i)upi[\/\-](?:p2[am][\/\-])?([0-9]{9,14})/#).map { String($0.1) }
    }

    /// Who was paid, where the mail says.
    static func payee(in text: String) -> String? {
        let patterns: [Regex<(Substring, Substring)>] = [
            // A VPA and the name banks print after it: "to VPA swiggy@icici SWIGGY on".
            #/(?i)to\s+vpa\s+\S+\s+([A-Za-z][A-Za-z0-9 .&'\-]{1,40}?)(?=\s+on\b|\s+ref|\.|,|\n|$)/#,
            #/(?i)upi[\/\-](?:p2[am][\/\-])?[0-9]{9,14}[\/\-]([A-Za-z][^\/\n.]{1,40})/#,
            #/(?i)info:\s*(?:upi[\/\-])?(?:[0-9]+[\/\-])?([A-Za-z][A-Za-z0-9 .&'\-]{1,40})/#,
            #/(?i)(?:paid to|sent to|payment to|transfer to|paid successfully to)\s+([A-Za-z][A-Za-z0-9 .&'\-]{1,40}?)(?=\s+on\b|\s+via\b|\s+using\b|\s+ref|\s+upi|\s+from\b|\s+was\b|\s+is\b|\.|,|\n|$)/#,
            // "You paid ₹250 to Swiggy", "Payment of Rs 250 to Swiggy was successful".
            #/(?i)(?:paid|sent|payment of)\s+(?:₹|rs\.?|inr)\s*[0-9][0-9,]*(?:\.[0-9]{1,2})?\s+to\s+([A-Za-z][A-Za-z0-9 .&'\-]{1,40}?)(?=\s+on\b|\s+via\b|\s+using\b|\s+ref|\s+from\b|\s+was\b|\s+is\b|\s+successful|\.|,|\n|$)/#,
            #/(?:\s|^)at\s+([A-Z][A-Za-z0-9 .&'*\-]{1,40}?)(?=\s+on\b|\s+via\b|\.\s|\.$|,|\n|$)/#,
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern) {
                let name = tidy(String(match.1))
                if name.count >= 2, !["your", "you", "a/c", "account"].contains(name.lowercased()) { return name }
            }
        }
        // Only the VPA: "swiggy.instamart@hdfcbank" → "Swiggy Instamart".
        // A UPI handle has no dot after the @, which tells it from an email address.
        if let vpa = text.firstMatch(of: #/(?i)\b([a-z0-9][a-z0-9._\-]{1,40})@[a-z]{2,16}\b(?!\.[a-z])/#) {
            let handle = String(vpa.1)
            guard !handle.allSatisfy(\.isNumber) else { return nil }
            return tidy(handle.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " "))
        }
        return nil
    }

    /// "SWIGGY LIMITED " → "Swiggy Limited".
    private static func tidy(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,-*:\t"))
        guard trimmed == trimmed.uppercased() || trimmed == trimmed.lowercased() else { return trimmed }
        return trimmed.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func method(_ lower: String) -> Method {
        if lower.contains("upi") || lower.contains("vpa") { return .upi }
        if lower.contains("card") { return .card }
        if ["neft", "imps", "rtgs", "net banking", "netbanking"].contains(where: lower.contains) { return .transfer }
        if lower.contains("wallet") { return .wallet }
        return .other
    }
}

/// The day's, the month's or the year's spending: every payment once, however many mails told of it.
nonisolated enum Spending {
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: UUID
        var at: Date
        var amount: Double
        /// Who was paid.
        var payee: String?
        /// Who said so: "HDFC Bank", "Uber".
        var source: String
        var method: PaymentMail.Method
        var reference: String?
        var account: String?
        /// A shop's or a ride app's own receipt, rather than the bank's word for it.
        var isReceipt: Bool
    }

    /// A shop's receipt comes up to a couple of hours after the bank's alert: a food order's, once
    /// it's delivered. Half an hour the other way, for a receipt that comes first.
    static let receiptAfterDebit: TimeInterval = 2 * 3_600
    static let receiptBeforeDebit: TimeInterval = 30 * 60

    /// Every payment once. The bank's alert and the shop's receipt for the same payment are one,
    /// named after the shop; two alerts for one payment are one. Two payments of the same amount,
    /// each with its own reference, are two.
    static func combined(_ entries: [Entry]) -> [Entry] {
        let sorted = entries.sorted { $0.at < $1.at }
        var debits: [Entry] = []
        for entry in sorted where !entry.isReceipt {
            let isRepeat = debits.contains { kept in
                if let a = kept.reference, let b = entry.reference { return a == b }
                return sameAmount(kept, entry) && kept.source == entry.source && abs(kept.at.timeIntervalSince(entry.at)) <= 120
            }
            if !isRepeat { debits.append(entry) }
        }
        var receipts: [Entry] = []
        for entry in sorted where entry.isReceipt {
            let isRepeat = receipts.contains { kept in
                guard kept.source == entry.source else { return false }
                if let a = kept.reference, let b = entry.reference { return a == b }
                return sameAmount(kept, entry) && abs(kept.at.timeIntervalSince(entry.at)) <= 12 * 3_600
            }
            if !isRepeat { receipts.append(entry) }
        }

        var matched = Set<UUID>()
        var result: [Entry] = []
        var unmatchedReceipts: [Entry] = []
        for receipt in receipts {
            let candidates = debits.filter { debit in
                !matched.contains(debit.id) && sameAmount(debit, receipt)
                    && receipt.at.timeIntervalSince(debit.at) <= receiptAfterDebit
                    && debit.at.timeIntervalSince(receipt.at) <= receiptBeforeDebit
            }
            guard let debit = candidates.min(by: { abs($0.at.timeIntervalSince(receipt.at)) < abs($1.at.timeIntervalSince(receipt.at)) }) else {
                unmatchedReceipts.append(receipt)
                continue
            }
            matched.insert(debit.id)
            var merged = debit
            merged.payee = receipt.payee ?? receipt.source
            result.append(merged)
        }
        result += debits.filter { !matched.contains($0.id) } + unmatchedReceipts
        return result.sorted { $0.at < $1.at }
    }

    static func total(_ entries: [Entry]) -> Double {
        entries.map(\.amount).reduce(0, +)
    }

    /// Who the money went to, most first.
    static func byPayee(_ entries: [Entry]) -> [(payee: String, amount: Double, count: Int)] {
        Dictionary(grouping: entries) { $0.payee ?? $0.source }
            .map { (payee: $0.key, amount: total($0.value), count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
    }

    private static func sameAmount(_ a: Entry, _ b: Entry) -> Bool {
        abs(a.amount - b.amount) <= max(1, 0.01 * max(a.amount, b.amount))
    }
}
