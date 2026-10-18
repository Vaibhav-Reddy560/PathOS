import Foundation

/// A Gmail message as the API returns it with `format=full`. Only the fields PathOS reads.
nonisolated struct GmailMessageResource: Decodable, Sendable {
    var id: String
    var threadId: String
    var labelIds: [String]?
    var snippet: String?
    /// Milliseconds since 1970, as a string.
    var internalDate: String?
    var payload: Part?

    struct Part: Decodable, Sendable {
        var mimeType: String?
        var filename: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?
    }

    struct Header: Decodable, Sendable {
        var name: String
        var value: String
    }

    struct Body: Decodable, Sendable {
        var data: String?
    }
}

nonisolated struct GmailMessageList: Decodable, Sendable {
    struct Reference: Decodable, Sendable {
        var id: String
    }

    var messages: [Reference]?
}

nonisolated struct GmailProfile: Decodable, Sendable {
    var emailAddress: String
}

/// One email, reduced to what triage needs.
nonisolated struct MailMessage: Equatable, Sendable {
    var id: String
    var threadID: String
    var subject: String
    var senderName: String
    var senderAddress: String
    var receivedAt: Date
    var snippet: String
    var body: String
    var labels: [String]
    /// Where the HTML linked its words, in the body: "Track your order" → the tracking page.
    var links: [MailLink] = []

    /// What the on-device model reads: headers, then as much body as fits its context.
    func promptText(bodyLimit: Int = 3_000) -> String {
        """
        From: \(senderName) <\(senderAddress)>
        Subject: \(subject)
        Sent: \(receivedAt.formatted(date: .complete, time: .shortened))

        \(body.prefix(bodyLimit))
        """
    }
}

/// A stretch of a message's text that goes somewhere, in characters from the start of the body.
nonisolated struct MailLink: Equatable, Sendable {
    var start: Int
    var length: Int
    var url: URL
}

/// A message's readable text, with what its links pointed at.
nonisolated struct MailBody: Equatable, Sendable {
    var text: String
    var links: [MailLink] = []
}

