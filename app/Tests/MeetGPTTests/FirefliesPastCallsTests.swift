import Foundation
import Testing
@testable import MeetGPT

/// Importing a past Fireflies call.
///
/// The parsing is the whole risk surface. Everything downstream — blind spots
/// quoting evidence, the assistant answering about who said what, export —
/// reads the transcript this produces, so a speaker dropped here is a wrong
/// attribution in every later answer, and a mangled timestamp reorders the
/// meeting.
@Suite("Fireflies past calls")
struct FirefliesPastCallsTests {

    // MARK: - The meeting list

    @Test("lists meetings newest first")
    func listsNewestFirst() {
        let payload = """
        [{"id":"a","title":"Older","date":1717200000000},
         {"id":"b","title":"Newer","date":1748736000000}]
        """
        let meetings = FirefliesPastCalls.parseMeetingList(payload)

        #expect(meetings.map(\.id) == ["b", "a"])
    }

    @Test("accepts the wrapped shapes the tool also returns")
    func acceptsWrappedShapes() {
        for key in ["transcripts", "data", "meetings"] {
            let payload = #"{"\#(key)":[{"id":"x","title":"Wrapped"}]}"#
            #expect(FirefliesPastCalls.parseMeetingList(payload).count == 1, "\(key)")
        }
    }

    @Test("finds the payload inside surrounding prose")
    func findsPayloadInProse() {
        let payload = """
        Here are your recent meetings:
        [{"id":"x","title":"Q3 pricing"}]
        Let me know if you need more.
        """
        #expect(FirefliesPastCalls.parseMeetingList(payload).first?.title == "Q3 pricing")
    }

    @Test("drops a meeting with no id, because it could never be opened")
    func dropsIdlessMeetings() {
        let payload = #"[{"title":"No id here"},{"id":"good","title":"Fine"}]"#
        let meetings = FirefliesPastCalls.parseMeetingList(payload)

        // Offering it would be a row that fails the moment it is tapped.
        #expect(meetings.map(\.id) == ["good"])
    }

    @Test("keeps an undated meeting, sorted last")
    func keepsUndatedMeetings() {
        let payload = """
        [{"id":"undated","title":"No date"},
         {"id":"dated","title":"Has one","date":1748736000000}]
        """
        #expect(FirefliesPastCalls.parseMeetingList(payload).map(\.id) == ["dated", "undated"])
    }

