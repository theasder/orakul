import Foundation
import Testing
@testable import MeetGPT

/// Choosing WHICH Fireflies meeting belongs to this call.
///
/// Three tests already pin the base behaviour — nearest wins, a match window
/// accepts this call and rejects a different one (see TranscriptEnhancementTests).
/// This suite layers the dimensions underneath that choice: the wire formats the
/// answer is parsed out of.
///
/// Worth the depth because the failure is silent and expensive. A date that
/// fails to parse becomes `nil`, which sorts as infinitely far away, so a
/// listing whose format shifted does not error — it quietly attaches SOMEONE
/// ELSE'S meeting transcript to your call, and the merge then rewrites your
/// transcript with it.
@Suite("Fireflies meeting match — wire formats")
struct FirefliesMeetingMatchTests {

    private let target = Date(timeIntervalSince1970: 1_700_000_000)

    private func pick(_ list: String, near: Date? = nil,
                      within: TimeInterval? = nil) -> (id: String?, title: String?) {
        MCPConnectionManager.pickFirefliesMeeting(from: list, near: near, within: within)
    }

    // MARK: - Epoch shapes

    @Test("milliseconds and seconds since epoch both resolve to the same instant")
    func acceptsBothEpochScales() {
        // Fireflies returns either. Read as seconds, a millisecond timestamp
        // lands in the year 55000 — infinitely far from the session, so the
        // right meeting loses to a stale one.
        let seconds = target.addingTimeInterval(60).timeIntervalSince1970
        let milliseconds = seconds * 1000

        let asSeconds = """
        [{"id":"near","title":"This call","date":\(seconds)},
         {"id":"far","title":"Last week","date":\(seconds - 604_800)}]
        """
        let asMilliseconds = """
        [{"id":"near","title":"This call","date":\(milliseconds)},
         {"id":"far","title":"Last week","date":\((seconds - 604_800) * 1000)}]
        """
        #expect(pick(asSeconds, near: target).id == "near")
        #expect(pick(asMilliseconds, near: target).id == "near")
    }

    @Test("an integer timestamp is read the same as a floating-point one")
    func acceptsIntegerTimestamps() {
        // JSON gives no type hint: 1700000060 decodes as Int, 1700000060.0 as
        // Double, and only one branch handled each.
        let list = """
        [{"id":"near","title":"This call","date":\(Int(target.timeIntervalSince1970) + 60)},
         {"id":"far","title":"Yesterday","date":\(Int(target.timeIntervalSince1970) - 86_400)}]
        """
        #expect(pick(list, near: target).id == "near")
    }

    @Test("ISO 8601 dates parse, with and without fractional seconds")
    func acceptsISO8601() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let near = formatter.string(from: target.addingTimeInterval(60))
        let far = formatter.string(from: target.addingTimeInterval(-86_400))

