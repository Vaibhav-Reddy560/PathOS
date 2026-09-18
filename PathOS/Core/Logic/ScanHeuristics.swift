import Foundation

nonisolated struct HeuristicScanResult: Equatable, Sendable {
    var kind: ScanKind
    var title: String
    var amount: Double?
    var eventDate: Date?
    var parkingLabel: String?
}

/// Rule-based scan understanding. Used when Apple Intelligence is unavailable,
/// and as a sanity check on the model's output.
nonisolated enum ScanHeuristics {
    static let receiptWords = ["total", "gst", "cgst", "sgst", "invoice", "bill", "subtotal", "receipt", "amount", "₹", "rs.", "inr"]
    static let parkingWords = ["parking", "level", "pillar", "slot", "bay", "basement", "floor", "zone"]

    static func analyze(_ text: String, now: Date = Date()) -> HeuristicScanResult {
        let lower = text.lowercased()
        let title = headline(in: text)

        if receiptWords.contains(where: lower.contains), let amount = totalAmount(in: text) {
            return HeuristicScanResult(kind: .receipt, title: title, amount: amount)
        }
        if parkingWords.contains(where: lower.contains), let label = parkingLabel(in: text) {
            return HeuristicScanResult(kind: .parking, title: "Parked at \(label)", parkingLabel: label)
        }
        if let date = eventDate(in: text, now: now) {
            return HeuristicScanResult(kind: .event, title: title, eventDate: date)
        }
        return HeuristicScanResult(kind: .note, title: title)
    }

    /// First line that looks like words rather than numbers.
    static func headline(in text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let wordy = lines.first { line in line.filter(\.isLetter).count >= 3 }
        return wordy ?? lines.first ?? "Scan"
    }

    /// Prefers the last line mentioning "total"; otherwise the largest currency-marked amount.
    static func totalAmount(in text: String) -> Double? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        let totalLines = lines.filter {
            let lower = $0.lowercased()
            return lower.contains("total") && !lower.contains("subtotal") && !lower.contains("sub total")
        }
        if let line = totalLines.last, let amount = numbers(in: line).max() {
            return amount
        }

        let currencyLines = lines.filter {
            let lower = $0.lowercased()
            return lower.contains("₹") || lower.contains("rs") || lower.contains("inr")
        }
        return currencyLines.flatMap(numbers(in:)).max()
    }

    static func numbers(in line: String) -> [Double] {
        matches(of: #"[0-9][0-9,]*(?:\.[0-9]{1,2})?"#, in: line)
            .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }

    /// e.g. "Level B2", "Pillar C-14", "Slot 45" → "B2 · C-14 · 45".
    static func parkingLabel(in text: String) -> String? {
        let pattern = #"(?i)\b(?:level|floor|basement|pillar|slot|bay|zone)\s*[:#\-]?\s*([A-Z]{0,2}-?\d{1,3}[A-Z]?(?:-\d{1,3})?)"#
        let labels = captureGroups(of: pattern, in: text).map { $0.uppercased() }
        var seen = Set<String>()
        let unique = labels.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    /// First date on the poster that isn't already in the past.
    static func eventDate(in text: String, now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let startOfToday = Calendar.current.startOfDay(for: now)
        return detector.matches(in: text, range: range)
            .compactMap(\.date)
            .first { $0 >= startOfToday }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func captureGroups(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
