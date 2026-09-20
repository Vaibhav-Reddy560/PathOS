import Testing
@testable import PathOS

/// Priority and muted senders: an address, or everyone at a domain.
struct SenderRulesTests {
    @Test func whatYouTypeBecomesARule() {
        #expect(SenderRules.normalized("  Dean@BMSCE.ac.in ") == "dean@bmsce.ac.in")
        #expect(SenderRules.normalized("bmsce.ac.in") == "@bmsce.ac.in")
        #expect(SenderRules.normalized("@bmsce.ac.in") == "@bmsce.ac.in")
        #expect(SenderRules.normalized("<noreply@college.edu>") == "noreply@college.edu")
        #expect(SenderRules.normalized("not an address") == nil)
        #expect(SenderRules.normalized("someone@localhost") == nil)
        #expect(SenderRules.normalized("") == nil)
    }

    @Test func aDomainCoversItsDepartments() {
        #expect(SenderRules.matches("@bmsce.ac.in", address: "Principal@bmsce.ac.in"))
        #expect(SenderRules.matches("@bmsce.ac.in", address: "hod@cse.bmsce.ac.in"))
        #expect(!SenderRules.matches("@bmsce.ac.in", address: "someone@notbmsce.ac.in"))
        #expect(SenderRules.matches("dean@bmsce.ac.in", address: "DEAN@bmsce.ac.in"))
        #expect(!SenderRules.matches("dean@bmsce.ac.in", address: "hod@bmsce.ac.in"))
    }

    /// Priority first, the rest after, both in the order given; muted ones counted, not shown.
    /// A muted address inside a priority domain stays muted: it's the more particular wish.
    @Test func mailIsArrangedPriorityFirst() {
        let mail = ["offers@shop.com", "hod@cse.bmsce.ac.in", "friend@gmail.com", "noreply@bmsce.ac.in", "dean@bmsce.ac.in"]
        let arranged = SenderRules.arrange(mail, address: { $0 }, priority: ["@bmsce.ac.in"], muted: ["noreply@bmsce.ac.in", "@shop.com"])
        #expect(arranged.priority == ["hod@cse.bmsce.ac.in", "dean@bmsce.ac.in"])
        #expect(arranged.others == ["friend@gmail.com"])
        #expect(arranged.mutedCount == 2)
    }

    /// The account chips: a Gmail address by its name, a college or work one by its organisation.
    @Test func accountsAreNamedSoYouCanTellThemApart() {
        #expect(MailInbox.shortName("vaibhav.reddy560@gmail.com") == "vaibhav.reddy560")
        #expect(MailInbox.shortName("1bm22cs001@bmsce.ac.in") == "bmsce.ac.in")
    }
}
