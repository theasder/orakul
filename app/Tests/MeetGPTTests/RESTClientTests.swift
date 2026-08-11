import Foundation
import Testing
@testable import MeetGPT

/// Routes URLSession requests by URL so the multi-request REST clients (Sheets:
/// title+values; AssemblyAI: upload→create→poll) can be driven from one
/// responder. Own static state + a serialized suite keep it race-free.
final class RESTMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _lastBody: Data?

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return _lastBody }
    static func reset() {
        lock.lock(); _requests = []; _lastBody = nil; responder = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        RESTMockURLProtocol.lock.lock()
        RESTMockURLProtocol._requests.append(request)
        RESTMockURLProtocol._lastBody = body
        RESTMockURLProtocol.lock.unlock()
        guard let responder = RESTMockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RESTMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

@Suite("REST clients", .serialized)
struct RESTClientTests {
    private func withResponder(_ responder: @escaping (URLRequest) -> (Int, Data),
                               _ run: () async throws -> Void) async rethrows {
        RESTMockURLProtocol.reset()
        RESTMockURLProtocol.responder = responder
        defer { RESTMockURLProtocol.reset() }
        try await run()
    }

    // MARK: Google Docs

    @Test("Docs: extracts the title and concatenated paragraph text")
    func docsSuccess() async throws {
        let doc: [String: Any] = [
            "title": "Roadmap Q3",
            "body": ["content": [
                ["paragraph": ["elements": [["textRun": ["content": "Line one.\n"]]]]],
                ["paragraph": ["elements": [["textRun": ["content": "Line two."]]]]]
            ]]
        ]
        try await withResponder({ _ in (200, json(doc)) }) {
            let out = try await GoogleDocsService.read(documentID: "abc", accessToken: "t",
                                                       session: RESTMockURLProtocol.session())
            #expect(out.title == "Roadmap Q3")
            #expect(out.text == "Line one.\nLine two.")
        }
    }

    @Test("Docs: a non-2xx response throws")
    func docsError() async throws {
        try await withResponder({ _ in (403, Data(#"{"error":"forbidden"}"#.utf8)) }) {
            await #expect(throws: (any Error).self) {
                _ = try await GoogleDocsService.read(documentID: "abc", accessToken: "t",
                                                     session: RESTMockURLProtocol.session())
            }
        }
    }

    @Test("Docs export: creates one bounded Drive file with authenticated multipart HTML")
    func docsExportCreatesBoundedFile() async throws {
        try await withResponder({ _ in
            (200, json(["id": "doc-created", "webViewLink":
                "https://docs.google.com/document/d/doc-created/edit"]))
        }) {
            let created = try await GoogleDocsWriter.create(
                title: "Falcon review", html: "<h1>Decision</h1><p>Ship Friday.</p>",
                accessToken: "write-token", session: RESTMockURLProtocol.session())

            #expect(created.id == "doc-created")
            #expect(created.webViewLink.hasSuffix("/doc-created/edit"))
            let request = try #require(RESTMockURLProtocol.requests.last)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.host == "www.googleapis.com")
            #expect(request.url?.path == "/upload/drive/v3/files")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer write-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/related") == true)
            let body = (String(data: RESTMockURLProtocol.lastBody ?? Data(), encoding: .utf8) ?? "")
                .replacingOccurrences(of: "\\/", with: "/")
            #expect(body.contains("Falcon review"))
            #expect(body.contains("application/vnd.google-apps.document"))
            #expect(body.contains("<h1>Decision</h1><p>Ship Friday.</p>"))
        }
    }

    @Test("Docs export: missing web link falls back to the created document id")
    func docsExportFallbackLink() async throws {
        try await withResponder({ _ in (200, json(["id": "fallback-id"])) }) {
            let created = try await GoogleDocsWriter.create(
                title: "Minutes", html: "<p>Done</p>", accessToken: "token",
                session: RESTMockURLProtocol.session())
            #expect(created.webViewLink
                == "https://docs.google.com/document/d/fallback-id/edit")
        }
    }

    @Test("Docs export: provider errors and malformed success bodies never look created")
    func docsExportFailures() async throws {
        try await withResponder({ _ in (403, Data(#"{"error":"scope"}"#.utf8)) }) {
            await #expect(throws: (any Error).self) {
                _ = try await GoogleDocsWriter.create(
                    title: "Nope", html: "<p>Nope</p>", accessToken: "token",
                    session: RESTMockURLProtocol.session())
            }
        }
        try await withResponder({ _ in (200, json(["webViewLink": "https://example.com"])) }) {
            await #expect(throws: (any Error).self) {
                _ = try await GoogleDocsWriter.create(
                    title: "No id", html: "<p>No id</p>", accessToken: "token",
                    session: RESTMockURLProtocol.session())
            }
        }
    }

    // MARK: Google Sheets

    @Test("Sheets: merges the title request and the values grid (tab-joined)")
    func sheetsSuccess() async throws {
        try await withResponder({ req in
            let path = req.url?.path ?? ""
            if path.contains("/values/") {
                return (200, json(["values": [["A", "B"], ["c", "d"]]]))
            }
            return (200, json(["properties": ["title": "Budget"]]))
        }) {
            let out = try await GoogleSheetsService.read(spreadsheetID: "sid", accessToken: "t",
                                                         session: RESTMockURLProtocol.session())
            #expect(out.title == "Budget")
            #expect(out.text == "A\tB\nc\td")
        }
    }

    @Test("Sheets: an error on either request propagates")
    func sheetsError() async throws {
        try await withResponder({ req in
            let path = req.url?.path ?? ""
            if path.contains("/values/") { return (401, Data("nope".utf8)) }
            return (200, json(["properties": ["title": "Budget"]]))
        }) {
            await #expect(throws: (any Error).self) {
                _ = try await GoogleSheetsService.read(spreadsheetID: "sid", accessToken: "t",
                                                       session: RESTMockURLProtocol.session())
            }
        }
    }

    // MARK: Google Workspace workflow search

    @Test("Workspace search is inert while its scope is withdrawn")
    func workspaceSearchIsWithdrawn() async throws {
        // This used to prove the whole path: Drive files.list finds a Doc by
        // name, then the Docs API reads it. Finding by name needs
        // `drive.metadata.readonly`, which Google classes as RESTRICTED — it was
        // dropped so the consent screen needs no CASA assessment, and the search
        // went with it.
        //
        // What matters now is that it stays SILENT rather than failing. A live
        // call is the worst place to surface a 403 the user cannot act on, so
        // the assertion is that no request is made at all.
        try await withResponder({ _ in
            Issue.record("search must not reach Google while its scope is withdrawn")
            return (200, json([:]))
        }) {
            let documents = try await GoogleWorkspaceSearchService.search(
                query: "beta launch milestones",
                services: [.docs],
                accessToken: "token",
                session: RESTMockURLProtocol.session())

            #expect(documents.isEmpty)
            #expect(RESTMockURLProtocol.requests.isEmpty)
        }
        // Restoring it means either a Google Picker flow on `drive.file`, or
        // putting the scope back with CASA attached — at which point
        // `isAvailable` flips and the deleted assertions belong here again.
        #expect(!GoogleWorkspaceSearchService.isAvailable)
    }

    // MARK: Calendar

    @Test("Calendar: folds the nearest event into an agenda summary")
    func agendaSuccess() async throws {
        let events: [String: Any] = ["items": [[
            "summary": "Design sync",
            "description": "Review the new flow",
            "attendees": [["email": "a@x.com"], ["email": "b@x.com"]]
        ]]]
        try await withResponder({ _ in (200, json(events)) }) {
            let agenda = try await CalendarService.currentAgenda(accessToken: "t",
                                                                 session: RESTMockURLProtocol.session())
            #expect(agenda.title == "Design sync")
            #expect(agenda.summary.contains("Review the new flow"))
            #expect(agenda.summary.contains("a@x.com, b@x.com"))
            #expect(agenda.attendeeCount == 2)   // diarization hint source
            let request = try #require(RESTMockURLProtocol.requests.last)
            let timeMin = URLComponents(
                url: try #require(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "timeMin" })?.value
            let lowerBound = try #require(timeMin.flatMap { ISO8601DateFormatter().date(from: $0) })
            #expect(abs(lowerBound.timeIntervalSinceNow) < 10)
        }
    }

    @Test("Calendar: no events throws noEvent; a non-2xx throws http")
    func agendaFailures() async throws {
        try await withResponder({ _ in (200, json(["items": []])) }) {
            await #expect(throws: CalendarError.self) {
                _ = try await CalendarService.currentAgenda(accessToken: "t", session: RESTMockURLProtocol.session())
            }
        }
        try await withResponder({ _ in (500, Data("boom".utf8)) }) {
            await #expect(throws: CalendarError.self) {
                _ = try await CalendarService.currentAgenda(accessToken: "t", session: RESTMockURLProtocol.session())
            }
        }
    }

    @Test("Calendar: upcomingEvents keeps future timed events, skips all-day and past")
    func upcoming() async throws {
        let fmt = ISO8601DateFormatter()
        let future = fmt.string(from: Date().addingTimeInterval(3600))
        let past = fmt.string(from: Date().addingTimeInterval(-3600))
        let events: [String: Any] = ["items": [
            ["id": "1", "summary": "Soon", "start": ["dateTime": future]],
            ["id": "2", "summary": "All day", "start": ["date": "2030-01-01"]],   // no dateTime -> skipped
            ["id": "3", "summary": "Already happened", "start": ["dateTime": past]]
        ]]
        try await withResponder({ _ in (200, json(events)) }) {
            let meetings = try await CalendarService.upcomingEvents(accessToken: "t",
                                                                    session: RESTMockURLProtocol.session())
            #expect(meetings.count == 1)
            #expect(meetings.first?.id == "1")
            #expect(meetings.first?.title == "Soon")
        }
    }

    // MARK: AssemblyAI

    @Test("AssemblyAI: upload → create → poll returns diarized utterances")
    func diarizeSuccess() async throws {
        try await withResponder({ req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/upload") {
                return (200, json(["upload_url": "https://cdn.assemblyai.com/x.wav"]))
            }
            if path.hasSuffix("/transcript") {
                return (200, json(["id": "tid-1"]))
            }
            // GET /transcript/{id} — completed on the first poll (no sleep).
            return (200, json([
                "status": "completed",
                "utterances": [
                    ["speaker": "A", "text": "Hello.", "start": 0],
                    ["speaker": "B", "text": "Hi there.", "start": 1500],
                    ["speaker": "A", "text": "", "start": 3000]   // empty text -> dropped
                ]
            ]))
        }) {
            let out = try await AssemblyAIService.diarize(wav: Data([1, 2, 3]), apiKey: "k",
                                                          session: RESTMockURLProtocol.session())
            #expect(out.count == 2)
            #expect(out[0].speaker == "A")
            #expect(out[0].text == "Hello.")
            #expect(out[0].startMs == 0)
            #expect(out[1].startMs == 1500)
        }
    }

    @Test("AssemblyAI: a missing key throws before any request")
    func diarizeMissingKey() async {
        await #expect(throws: (any Error).self) {
            _ = try await AssemblyAIService.diarize(wav: Data([1]), apiKey: "  ",
                                                    session: RESTMockURLProtocol.session())
        }
    }

    @Test("AssemblyAI: a terminal error status throws")
    func diarizeErrorStatus() async throws {
        try await withResponder({ req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/upload") { return (200, json(["upload_url": "https://x"])) }
            if path.hasSuffix("/transcript") { return (200, json(["id": "tid"])) }
            return (200, json(["status": "error", "error": "audio too short"]))
        }) {
            await #expect(throws: (any Error).self) {
                _ = try await AssemblyAIService.diarize(wav: Data([1]), apiKey: "k",
                                                        session: RESTMockURLProtocol.session())
            }
        }
    }
}