        #expect(pick("""
        [{"id":"near","title":"This call","date":"\(near)"},
         {"id":"far","title":"Yesterday","date":"\(far)"}]
        """, near: target).id == "near")

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(pick("""
        [{"id":"near","title":"This call","date":"\(fractional.string(from: target.addingTimeInterval(60)))"},
         {"id":"far","title":"Yesterday","date":"\(far)"}]
        """, near: target).id == "near")
    }

    @Test("a date-only string still places the meeting on that day")
    func acceptsDateOnlyStrings() {
        // Some listings carry "2023-11-14" with no time. Unparsed it would be
        // nil and lose to anything with a timestamp.
        let list = """
        [{"id":"dated","title":"Same day","date":"2023-11-14"},
         {"id":"undated","title":"No date"}]
        """
        #expect(pick(list, near: target).id == "dated")
    }

    // MARK: - Field naming

    @Test("every id spelling Fireflies uses is recognised")
    func acceptsIdAliases() {
        for key in ["id", "transcript_id", "transcriptId"] {
            let list = """
            [{"\(key)":"found","title":"This call","date":\(target.timeIntervalSince1970)}]
            """
            #expect(pick(list, near: target).id == "found", "id key '\(key)' was not read")
        }
    }

    @Test("every date spelling is recognised, so nothing silently sorts as far away")
    func acceptsDateAliases() {
        for key in ["date", "meeting_date", "meetingDate", "createdAt", "created_at", "start_time"] {
            let list = """
            [{"id":"near","title":"This call","\(key)":\(target.timeIntervalSince1970 + 60)},
             {"id":"far","title":"Yesterday","\(key)":\(target.timeIntervalSince1970 - 86_400)}]
            """
            #expect(pick(list, near: target).id == "near", "date key '\(key)' was not read")
        }
    }

    // MARK: - Envelope shapes

    @Test("a bare array and every named envelope are all unwrapped")
    func acceptsEnvelopeShapes() {
        let rows = """
        {"id":"near","title":"This call","date":\(target.timeIntervalSince1970 + 60)},
        {"id":"far","title":"Yesterday","date":\(target.timeIntervalSince1970 - 86_400)}
        """
        #expect(pick("[\(rows)]", near: target).id == "near")
        for key in ["transcripts", "data", "meetings"] {
            #expect(pick("{\"\(key)\":[\(rows)]}", near: target).id == "near",
                    "envelope '\(key)' was not unwrapped")
        }
    }

    @Test("JSON wrapped in the tool's prose is still parsed")
    func acceptsProseWrappedJSON() {
        // MCP tools often answer conversationally around the payload. Without
        // the bracket-slice fallback the whole listing is discarded.
        let list = """
        Here are the transcripts I found for you:
        [{"id":"near","title":"This call","date":\(target.timeIntervalSince1970 + 60)},
         {"id":"far","title":"Yesterday","date":\(target.timeIntervalSince1970 - 86_400)}]
        Let me know if you need more.
        """
        #expect(pick(list, near: target).id == "near")
    }

    // MARK: - Refusing to guess

    @Test("with a match window, an unparseable listing matches nothing")
    func windowRefusesUnparseableListings() {
        // Strictness is the point: "closest" is meaningless when no date could
        // be read, and guessing here overwrites a good transcript.
        let window = MCPConnectionManager.firefliesMatchWindow
        #expect(pick("not json at all", near: target, within: window).id == nil)
        #expect(pick("[]", near: target, within: window).id == nil)
        #expect(pick("""
        [{"id":"undated","title":"No date at all"}]
        """, near: target, within: window).id == nil)
    }

    @Test("with a match window and no session time, nothing matches")
    func windowRefusesWithoutATarget() {
        let list = """
        [{"id":"a","title":"Some call","date":\(target.timeIntervalSince1970)}]
        """
        #expect(pick(list, near: nil, within: MCPConnectionManager.firefliesMatchWindow).id == nil)
    }

    @Test("without a window, a listing still yields the newest meeting")
    func withoutAWindowItFallsBack() {
        // The lenient path — a manual import, where the user picked Fireflies
        // deliberately and some answer beats none.
        let list = """
        [{"id":"first","title":"Newest"},{"id":"second","title":"Older"}]
        """
        #expect(pick(list, near: nil).id == "first")
        #expect(pick(list, near: nil).title == "Newest")
    }

    @Test("without a window, a meeting more than 12h away loses to the newest")
    func distantMeetingsFallBackToNewest() {
        // Nearest-wins is only trustworthy near the session. A day out, the
        // listing order is the better signal than a bad distance.
        let list = """
        [{"id":"newest","title":"Newest","date":\(target.timeIntervalSince1970 + 40 * 3600)},
         {"id":"distant","title":"Distant","date":\(target.timeIntervalSince1970 + 13 * 3600)}]
        """
        #expect(pick(list, near: target).id == "newest")
    }

    @Test("a malformed listing never crashes and never invents an id")
    func malformedInputIsSafe() {
        for text in ["", "   ", "{}", "[]", "[[[", "{\"transcripts\":\"nope\"}", "null"] {
            let result = pick(text, near: target, within: MCPConnectionManager.firefliesMatchWindow)
            #expect(result.id == nil, "invented an id from: \(text)")
        }
    }
}