    @Test("reads participants from either a name list or objects")
    func readsParticipants() {
        let asStrings = #"[{"id":"a","participants":["Ada","Marek"]}]"#
        #expect(FirefliesPastCalls.parseMeetingList(asStrings).first?.participants == ["Ada", "Marek"])

        let asObjects = #"[{"id":"b","participants":[{"name":"Ada"},{"email":"marek@x.com"}]}]"#
        #expect(FirefliesPastCalls.parseMeetingList(asObjects).first?.participants
                == ["Ada", "marek@x.com"])
    }

    @Test("an untitled meeting still shows something a human can click")
    func untitledMeetingHasDisplayTitle() {
        let payload = #"[{"id":"a","title":"   "}]"#
        #expect(FirefliesPastCalls.parseMeetingList(payload).first?.displayTitle == "Untitled meeting")
    }

    @Test("junk is an empty list rather than a crash")
    func junkIsEmpty() {
        for payload in ["", "not json", "null", "42", "{}"] {
            #expect(FirefliesPastCalls.parseMeetingList(payload).isEmpty, "\(payload)")
        }
    }

    // MARK: - The transcript

    @Test("keeps who said each line")
    func keepsSpeakers() {
        let payload = """
        {"sentences":[
          {"speaker_name":"Ada","text":"We ship US-only on the twentieth.","start_time":0},
          {"speaker_name":"Marek","text":"Legal has not signed the DPA.","start_time":12.5}]}
        """
        let utterances = FirefliesPastCalls.parseUtterances(payload)

        // Attribution is the point: "Marek said the DPA is unsigned" is worth
        // far more than "someone said" it.
        #expect(utterances.map(\.speaker) == ["Ada", "Marek"])
        #expect(utterances[1].text == "Legal has not signed the DPA.")
    }

    @Test("accepts the alternate field names for speaker and text")
    func acceptsAlternateFieldNames() {
        let payload = """
        [{"speaker":"Ada","sentence":"First."},
         {"speakerName":"Marek","raw_text":"Second."}]
        """
        let utterances = FirefliesPastCalls.parseUtterances(payload)
        #expect(utterances.map(\.speaker) == ["Ada", "Marek"])
        #expect(utterances.map(\.text) == ["First.", "Second."])
    }

    @Test("treats a huge offset as milliseconds, not seconds")
    func normalisesMillisecondOffsets() {
        let payload = """
        {"sentences":[{"speaker_name":"Ada","text":"Late in the call","start_time":2400000}]}
        """
        let utterances = FirefliesPastCalls.parseUtterances(payload)

        // 2 400 000 is 40 minutes in milliseconds. Read as seconds it would put
        // one line 27 days after the meeting started and make every timestamp
        // in the session meaningless.
        #expect(utterances[0].offsetSeconds == 2400)
    }

    @Test("leaves a plausible second offset alone")
    func leavesSecondsAlone() {
        let payload = #"{"sentences":[{"text":"Early","start_time":95}]}"#
        #expect(FirefliesPastCalls.parseUtterances(payload)[0].offsetSeconds == 95)
    }

    @Test("a sentence with no offset holds its place instead of jumping to zero")
    func missingOffsetHoldsPosition() {
        let payload = """
        {"sentences":[
          {"text":"First","start_time":10},
          {"text":"Second"},
          {"text":"Third","start_time":30}]}
        """
        let utterances = FirefliesPastCalls.parseUtterances(payload)

        // Falling back to 0 would reorder the meeting: the middle line would
        // sort before the first.
        #expect(utterances.map(\.offsetSeconds) == [10, 10, 30])
    }

    @Test("skips empty sentences")
    func skipsEmptySentences() {
        let payload = #"{"sentences":[{"text":"  "},{"text":"Real line"},{"text":""}]}"#
        #expect(FirefliesPastCalls.parseUtterances(payload).map(\.text) == ["Real line"])
    }

    @Test("falls back to plain text when there are no structured sentences")
    func plainTextFallback() {
        let payload = """
        Ada: We ship US-only.
        Marek: Legal has not signed.
        """
        let utterances = FirefliesPastCalls.parseUtterances(payload)

        #expect(utterances.map(\.speaker) == ["Ada", "Marek"])
        #expect(utterances[0].text == "We ship US-only.")
    }

    @Test("does not mistake a colon inside a sentence for a speaker")
    func doesNotInventSpeakersFromColons() {
        let payload = "The plan is simple: ship US-only and wait for legal to sign."
        let utterances = FirefliesPastCalls.parseUtterances(payload)

        // Inventing "The plan is simple" as a person would put a fabricated
        // name on a real quote.
        #expect(utterances.count == 1)
        #expect(utterances[0].speaker == nil)
        #expect(utterances[0].text == payload)
    }

    @Test("recognises names but not sentence openings",
          arguments: [("Ada", true), ("Ada Lovelace", true), ("Speaker 1", true),
                      ("Dr. Ada", true),
                      ("The plan is simple", false), ("the plan", false),
                      ("So in summary", false), ("", false),
                      ("One two three four", false)])
    func speakerNameHeuristic(_ candidate: (String, Bool)) {
        #expect(FirefliesPastCalls.looksLikeSpeakerName(candidate.0) == candidate.1,
                "\(candidate.0)")
    }

    // MARK: - Becoming a session

    private func meeting(date: Date? = nil, duration: Double? = nil) -> FirefliesPastCalls.MeetingSummary {
        FirefliesPastCalls.MeetingSummary(
            id: "m1", title: "Q3 pricing — go/no-go", date: date,
            participants: ["Ada", "Marek"], durationSeconds: duration)
    }

    private let spoken: [FirefliesPastCalls.Utterance] = [
        .init(speaker: "Ada", text: "We ship US-only on the twentieth.", offsetSeconds: 0),
        .init(speaker: "Marek", text: "Legal has not signed the DPA.", offsetSeconds: 60),
    ]

    @Test("imports as a session History can open")
    func importsAsSession() {
        let happened = Date(timeIntervalSince1970: 1_748_736_000)
        let session = FirefliesPastCalls.session(for: meeting(date: happened), utterances: spoken)

        #expect(session.title == "Q3 pricing — go/no-go")
        #expect(session.entries.count == 2)
        // Sorted among real calls by when it HAPPENED, not when it was
        // imported — otherwise six months of meetings all stack at today.
        #expect(session.startedAt == happened)
        #expect(session.entries[1].timestamp == happened.addingTimeInterval(60))
    }

    @Test("carries no answer, because importing is not asking")
    func carriesNoAnswer() {
        let session = FirefliesPastCalls.session(for: meeting(), utterances: spoken)
        #expect(session.aiResponse.isEmpty)
    }

    @Test("attributes every line to the remote side")
    func attributesEveryLineRemote() {
        let session = FirefliesPastCalls.session(for: meeting(), utterances: spoken)

        // An imported call is somebody else's recording. Marking any line as
        // this machine's microphone would put words in the user's mouth every
        // time a later answer quotes it.
        #expect(session.entries.allSatisfy { $0.source == .system })
    }

    @Test("falls back to the import time when the meeting has no date")
    func fallsBackToImportTime() {
        let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let session = FirefliesPastCalls.session(for: meeting(date: nil), utterances: spoken,
                                                 importedAt: importedAt)
        #expect(session.startedAt == importedAt)
    }

    @Test("the digest names the speakers it found")
    func digestNamesSpeakers() {
        let session = FirefliesPastCalls.session(for: meeting(duration: 1800), utterances: spoken)

        #expect(session.digest.contains("Imported from Fireflies"))
        #expect(session.digest.contains("Ada"))
        #expect(session.digest.contains("2 lines"))
        #expect(session.digest.contains("30 min"))
    }

    @Test("the digest says plainly when the source had no speaker labels")
    func digestFlagsMissingSpeakers() {
        let unattributed = [FirefliesPastCalls.Utterance(speaker: nil, text: "Something", offsetSeconds: 0)]
        let session = FirefliesPastCalls.session(for: meeting(), utterances: unattributed)

        // Without labels every later quote reads "someone said", and the user
        // should be able to see why rather than assume the co-pilot is vague.
        #expect(session.digest.contains("no speaker labels"))
    }

    @Test("an imported session round-trips through the store")
    func roundTripsThroughStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fireflies-import-\(UUID().uuidString)")
        let store = SessionStore(root: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = FirefliesPastCalls.session(for: meeting(date: Date()), utterances: spoken)
        try store.save(session)

        // The whole design rests on this: it is an ordinary session, so History
        // lists it and every existing feature works on it unchanged.
        let reloaded = try #require(store.load(id: session.id))
        #expect(reloaded.title == session.title)
        #expect(reloaded.entries.map(\.text) == session.entries.map(\.text))
        #expect(reloaded.entries.map(\.speaker) == ["Ada", "Marek"])
        #expect(store.list().contains { $0.id == session.id })
    }
}

