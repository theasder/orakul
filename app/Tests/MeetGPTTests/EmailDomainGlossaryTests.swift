import Foundation
import Testing
@testable import MeetGPT

/// The sign-in email is the earliest company signal the app ever gets — before
/// any app is connected and before the first call. A corporate domain names
/// the employer, and the employer's name is the term most likely to be spoken
/// on every call and most worth spelling right.
@Suite("Email-domain glossary")
struct EmailDomainGlossaryTests {

    @Test("a corporate domain yields the company name")
    func corporateDomain() {
        #expect(EmailDomainGlossary.candidates(fromEmail: "anna@cruxwing.ai")
                == ["Cruxwing"])
    }

    @Test("hyphenated domains become multi-word names")
    func hyphenatedDomain() {
        #expect(EmailDomainGlossary.candidates(fromEmail: "dev@acme-robotics.com")
                == ["Acme Robotics"])
    }

    @Test("short domains read as acronyms, not words")
    func shortDomainIsAcronym() {
        #expect(EmailDomainGlossary.candidates(fromEmail: "sre@ibm.com") == ["IBM"])
    }

    @Test("multi-part public suffixes are stripped")
    func multiPartTLD() {
        #expect(EmailDomainGlossary.candidates(fromEmail: "it@acme.co.uk") == ["Acme"])
        #expect(EmailDomainGlossary.candidates(fromEmail: "ops@acme.com.au") == ["Acme"])
    }

    @Test("freemail providers yield nothing")
    func freemailSkipped() {
        for email in ["a@gmail.com", "b@outlook.com", "c@yandex.ru", "d@mail.ru",
                      "e@icloud.com", "f@proton.me", "g@qq.com", "h@yahoo.co.uk"] {
            #expect(EmailDomainGlossary.candidates(fromEmail: email).isEmpty,
                    "\(email) is not a company")
        }
    }

    @Test("garbage in, nothing out")
    func invalidInput() {
        #expect(EmailDomainGlossary.candidates(fromEmail: "").isEmpty)
        #expect(EmailDomainGlossary.candidates(fromEmail: "no-at-sign").isEmpty)
        #expect(EmailDomainGlossary.candidates(fromEmail: "x@").isEmpty)
        #expect(EmailDomainGlossary.candidates(fromEmail: "x@localhost").isEmpty)
    }

    @Test("case and whitespace do not matter")
    func normalisesInput() {
        #expect(EmailDomainGlossary.candidates(fromEmail: "  Anna@CruxWing.AI  ")
                == ["Cruxwing"])
    }

    @Test("attendee domains become review-gated company suggestions")
    @MainActor
    func attendeeDomainsProposed() {
        let state = AppState()
        state.upcomingMeetings = [UpcomingMeeting(
            id: "evt1", title: "Pilot sync", start: Date(), end: nil,
            attendees: ["ceo@stripe.com", "friend@gmail.com"])]

        state.proposeAttendeeDomainGlossarySuggestions()

        #expect(state.connectedGlossarySuggestions.contains { $0.term == "Stripe" },
                "the counterparty's company must be proposed")
        #expect(!state.connectedGlossarySuggestions.contains {
            $0.term.lowercased().contains("gmail")
        }, "a freemail invitee names nobody")

        // Idempotent across calendar re-polls: same meeting, no duplicates.
        state.proposeAttendeeDomainGlossarySuggestions()
        #expect(state.connectedGlossarySuggestions.filter { $0.term == "Stripe" }.count == 1)
    }
}
