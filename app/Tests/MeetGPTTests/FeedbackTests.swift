import Foundation
import Testing
@testable import MeetGPT

/// Intercepts every request so nothing leaves the machine, and lets each test
/// dictate the status code the uploader has to reason about.
final class FeedbackStubProtocol: URLProtocol {
    /// `nil` simulates a transport failure — offline, DNS, timeout — as opposed
    /// to an HTTP answer.
    nonisolated(unsafe) static var status: Int? = 202
    nonisolated(unsafe) static var lastBody: [String: Any]?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        status = 202
        lastBody = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        // URLProtocol hands the body over as a stream, not as httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        guard let status = Self.status else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Both suites live under one parent, and the parent is `.serialized`.
///
/// Not tidiness. The store is a global (`FirstMeetingPrompt.defaults`) and both
/// suites drive it, so serializing each separately is not enough — they would
/// still run concurrently WITH EACH OTHER, and one calling `resetForTesting()`
/// mid-assertion in the other is exactly what turned two green suites into nine
/// red tests in a full run. `.serialized` applies recursively, and suites in
/// different files cannot be nested, so they share a file.
///
/// The throwaway defaults suite matters for a second reason: written against
/// `.standard`, these tests leave `feedback.firstMeeting.asked` behind on the
/// machine, which then silently suppresses the prompt during manual testing.
@Suite(.serialized)
struct FeedbackTests {

    fileprivate static func freshDefaults() {
        FirstMeetingPrompt.defaults =
            UserDefaults(suiteName: "cruxwing.tests.feedback") ?? .standard
        FirstMeetingPrompt.resetForTesting()
    }

    /// The prompt gets exactly one chance at the user, so the rules deciding
    /// when it fires matter more than what it looks like.
    @Suite struct Prompt {
        init() { FeedbackTests.freshDefaults() }

        @Test("asks after the first real meeting")
        func asksAfterFirstMeeting() {
            #expect(FirstMeetingPrompt.shouldAsk(meetingsSoFar: 1))
        }

        @Test("stays quiet before any meeting has happened")
        func silentBeforeFirstMeeting() {
            // Nobody can say how the first call went before having one, and
            // asking at launch is the version that gets the app uninstalled.
            #expect(!FirstMeetingPrompt.shouldAsk(meetingsSoFar: 0))
        }

        @Test("stays quiet from the second meeting on")
        func silentAfterFirstMeeting() {
            for count in [2, 3, 17] {
                #expect(!FirstMeetingPrompt.shouldAsk(meetingsSoFar: count))
            }
        }

        @Test("never asks twice, even if the meeting count is somehow one again")
        func neverAsksTwice() {
            FirstMeetingPrompt.markAsked()
            // A counter reset, or a reinstall keeping defaults, must not reopen it.
            #expect(!FirstMeetingPrompt.shouldAsk(meetingsSoFar: 1))
        }

        @Test("a dismissal closes it permanently")
        func dismissalCounts() {
            // markAsked fires when the prompt APPEARS, not when it is answered:
            // somebody who closed it without answering has answered by doing so.
            FirstMeetingPrompt.markAsked()
            #expect(FirstMeetingPrompt.hasBeenAsked)
            #expect(FirstMeetingPrompt.stored == nil)
            #expect(!FirstMeetingPrompt.shouldAsk(meetingsSoFar: 1))
        }

        @Test("keeps the rating, the note and the email")
        func recordsFullResponse() {
            FirstMeetingPrompt.record(
                rating: .good, note: "caught the budget question", email: "someone@example.com")
            let stored = FirstMeetingPrompt.stored
            #expect(stored?.rating == .good)
            #expect(stored?.note == "caught the budget question")
            #expect(stored?.email == "someone@example.com")
        }

        @Test("a rating alone is a complete answer")
        func ratingAloneIsValid() {
            // The email is optional on purpose. Requiring it turns this into a
            // lead form and collects far fewer answers.
            FirstMeetingPrompt.record(rating: .bad, note: nil, email: nil)
            #expect(FirstMeetingPrompt.stored?.rating == .bad)
            #expect(FirstMeetingPrompt.stored?.email == nil)
        }

        @Test("blank input is absent, not empty")
        func blanksBecomeNil() {
            // "" and "   " would otherwise be stored and later uploaded as
            // though the user had deliberately submitted nothing.
            FirstMeetingPrompt.record(rating: .good, note: "   ", email: "\n")
            #expect(FirstMeetingPrompt.stored?.note == nil)
            #expect(FirstMeetingPrompt.stored?.email == nil)
        }

        @Test("answering also marks it asked")
        func answeringClosesIt() {
            FirstMeetingPrompt.record(rating: .good, note: nil, email: nil)
            #expect(FirstMeetingPrompt.hasBeenAsked)
            #expect(!FirstMeetingPrompt.shouldAsk(meetingsSoFar: 1))
        }

        @Test("a new answer is queued for upload")
        func newAnswerIsUnsent() {
            FirstMeetingPrompt.record(rating: .good, note: "worked", email: nil)
            #expect(FirstMeetingPrompt.unsent != nil)
            #expect(FirstMeetingPrompt.stored?.sentAt == nil)
        }

        @Test("a delivered answer stops being queued")
        func sentAnswerLeavesTheQueue() {
            FirstMeetingPrompt.record(rating: .good, note: "worked", email: nil)
            FirstMeetingPrompt.markSent()
            #expect(FirstMeetingPrompt.unsent == nil)
            #expect(FirstMeetingPrompt.stored?.sentAt != nil)
            // The answer survives being sent — it is the evidence.
            #expect(FirstMeetingPrompt.stored?.note == "worked")
        }

