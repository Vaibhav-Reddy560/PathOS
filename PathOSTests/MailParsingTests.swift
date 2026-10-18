import Foundation
import Testing
@testable import PathOS

struct MailParsingTests {
    private func encoded(_ text: String) -> String {
        Data(text.utf8).base64URLEncodedString()
    }

    private func resource(_ json: String) throws -> GmailMessageResource {
        try JSONDecoder().decode(GmailMessageResource.self, from: Data(json.utf8))
    }

    @Test func thePlainPartIsReadAndAttachmentsAreNot() throws {
        let json = """
        {"id":"18f1","threadId":"18f0","labelIds":["INBOX","CATEGORY_UPDATES"],
         "snippet":"Your talk is confirmed &amp; scheduled","internalDate":"1800000000000",
         "payload":{"mimeType":"multipart/mixed",
          "headers":[{"name":"From","value":"\\"IEEE Bangalore\\" <events@ieee.org>"},{"name":"subject","value":" Talk confirmed "}],
          "parts":[
            {"mimeType":"multipart/alternative","parts":[
              {"mimeType":"text/plain","body":{"data":"\(encoded("Your talk is on 21 Sep at 2 PM.\r\n\r\n\r\n\r\nSee   you there"))"}},
              {"mimeType":"text/html","body":{"data":"\(encoded("<p>HTML version</p>"))"}}]},
            {"mimeType":"text/plain","filename":"agenda.txt","body":{"data":"\(encoded("Attachment text"))"}}]}}
        """
        let message = MailParsing.message(from: try resource(json))
        #expect(message.subject == "Talk confirmed")
        #expect(message.senderName == "IEEE Bangalore")
        #expect(message.senderAddress == "events@ieee.org")
        #expect(message.body == "Your talk is on 21 Sep at 2 PM.\n\nSee you there")
        #expect(message.snippet == "Your talk is confirmed & scheduled")
        #expect(message.receivedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(message.labels == ["INBOX", "CATEGORY_UPDATES"])
    }

    @Test func htmlOnlyMailComesOutAsReadableText() {
        let html = """
        <html><head><title>x</title><style>.a{color:red}</style></head><body>
        <div>Hackathon&nbsp;&amp;&nbsp;Demo Day</div><table><tr><td>Date</td><td>Sat, 21 Sep</td></tr></table>
        <p>Venue: MG&#39;s Hall<br>Bengaluru &#x20B9;0 entry</p><script>track()</script>
        <span style="display:none">&zwnj;&nbsp;&zwnj;&nbsp;</span></body></html>
        """
        #expect(MailParsing.htmlToText(html) == "Hackathon & Demo Day\nDate Sat, 21 Sep\n\nVenue: MG's Hall\nBengaluru ₹0 entry")
    }

    @Test func aMessageWithNoBodyFallsBackToItsSnippet() throws {
        let json = #"{"id":"1","threadId":"1","snippet":"Meeting moved to 4 PM","payload":{"mimeType":"multipart/mixed","parts":[]}}"#
        #expect(MailParsing.message(from: try resource(json)).body == "Meeting moved to 4 PM")
    }

    @Test func base64URLSurvivesTheCharactersPlainBase64Uses() {
        let text = "ÿ>?ûüý~ ₹ subjects?>"
        let standard = Data(text.utf8).base64EncodedString()
        // Only meaningful if plain base64 would have used the characters base64url replaces.
        #expect(standard.contains("+") || standard.contains("/"))
        let urlSafe = Data(text.utf8).base64URLEncodedString()
        #expect(!urlSafe.contains("+") && !urlSafe.contains("/") && !urlSafe.contains("="))
        #expect(MailParsing.decodeBase64URL(urlSafe) == text)
    }

    @Test func sendersAreReadInEveryUsualShape() {
        let quoted = MailParsing.parseSender("\"Priya S\" <priya@college.edu>")
        #expect(quoted.name == "Priya S")
        #expect(quoted.address == "priya@college.edu")

        let bare = MailParsing.parseSender("Placement Cell <placements@college.edu>")
        #expect(bare.name == "Placement Cell")

        let addressOnly = MailParsing.parseSender("noreply@irctc.co.in")
        #expect(addressOnly.name == "noreply@irctc.co.in")
        #expect(addressOnly.address == "noreply@irctc.co.in")

        #expect(MailParsing.parseSender("<alerts@bank.in>").name == "alerts@bank.in")
    }

    @Test func encodedHeadersAreDecoded() {
        let base64 = Data("₹ Refund processed".utf8).base64EncodedString()
        #expect(MailParsing.decodeHeader("=?UTF-8?B?\(base64)?=") == "₹ Refund processed")
        #expect(MailParsing.decodeHeader("=?utf-8?Q?Caf=C3=A9_meetup?= today") == "Café meetup today")
        // The space between two encoded words is folding, not part of the text.
        #expect(MailParsing.decodeHeader("=?UTF-8?Q?Hello_?= =?UTF-8?Q?world?=") == "Hello world")
        #expect(MailParsing.decodeHeader("Plain subject") == "Plain subject")
    }

    @Test func theSearchSkipsNoiseAndOverlapsTheLastCheck() {
        let first = MailParsing.searchQuery(since: nil)
        #expect(first.hasPrefix("newer_than:3d "))
        for exclusion in ["-category:promotions", "-category:social", "-category:forums", "-in:spam", "-in:trash", "-in:sent"] {
            #expect(first.contains(exclusion))
        }
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        // Five minutes of overlap, so mail arriving mid-check isn't missed; ids stop it being read twice.
        #expect(MailParsing.searchQuery(since: since, now: since.addingTimeInterval(3_600)).hasPrefix("after:1799999700 "))
    }

    /// Gmail's app, at the conversation, in the account at that place in its list. Gmail on the
    /// web was tried first, and on a phone it showed an error page.
    @Test func messagesOpenInGmailsApp() {
        #expect(MailParsing.gmailAppURL(threadID: "18f1a2", accountPosition: 2)?.absoluteString
                == "googlegmail:///cv=18f1a2/accountId=2&create-new-tab")
    }

    // MARK: Links

    /// A link keeps its words and where it goes; the words read as before.
    @Test func linksKeepWhereTheyGo() throws {
        let html = #"<p>Your order has shipped. <a href="https://amazon.in/track?id=1&amp;ref=x" style="color:blue"><span>Track your order</span></a> or <a href='mailto:help@shop.in'>write to us</a>.</p><a href="https://x.in/p"><img src="logo.png"></a>"#
        let body = MailParsing.readable(html: html)
        #expect(body.text == "Your order has shipped. Track your order or write to us.")
        #expect(body.links.count == 2)
        let track = try #require(body.links.first)
        let start = body.text.index(body.text.startIndex, offsetBy: track.start)
        #expect(String(body.text[start...].prefix(track.length)) == "Track your order")
        #expect(track.url.absoluteString == "https://amazon.in/track?id=1&ref=x")
        #expect(body.links.last?.url.scheme == "mailto")
    }

    /// Addresses and phone numbers written out in plain text become links too.
    @Test func plainTextAddressesAndNumbersAreFound() {
        let text = "Call 080 4567 8901 or see https://bookmyshow.com/booking/ABC123 for details."
        let links = MailParsing.detectedLinks(in: text)
        #expect(links.contains { $0.url.scheme == "tel" })
        #expect(links.contains { $0.url.absoluteString.hasPrefix("https://bookmyshow.com/booking/ABC123") })
    }
}
