import Foundation
import Testing
@testable import MeetGPT

/// The single point where outbound text is checked for secrets.
///
/// Four types implement LLMGateway and every feature holds one as an
/// existential. A filter attached to features would be bypassed by the next
/// caller someone adds; wrapping the gateway once means there is no route to a
/// provider that does not pass through here. These tests defend that property,
/// because a redactor nothing routes through is a privacy control in name only.
@Suite("Redacting gateway")
struct RedactingGatewayTests {

    /// Records exactly what the provider would have received.
    private final class SpyGateway: LLMGateway, @unchecked Sendable {
        var seenSystem = ""
        var seenUser = ""

        func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                        onDelta: @escaping (String) -> Void) async throws -> String {
            seenSystem = system; seenUser = user
            return "ok"
        }

        func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                        maxOutputTokens: Int?,
                        onDelta: @escaping (String) -> Void) async throws -> String {
            seenSystem = system; seenUser = user
            return "ok"
        }
    }

    private func model() -> LLMModel { LLMCatalog.all.first! }

    @Test("a card in the user message never reaches the provider")
    func redactsUserMessage() async throws {
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true })

        _ = try await gateway.streamChat(system: "s", user: "charge 4532015112830366",
                                         images: [], model: model()) { _ in }

        #expect(!spy.seenUser.contains("4532015112830366"))
        #expect(spy.seenUser.contains(OutboundRedactor.marker))
    }

    @Test("the system message is filtered too")
    func redactsSystemMessage() async throws {
        // Attached context and connector snippets land in the system half, and
        // that is where a pasted key is most likely to arrive.
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true })

        _ = try await gateway.streamChat(system: "key sk-abcdefghijklmnopqrst", user: "u",
                                         images: [], model: model()) { _ in }

        #expect(!spy.seenSystem.contains("sk-abcdefghijklmnopqrst"))
    }

    @Test("the token-capped overload is filtered identically")
    func redactsOnTheOtherOverload() async throws {
        // Two overloads reach providers. One filtered and one not is the same
        // as none — and the unfiltered one carries the LONGEST payloads, since
        // it exists for whole-document output.
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true })

        _ = try await gateway.streamChat(system: "s", user: "charge 4532015112830366",
                                         images: [], model: model(),
                                         maxOutputTokens: 8000) { _ in }

        #expect(!spy.seenUser.contains("4532015112830366"))
    }

    @Test("clean text passes through byte-identical")
    func cleanTextUntouched() async throws {
        // The overwhelmingly common case. Any rewriting here would silently
        // alter every prompt in the product.
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true })
        let sentence = "Maria will send the contract by Friday, and legal signs it."

        _ = try await gateway.streamChat(system: "system prompt", user: sentence,
                                         images: [], model: model()) { _ in }

        #expect(spy.seenUser == sentence)
        #expect(spy.seenSystem == "system prompt")
    }

    @Test("disabled means genuinely off, not merely quiet")
    func disabledPassesEverything() async throws {
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { false })

        _ = try await gateway.streamChat(system: "s", user: "charge 4532015112830366",
                                         images: [], model: model()) { _ in }

        #expect(spy.seenUser.contains("4532015112830366"))
    }

    @Test("reports what was removed so the request can be marked")
    func reportsFindings() async throws {
        // The acceptance criterion: a redacted request is visibly marked, and a
        // false positive is correctable. Both need the callback.
        let spy = SpyGateway()
        var reported: [OutboundRedactor.Finding] = []
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true },
                                       onRedaction: { reported = $0 })

        _ = try await gateway.streamChat(system: "s", user: "charge 4532015112830366",
                                         images: [], model: model()) { _ in }

        #expect(reported.count == 1)
        #expect(reported.first?.kind == .paymentCard)
    }

    @Test("no callback fires when nothing was removed")
    func silentWhenClean() async throws {
        // A marker on every request would train people to ignore it.
        let spy = SpyGateway()
        var fired = false
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true },
                                       onRedaction: { _ in fired = true })

        _ = try await gateway.streamChat(system: "s", user: "an ordinary sentence",
                                         images: [], model: model()) { _ in }

        #expect(!fired)
    }

    @Test("user terms reach the redactor")
    func userTermsApplied() async throws {
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { ["Falcon"] }, isEnabled: { true })

        _ = try await gateway.streamChat(system: "s", user: "Project Falcon ships in May",
                                         images: [], model: model()) { _ in }

        #expect(!spy.seenUser.contains("Falcon"))
    }

    @Test("the request still goes — redaction never blocks")
    func neverBlocks() async throws {
        // The decision: redact and proceed. A detection must never turn into a
        // failed request.
        let spy = SpyGateway()
        let gateway = RedactingGateway(wrapping: spy, userTerms: { [] }, isEnabled: { true })

        let answer = try await gateway.streamChat(system: "s", user: "card 4532015112830366",
                                                  images: [], model: model()) { _ in }
        #expect(answer == "ok")
    }

    @Test("redaction defaults to on")
    func defaultsToOn() {
        // A privacy control that ships off protects nobody.
        let previous = UserDefaults.standard.object(forKey: "privacy.outboundRedaction")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "privacy.outboundRedaction") }
            else { UserDefaults.standard.removeObject(forKey: "privacy.outboundRedaction") }
        }
        UserDefaults.standard.removeObject(forKey: "privacy.outboundRedaction")
        #expect(Config.outboundRedactionEnabled)
    }
}
