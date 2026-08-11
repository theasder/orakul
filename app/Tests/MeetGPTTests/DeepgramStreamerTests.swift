import Foundation
import Testing
@testable import MeetGPT

/// Deepgram's live-transcription logic, extracted from the WebSocket transport
/// so the load-bearing parts are testable without a socket: the Results message
/// parser (interim/final + diarization crosstalk splitting), the byte-capped
/// FIFO replay buffer, URL building, PCM16 serialization, and reconnect backoff.
@Suite("Deepgram streamer")
struct DeepgramStreamerTests {
    // Build a Deepgram `Results` frame.
    private func results(_ transcript: String, isFinal: Bool,
                         words: [[String: Any]]? = nil,
                         confidence: Double? = nil) -> String {
        var alt: [String: Any] = ["transcript": transcript]
        if let words { alt["words"] = words }
        if let confidence { alt["confidence"] = confidence }
        let obj: [String: Any] = [
            "type": "Results",
            "is_final": isFinal,
            "channel": ["alternatives": [alt]]
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func word(_ text: String, speaker: Int?, punctuated: String? = nil) -> [String: Any] {
        var w: [String: Any] = ["word": text]
        if let speaker { w["speaker"] = speaker }
        if let punctuated { w["punctuated_word"] = punctuated }
        return w
    }

    // MARK: parseMessage

    @Test("an interim result surfaces provisionally, no clear")
    func interim() {
        let events = DeepgramStreamer.parseMessage(results("hello wor", isFinal: false), diarize: false)
        #expect(events == [.interim("hello wor")])
    }

    @Test("a non-diarized final emits the utterance then clears the interim")
    func finalPlain() {
        let events = DeepgramStreamer.parseMessage(results("hello world", isFinal: true), diarize: false)
        #expect(events == [.result(text: "hello world", speaker: nil), .clearInterim])
    }

    @Test("an empty transcript yields no events")
    func emptyTranscript() {
        #expect(DeepgramStreamer.parseMessage(results("", isFinal: true), diarize: false).isEmpty)
        #expect(DeepgramStreamer.parseMessage(results("", isFinal: false), diarize: false).isEmpty)
    }

    @Test("non-Results, malformed, and non-JSON messages yield no events")
    func ignoredMessages() {
        let metadata = #"{"type":"Metadata","duration":1.0}"#
        #expect(DeepgramStreamer.parseMessage(metadata, diarize: true).isEmpty)
        #expect(DeepgramStreamer.parseMessage("not json at all", diarize: true).isEmpty)
        #expect(DeepgramStreamer.parseMessage("{}", diarize: true).isEmpty)
    }

    @Test("diarized final attributes a single-speaker utterance to that speaker")
    func diarizedSingleSpeaker() {
        let msg = results("Hello there.", isFinal: true, words: [
            word("Hello", speaker: 0, punctuated: "Hello"),
            word("there", speaker: 0, punctuated: "there.")
        ])
        let events = DeepgramStreamer.parseMessage(msg, diarize: true)
        #expect(events == [.result(text: "Hello there.", speaker: 0), .clearInterim])
    }

    @Test("diarized final splits crosstalk into per-speaker runs, preferring punctuated tokens")
    func diarizedCrosstalk() {
        let msg = results("ignored", isFinal: true, words: [
            word("Yes", speaker: 0, punctuated: "Yes,"),
            word("exactly", speaker: 0, punctuated: "exactly."),
            word("But", speaker: 1, punctuated: "But"),
            word("wait", speaker: 1, punctuated: "wait?")
        ])
        let events = DeepgramStreamer.parseMessage(msg, diarize: true)
        #expect(events == [
            .result(text: "Yes, exactly.", speaker: 0),
            .result(text: "But wait?", speaker: 1),
            .clearInterim
        ])
    }

    @Test("diarize on but no word data falls back to the whole utterance")
    func diarizeNoWords() {
        let events = DeepgramStreamer.parseMessage(results("whole thing", isFinal: true), diarize: true)
        #expect(events == [.result(text: "whole thing", speaker: nil), .clearInterim])
    }