nonisolated enum MailParsing {
    static func message(from resource: GmailMessageResource) -> MailMessage {
        let headers = resource.payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { decodeHeader($0.value) }
        }
        let sender = parseSender(header("From") ?? "")
        let received = resource.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
        let snippet = decodeEntities(resource.snippet ?? "")
        let readable = resource.payload.flatMap(readableBody)
        let body = readable?.text ?? ""

        return MailMessage(
            id: resource.id,
            threadID: resource.threadId,
            subject: header("Subject").map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
            senderName: sender.name,
            senderAddress: sender.address,
            receivedAt: received ?? Date(),
            snippet: snippet,
            body: body.isEmpty ? snippet : body,
            labels: resource.labelIds ?? [],
            links: body.isEmpty ? [] : readable?.links ?? []
        )
    }

    // MARK: Body

    /// The readable text of a message: its plain-text part, or its HTML part stripped to text.
    /// Attachments are skipped, however they're nested.
    static func bodyText(of part: GmailMessageResource.Part) -> String? {
        readableBody(of: part)?.text
    }

    /// The same, keeping where the HTML's links went.
    static func readableBody(of part: GmailMessageResource.Part) -> MailBody? {
        var plain: String?
        var html: String?
        collect(part, plain: &plain, html: &html)
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MailBody(text: tidy(plain))
        }
        return html.map(readable(html:))
    }

    private static func collect(_ part: GmailMessageResource.Part, plain: inout String?, html: inout String?) {
        if let filename = part.filename, !filename.isEmpty { return }
        let type = (part.mimeType ?? "").lowercased()
        if type == "text/plain", plain == nil, let text = part.body?.data.flatMap(decodeBase64URL) {
            plain = text
        } else if type == "text/html", html == nil, let text = part.body?.data.flatMap(decodeBase64URL) {
            html = text
        }
        for child in part.parts ?? [] {
            collect(child, plain: &plain, html: &html)
        }
    }

    /// Gmail bodies are base64url without padding.
    static func decodeBase64URL(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func htmlToText(_ html: String) -> String {
        readable(html: html).text
    }

    /// Marks around a link's words, and between them and where it goes, that pass through the
    /// rest of the clean-up untouched: characters no email has any business containing.
    private static let linkOpen: Character = "\u{E000}"
    private static let linkTarget: Character = "\u{E001}"
    private static let linkClose: Character = "\u{E002}"

    /// HTML as readable text, with each link kept on its own words. Stripping every tag used to
    /// take the links with it, and "Track your order" went nowhere.
    static func readable(html: String) -> MailBody {
        var text = html
        for pattern in [#"(?is)<head\b.*?</head>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<script\b.*?</script>"#, #"(?s)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"(?is)<a\b[^>]*?\bhref\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a\s*>"#,
            with: "\(linkOpen)$3\(linkTarget)$2\(linkClose)", options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|tr|li|h[1-6]|table)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // A link around nothing but a picture has no words left to tap.
        text = text.replacingOccurrences(of: "\(linkOpen)\\s*\(linkTarget)[^\(linkClose)]*\(linkClose)", with: "",
                                         options: .regularExpression)
        return extractingLinks(from: tidy(decodeEntities(text)))
    }

    /// Takes the marks back out, noting where each link's words ended up.
    private static func extractingLinks(from marked: String) -> MailBody {
        var text = ""
        var links: [MailLink] = []
        var count = 0
        var index = marked.startIndex
        while index < marked.endIndex {
            let character = marked[index]
            guard character == linkOpen,
                  let middle = marked[index...].firstIndex(of: linkTarget),
                  let end = marked[middle...].firstIndex(of: linkClose) else {
                if character != linkOpen, character != linkTarget, character != linkClose {
                    text.append(character)
                    count += 1
                }
                index = marked.index(after: index)
                continue
            }
            let words = String(marked[marked.index(after: index)..<middle]).filter { $0 != linkOpen }
            let target = String(marked[marked.index(after: middle)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: target), let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto", "tel"].contains(scheme),
               !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                links.append(MailLink(start: count, length: words.count, url: url))
            }
            text += words
            count += words.count
            index = marked.index(after: end)
        }
        return MailBody(text: text, links: links)
    }

    /// Addresses, phone numbers and email addresses written out in the text itself, as links —
    /// anywhere a link from the HTML doesn't already cover.
    static func detectedLinks(in text: String, besides existing: [MailLink] = []) -> [MailLink] {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let taken = existing.map { $0.start..<($0.start + $0.length) }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let url: URL? = match.url ?? match.phoneNumber.flatMap { number in
                URL(string: "tel:" + number.filter { $0.isNumber || $0 == "+" })
            }
            guard let url else { return nil }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            guard !taken.contains(where: { $0.overlaps(start..<(start + length)) }) else { return nil }
            return MailLink(start: start, length: length, url: url)
        }
    }

    /// Collapses the runs of spaces and blank lines that email HTML leaves behind, and drops the
    /// invisible characters marketing mail pads its preview text with.
    static func tidy(_ text: String) -> String {
        let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{00AD}", "\u{034F}", "\u{FEFF}"]
        let cleaned = String(text.filter { !invisible.contains($0) })
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&#39;": "'", "&zwnj;": "", "&zwj;": "", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”",
                     "&ldquo;": "“", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&rarr;": "→", "&bull;": "•",
                     "&copy;": "©", "&reg;": "®", "&trade;": "™", "&rupee;": "₹"]
        guard let regex = try? NSRegularExpression(pattern: #"&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"#) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let entity = String(text[range])
            if let replacement = named[entity.lowercased()] {
                result += replacement
            } else if let scalar = numericEntity(entity) {
                result.unicodeScalars.append(scalar)
            } else {
                result += entity
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func numericEntity(_ entity: String) -> Unicode.Scalar? {
        let inner = entity.dropFirst(2).dropLast()
        let value = inner.first == "x" || inner.first == "X"
            ? UInt32(inner.dropFirst(), radix: 16)
            : UInt32(inner, radix: 10)
        return value.flatMap(Unicode.Scalar.init)
    }

    // MARK: Headers

    /// `"Priya S" <priya@college.edu>` → ("Priya S", "priya@college.edu"). A bare address is its own name.
    static func parseSender(_ from: String) -> (name: String, address: String) {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close else {
            return (trimmed, trimmed)
        }
        let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        let name = trimmed[..<open]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? address : name, address)
    }

    /// Decodes RFC 2047 encoded words (`=?UTF-8?B?…?=`, `=?UTF-8?Q?…?=`). Gmail usually decodes
    /// headers already; this covers the ones it passes through untouched.
    static func decodeHeader(_ value: String) -> String {
        guard value.contains("=?"), let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else {
            return value
        }
        var result = ""
        var cursor = value.startIndex
        var previousWasEncoded = false
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let modeRange = Range(match.range(at: 2), in: value),
                  let textRange = Range(match.range(at: 3), in: value) else { continue }
            let gap = value[cursor..<range.lowerBound]
            // Whitespace between two encoded words is folding, not content.
            if !(previousWasEncoded && gap.allSatisfy(\.isWhitespace)) {
                result += gap
            }
            let encoding = String(value[charsetRange]).lowercased().contains("8859") ? String.Encoding.isoLatin1 : .utf8
            let text = String(value[textRange])
            let decoded: String? = if value[modeRange].lowercased() == "b" {
                Data(base64Encoded: text).flatMap { String(data: $0, encoding: encoding) }
            } else {
                decodeQuotedPrintableWord(text, encoding: encoding)
            }
            result += decoded ?? String(value[range])
            cursor = range.upperBound
            previousWasEncoded = true
        }
        result += value[cursor...]
        return result
    }

    private static func decodeQuotedPrintableWord(_ text: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "_" {
                bytes.append(0x20)
            } else if character == "=",
                      let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex),
                      let byte = UInt8(text[text.index(after: index)..<end], radix: 16) {
                bytes.append(byte)
                index = end
                continue
            } else {
                bytes.append(contentsOf: Array(String(character).utf8))
            }
            index = text.index(after: index)
        }
        return String(data: Data(bytes), encoding: encoding)
    }

    // MARK: Search

    /// Gmail's own categories for mail that's never worth scheduling from.
    static let excludedCategories = ["promotions", "social", "forums"]

    /// The search for mail PathOS hasn't looked at yet. The first check reaches back a few days;
    /// later ones start just before the last check, and already-seen messages are skipped by id.
    static func searchQuery(since: Date?, now: Date = Date()) -> String {
        let window: String
        if let since {
            let overlap = since.addingTimeInterval(-5 * 60)
            window = "after:\(Int(min(overlap, now).timeIntervalSince1970))"
        } else {
            window = "newer_than:3d"
        }
        let exclusions = excludedCategories.map { "-category:\($0)" } + ["-in:chats", "-in:spam", "-in:trash", "-in:sent"]
        return ([window] + exclusions).joined(separator: " ")
    }

    /// The conversation in Gmail's iPhone app. Google doesn't document this link; the account is
    /// the one at that place (from 1) in the app's own list of accounts.
    static func gmailAppURL(threadID: String, accountPosition: Int) -> URL? {
        URL(string: "googlegmail:///cv=\(threadID)/accountId=\(accountPosition)&create-new-tab")
    }
}