        @Test("marking sent with nothing stored does nothing")
        func markSentIsSafeWhenEmpty() {
            FirstMeetingPrompt.markSent()
            #expect(FirstMeetingPrompt.stored == nil)
        }
    }

    /// Delivery. The interesting behaviour is which failures are worth retrying
    /// and which are not — a queue that retries forever and one that gives up
    /// too early both lose the answer.
    @Suite struct Uploader {
        private let session: URLSession

        init() {
            FeedbackTests.freshDefaults()
            FeedbackStubProtocol.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FeedbackStubProtocol.self]
            session = URLSession(configuration: config)
        }

        @Test("sends nothing when the queue is empty")
        func noQueueNoRequest() async {
            // Every launch after delivery takes this path, so it must not cost
            // a request.
            let sent = await FeedbackUploader.flush(session: session)
            #expect(!sent)
            #expect(FeedbackStubProtocol.requestCount == 0)
        }

        @Test("delivers a queued answer and marks it sent")
        func deliversAndMarks() async {
            FirstMeetingPrompt.record(rating: .good, note: "worked", email: nil)
            let sent = await FeedbackUploader.flush(session: session)

            #expect(sent)
            #expect(FirstMeetingPrompt.unsent == nil)
            #expect(FirstMeetingPrompt.stored?.sentAt != nil)
        }

        @Test("sends the rating, the note and the source")
        func sendsExpectedFields() async {
            FirstMeetingPrompt.record(
                rating: .bad, note: "missed the decision", email: "someone@example.com")
            _ = await FeedbackUploader.flush(session: session)

            #expect(FeedbackStubProtocol.lastBody?["rating"] as? String == "bad")
            #expect(FeedbackStubProtocol.lastBody?["note"] as? String == "missed the decision")
            #expect(FeedbackStubProtocol.lastBody?["email"] as? String == "someone@example.com")
            #expect(FeedbackStubProtocol.lastBody?["source"] as? String == FeedbackUploader.source)
        }

        @Test("never sends the local timestamp")
        func omitsClientClock() async {
            // The server stamps its own. A queued answer can be delivered days
            // late, so a device clock would be wrong exactly when it differs.
            FirstMeetingPrompt.record(rating: .good, note: nil, email: nil)
            _ = await FeedbackUploader.flush(session: session)
            #expect(FeedbackStubProtocol.lastBody?["at"] == nil)
        }

        @Test("omits absent optional fields rather than sending null")
        func omitsEmptyOptionals() async {
            FirstMeetingPrompt.record(rating: .good, note: nil, email: nil)
            _ = await FeedbackUploader.flush(session: session)

            #expect(FeedbackStubProtocol.lastBody?["note"] == nil)
            #expect(FeedbackStubProtocol.lastBody?["email"] == nil)
            #expect(FeedbackStubProtocol.lastBody?["rating"] as? String == "good")
        }

        @Test("stays queued when the device is offline")
        func offlineKeepsQueue() async {
            FirstMeetingPrompt.record(rating: .good, note: "on a plane", email: nil)
            FeedbackStubProtocol.status = nil

            let sent = await FeedbackUploader.flush(session: session)
            #expect(!sent)
            #expect(FirstMeetingPrompt.unsent != nil,
                    "an offline answer must survive to the next launch")
        }

        @Test("stays queued on a server error")
        func serverErrorKeepsQueue() async {
            // A 500 is transient by definition; retrying is correct.
            FirstMeetingPrompt.record(rating: .bad, note: "broke", email: nil)
            FeedbackStubProtocol.status = 500

            let sent = await FeedbackUploader.flush(session: session)
            #expect(!sent)
            #expect(FirstMeetingPrompt.unsent != nil)
        }

        @Test("stays queued on a rate limit")
        func rateLimitKeepsQueue() async {
            // 429 is "not now", not "never" — the one 4xx worth retrying.
            FirstMeetingPrompt.record(rating: .good, note: nil, email: nil)
            FeedbackStubProtocol.status = 429

            let sent = await FeedbackUploader.flush(session: session)
            #expect(!sent)
            #expect(FirstMeetingPrompt.unsent != nil)
        }

        @Test("gives up on a rejection that cannot succeed")
        func permanentRejectionLeavesQueue() async {
            // A 400 will be a 400 forever, so retrying every launch is waste.
            // It leaves the queue — but the answer itself stays on disk.
            FirstMeetingPrompt.record(rating: .good, note: "kept locally", email: nil)
            FeedbackStubProtocol.status = 400

            let sent = await FeedbackUploader.flush(session: session)
            #expect(!sent)
            #expect(FirstMeetingPrompt.unsent == nil, "a permanent rejection must stop retrying")
            #expect(FirstMeetingPrompt.stored?.note == "kept locally",
                    "the answer is never discarded")
        }

        @Test("a delivered answer is not sent twice")
        func doesNotResend() async {
            FirstMeetingPrompt.record(rating: .good, note: "worked", email: nil)
            _ = await FeedbackUploader.flush(session: session)
            let after = FeedbackStubProtocol.requestCount

            _ = await FeedbackUploader.flush(session: session)
            #expect(FeedbackStubProtocol.requestCount == after,
                    "a second launch must not re-post")
        }
    }
}