    @Test("empty-token words are skipped; the surviving tokens form the run")
    func blankTokens() {
        let msg = results("x", isFinal: true, words: [
            word("", speaker: 0),                          // empty word -> skipped
            word("kept", speaker: 0, punctuated: "kept.")  // survives
        ])
        #expect(DeepgramStreamer.parseMessage(msg, diarize: true)
                == [.result(text: "kept.", speaker: 0), .clearInterim])
    }

    @Test("an all-empty word list still clears the interim, with no result")
    func allBlankWords() {
        let msg = results("y", isFinal: true, words: [word("", speaker: 0)])
        #expect(DeepgramStreamer.parseMessage(msg, diarize: true) == [.clearInterim])
    }

    // Reported from a real call: "recognition of speaker was very poor …
    // duplicating speaker name all the time". Diarization flips speaker for a
    // single word mid-utterance; every flip became its own transcript entry
    // with its own gutter line, so one sentence rendered as five labels.

    @Test("a one-word speaker island inside an utterance is diarization noise, not crosstalk")
    func mergesSingleWordSpeakerIsland() {
        let msg = results("ignored", isFinal: true, words: [
            word("the", speaker: 0, punctuated: "The"),
            word("pricing", speaker: 0, punctuated: "pricing"),
            word("page", speaker: 1, punctuated: "page"),   // island — same voice
            word("ships", speaker: 0, punctuated: "ships"),
            word("friday", speaker: 0, punctuated: "Friday.")
        ])
        #expect(DeepgramStreamer.parseMessage(msg, diarize: true) == [
            .result(text: "The pricing page ships Friday.", speaker: 0),
            .clearInterim
        ])
    }

    @Test("a genuine interjection — an island at the utterance edge — is kept")
    func keepsEdgeIsland() {
        let msg = results("ignored", isFinal: true, words: [
            word("agreed", speaker: 1, punctuated: "Agreed."),
            word("so", speaker: 0, punctuated: "So"),
            word("we", speaker: 0, punctuated: "we"),
            word("ship", speaker: 0, punctuated: "ship.")
        ])
        // No same-speaker run on BOTH sides — this is a real speaker change.
        #expect(DeepgramStreamer.parseMessage(msg, diarize: true) == [
            .result(text: "Agreed.", speaker: 1),
            .result(text: "So we ship.", speaker: 0),
            .clearInterim
        ])
    }

    // Reported: "issue with duplicating recognition of speech … show version
    // you confident enough?" — a final the model itself scores as a guess
    // should not be committed to the transcript.

    @Test("a low-confidence final is dropped, clearing its interim")
    func dropsLowConfidenceFinal() {
        let msg = results("thrash noise misheard", isFinal: true, confidence: 0.2)
        #expect(DeepgramStreamer.parseMessage(msg, diarize: false) == [.clearInterim])
    }

    @Test("a confident final commits; one without a confidence field commits too")
    func keepsConfidentFinals() {
        #expect(DeepgramStreamer.parseMessage(
            results("clear speech", isFinal: true, confidence: 0.9), diarize: false)
            == [.result(text: "clear speech", speaker: nil), .clearInterim])
        // Absent confidence must not start dropping speech.
        #expect(DeepgramStreamer.parseMessage(
            results("clear speech", isFinal: true), diarize: false)
            == [.result(text: "clear speech", speaker: nil), .clearInterim])
    }

    // MARK: ReplayBuffer

    @Test("replay buffer is FIFO: append to back, pop from front")
    func bufferFIFO() {
        var buf = ReplayBuffer(byteCap: 1_000)
        buf.append([1, 2])
        buf.append([3, 4])
        #expect(buf.popFront() == [1, 2])
        #expect(buf.popFront() == [3, 4])
        #expect(buf.popFront() == nil)
        #expect(buf.isEmpty)
    }

    @Test("a requeued frame goes back to the front, in order")
    func bufferRequeue() {
        var buf = ReplayBuffer(byteCap: 1_000)
        buf.append([9])
        let failed = buf.popFront()!
        buf.append([10])            // a newer frame arrived while the send was failing
        buf.requeueFront(failed)    // failed frame must come out first again
        #expect(buf.popFront() == [9])
        #expect(buf.popFront() == [10])
    }

    @Test("appends past the byte cap drop the oldest frames")
    func bufferTrim() {
        // cap = 8 bytes = 4 Int16 samples.
        var buf = ReplayBuffer(byteCap: 8)
        buf.append([1, 2])   // 4 bytes
        buf.append([3, 4])   // 8 bytes total — at cap
        buf.append([5, 6])   // 12 bytes -> drop oldest [1,2] back to 8
        #expect(buf.byteCount == 8)
        #expect(buf.popFront() == [3, 4])
        #expect(buf.popFront() == [5, 6])
    }

    @Test("a single frame larger than the cap is dropped entirely")
    func bufferOversizeFrame() {
        var buf = ReplayBuffer(byteCap: 4)
        buf.append([1, 2, 3])   // 6 bytes > 4 -> trimmed away
        #expect(buf.isEmpty)
        #expect(buf.byteCount == 0)
    }

    // MARK: buildURL

    @Test("buildURL sets the nova-3 streaming params and language")
    func urlParams() throws {
        let url = try #require(DeepgramStreamer.buildURL(language: "ru", diarize: false))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(url.scheme == "wss")
        #expect(url.host == "api.deepgram.com")
        #expect(dict["model"] == "nova-3")
        #expect(dict["language"] == "ru")
        #expect(dict["encoding"] == "linear16")
        #expect(dict["sample_rate"] == "16000")
        #expect(dict["interim_results"] == "true")
        #expect(dict["diarize_model"] == nil)   // off unless requested
        #expect(dict["diarize"] == nil)         // deprecated alias is never sent
    }

    @Test("buildURL selects the latest streaming diarizer only when enabled")
    func urlDiarize() throws {
        let url = try #require(DeepgramStreamer.buildURL(language: "multi", diarize: true))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(where: { $0.name == "diarize_model" && $0.value == "latest" }))
        #expect(!items.contains(where: { $0.name == "diarize" }))
    }

    @Test("Auto keeps Deepgram multilingual code switching enabled")
    func urlAutoLanguage() throws {
        let url = try #require(DeepgramStreamer.buildURL(language: "multi", diarize: false))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(where: { $0.name == "language" && $0.value == "multi" }))
        #expect(items.contains(where: { $0.name == "endpointing" && $0.value == "100" }))
    }

    // MARK: PCM16 + backoff

    @Test("pcm16LE serializes Int16 samples as little-endian bytes")
    func pcm16() {
        let data = DeepgramStreamer.pcm16LE([1, 258])   // 0x0001, 0x0102
        #expect(Array(data) == [0x01, 0x00, 0x02, 0x01])   // little-endian
    }

    @Test("backoff grows exponentially, is capped, and jitter stays within +30%")
    func backoff() {
        #expect(DeepgramStreamer.backoffBase(0) == 0.5)   // 0.5 * 2^0
        #expect(DeepgramStreamer.backoffBase(1) == 1.0)
        #expect(DeepgramStreamer.backoffBase(3) == 4.0)
        #expect(DeepgramStreamer.backoffBase(20) == 15.0) // capped at maxReconnectDelay
        for attempt in 0...8 {
            let base = DeepgramStreamer.backoffBase(attempt)
            let delay = DeepgramStreamer.backoffDelay(attempt)
            #expect(delay >= base)
            #expect(delay <= base * 1.3 + 0.0001)
        }
    }

    // MARK: Credit economy (grant auth + usage metering)

    @Test("permanent keys use the Token scheme; grant tokens use Bearer")
    func authHeaders() {
        #expect(DeepgramAuth.header(key: "dg_secret") == "Token dg_secret")
        #expect(DeepgramAuth.header(grantToken: "tmp") == "Bearer tmp")
        #expect(DeepgramAuth.key("k").isMetered == false)        // BYO bills the operator
        #expect(DeepgramAuth.grant({ "t" }).isMetered == true)   // grants bill credits
    }

    @Test("heartbeats floor to whole 6-second chunks and carry the remainder")
    func meteringMath() {
        let chunk = 16_000 * 6   // samples per metering chunk
        #expect(DeepgramStreamer.chunksToReport(sentSamples: 0, reportedSamples: 0) == 0)
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk - 1, reportedSamples: 0) == 0)
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk, reportedSamples: 0) == 1)
        // Remainder carries: report 1, keep half a chunk pending for next beat.
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk * 3 / 2, reportedSamples: 0) == 1)
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk * 3, reportedSamples: chunk) == 2)
        // A stale reading can never produce a negative report.
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk, reportedSamples: chunk * 2) == 0)
    }

    @Test("the finish-time flush ceils so a trailing partial chunk is still billed")
    func meteringFinalFlush() {
        let chunk = 16_000 * 6
        #expect(DeepgramStreamer.chunksToReport(sentSamples: 0, reportedSamples: 0, final: true) == 0)
        #expect(DeepgramStreamer.chunksToReport(sentSamples: 1, reportedSamples: 0, final: true) == 1)
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk, reportedSamples: 0, final: true) == 1)
        #expect(DeepgramStreamer.chunksToReport(sentSamples: chunk + 1, reportedSamples: chunk, final: true) == 1)
    }

    @Test("grant responses classify by whether a retry can help mid-session")
    func grantClassification() {
        // Success → no error.
        #expect(DeepgramBackend.classifyGrant(status: 200, message: nil) == nil)
        // Terminal: cap (with the server's message), unconfigured, signed out.
        #expect(DeepgramBackend.classifyGrant(status: 429, message: "Credits used up.")
            == .creditCap("Credits used up."))
        #expect(DeepgramBackend.classifyGrant(status: 402, message: nil)?.isTerminal == true)
        #expect(DeepgramBackend.classifyGrant(status: 503, message: nil)
            == .notConfigured("Deepgram live streaming is not available on this server."))
        #expect(DeepgramBackend.classifyGrant(status: 401, message: nil) == .signInRequired)
        #expect(DeepgramBackend.classifyGrant(status: 403, message: nil) == .signInRequired)
        // Transient: server hiccups reuse the reconnect backoff.
        #expect(DeepgramBackend.classifyGrant(status: 500, message: nil) == .transient(500))
        #expect(DeepgramBackend.classifyGrant(status: 502, message: nil)?.isTerminal == false)
    }

    @Test("every grant failure carries a user-facing fallback message")
    func fallbackMessages() {
        #expect(DeepgramGrantError.creditCap("Out of credits.").fallbackMessage == "Out of credits.")
        #expect(DeepgramGrantError.signInRequired.fallbackMessage.contains("Войти"))
        #expect(DeepgramGrantError.transient(500).fallbackMessage.contains("500"))
    }
}
