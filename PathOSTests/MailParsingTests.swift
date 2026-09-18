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

    @Test func messagesOpenInTheConnectedAccount() {
        #expect(MailParsing.webURL(messageID: "18f1", account: "me@gmail.com")?.absoluteString == "https://mail.google.com/mail/u/me@gmail.com/#all/18f1")
        #expect(MailParsing.webURL(messageID: "18f1", account: nil)?.absoluteString == "https://mail.google.com/mail/u/0/#all/18f1")
    }
}