@Suite("Непонятый ответ Fireflies — не «звонков нет»")
struct FirefliesUnparsedIsNotEmptyTests {
    /// Пустой список и «не разобрали» показывались одинаково. При смене схемы
    /// у сервиса человек видел «прошлых звонков нет» и делал вывод, что
    /// импортировать нечего, — при том что звонки на месте.
    @Test("непонятый ответ отличается от пустого списка",
          arguments: ["<html>502 Bad Gateway</html>",
                      #"{"error":"invalid api key"}"#,
                      #"{"unexpected":{"shape":1}}"#,
                      "просто текст без json"])
    func unparsedYieldsNil(payload: String) {
        #expect(FirefliesPastCalls.parsedMeetingList(payload) == nil,
                "непонятый ответ выдан за разобранный: \(payload)")
    }

    @Test("настоящий пустой список остаётся пустым списком",
          arguments: ["[]", #"{"transcripts":[]}"#, #"{"data":[]}"#, #"{"meetings":[]}"#])
    func genuineEmptyStaysEmpty(payload: String) {
        let parsed = FirefliesPastCalls.parsedMeetingList(payload)
        #expect(parsed != nil, "разобранный пустой список принят за ошибку: \(payload)")
        #expect(parsed?.isEmpty == true)
    }

    /// Прежняя форма остаётся ровно для тех мест, где различать нечего.
    @Test("совместимая форма по-прежнему возвращает список")
    func compatibilityWrapperStillWorks() {
        #expect(FirefliesPastCalls.parseMeetingList(#"[{"id":"x","title":"Q3"}]"#).count == 1)
        #expect(FirefliesPastCalls.parseMeetingList("мусор").isEmpty)
    }
}
