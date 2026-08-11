import Foundation
import Testing
@testable import MeetGPT

/// Its own URLProtocol rather than the gateway suite's.
///
/// A URLProtocol stub keeps its captured request in static storage, so two
/// suites sharing one class read each other's traffic when the runner
/// interleaves them — `.serialized` only orders tests *within* a suite. That
/// showed up immediately as both suites failing on requests they never made.
private final class DriveStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(status: Int = 200, body: Data = Data("{}".utf8)) {
        self.status = status
        self.body = body
        lastRequest = nil
        lastBody = nil
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriveStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        // URLSession moves `httpBody` into a stream before the protocol sees it,
        // so reading only `httpBody` gets nil and every body assertion passes
        // vacuously against "".
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

/// Performing a confirmed proposal.
///
/// This is the far side of the confirmation boundary — by the time any of it
/// runs the user has said yes — so the tests are about doing exactly what was
/// agreed and nothing wider: one scope, one request, and a deletion that can be
/// walked back.
@Suite("Google drive writer", .serialized)
struct GoogleDriveWriterTests {

    private let table = GoogleFileExport.Table(
        header: ["Owner", "Task"], rows: [["Maria", "Contract"], ["Ana", "Backfill"]])

    @Test("creates the sheet and fills it in ONE request")
    func createsInOneRequest() async throws {
        // The two-step version (create, then append) has a failure this one
        // cannot: an empty file left behind in the user's Drive when the second
        // call fails.
        DriveStub.reset(body: Data(
            #"{"spreadsheetId":"abc","spreadsheetUrl":"https://x/abc"}"#.utf8))

        let file = try await GoogleDriveWriter.createSpreadsheet(
            title: "Owners", table: table, accessToken: "t", session: DriveStub.session())

        #expect(file.id == "abc")
        #expect(file.url == "https://x/abc")
        #expect(DriveStub.lastRequest?.httpMethod == "POST")
        let body = String(decoding: DriveStub.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("Owners"))
        #expect(body.contains("Maria"), "the rows ship with the create call")
        #expect(body.contains("Backfill"))
    }

    @Test("sends the bearer token")
    func sendsToken() async throws {
        DriveStub.reset(body: Data(#"{"spreadsheetId":"abc"}"#.utf8))
        _ = try await GoogleDriveWriter.createSpreadsheet(
            title: "t", table: table, accessToken: "secret-token", session: DriveStub.session())
        #expect(DriveStub.lastRequest?
            .value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test("falls back to a canonical url when Google omits one")
    func synthesisesURL() async throws {
        // Sheets has returned a bare id before. A nil url would strand the user
        // with a file they were told was created and cannot open.
        DriveStub.reset(body: Data(#"{"spreadsheetId":"abc"}"#.utf8))
        let file = try await GoogleDriveWriter.createSpreadsheet(
            title: "t", table: table, accessToken: "t", session: DriveStub.session())
        #expect(file.url.contains("abc"))
    }

    @Test("a response with no id is an error, not a half-success")
    func missingIDIsAnError() async {
        DriveStub.reset(body: Data(#"{"ok":true}"#.utf8))
        await #expect(throws: GoogleDriveWriter.WriteError.malformedResponse) {
            _ = try await GoogleDriveWriter.createSpreadsheet(
                title: "t", table: self.table, accessToken: "t", session: DriveStub.session())
        }
    }

    @Test("surfaces Google's own error message")
    func surfacesError() async {
        // A scope problem reads as "insufficient authentication scopes", which
        // is the difference between a bug report and a re-consent prompt.
        DriveStub.reset(
            status: 403,
            body: Data(#"{"error":{"message":"Request had insufficient authentication scopes."}}"#.utf8))
        await #expect(throws: GoogleDriveWriter.WriteError.http(
            403, "Request had insufficient authentication scopes.")) {
            _ = try await GoogleDriveWriter.createSpreadsheet(
                title: "t", table: self.table, accessToken: "t", session: DriveStub.session())
        }
    }

    // MARK: - Deletion

    @Test("deletion TRASHES rather than destroys")
    func deletionTrashes() async throws {
        // The user confirmed "remove this", not "destroy this irrecoverably".
        // Trashing keeps the thirty-day undo Drive already gives them.
        DriveStub.reset()
        try await GoogleDriveWriter.trashFile(
            fileID: "abc", createdByUs: true, accessToken: "t", session: DriveStub.session())

        #expect(DriveStub.lastRequest?.httpMethod == "PATCH")
        #expect(DriveStub.lastRequest?.httpMethod != "DELETE")
        let body = String(decoding: DriveStub.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("trashed"))
        #expect(DriveStub.lastRequest?.url?.absoluteString
            .contains("drive/v3/files/abc") == true)
    }

    @Test("refuses to touch a file we did not create, without calling Google")
    func refusesForeignFile() async {
        DriveStub.reset()
        await #expect(throws: GoogleDriveWriter.WriteError.notOurFile) {
            try await GoogleDriveWriter.trashFile(
                fileID: "abc", createdByUs: false, accessToken: "t", session: DriveStub.session())
        }
        #expect(DriveStub.lastRequest == nil, "the guard runs before the network")
    }

    @Test("an empty file id never reaches Google")
    func refusesEmptyID() async {
        // Otherwise the url becomes .../files/ and PATCHes the file *list*.
        DriveStub.reset()
        await #expect(throws: GoogleDriveWriter.WriteError.notOurFile) {
            try await GoogleDriveWriter.trashFile(
                fileID: "", createdByUs: true, accessToken: "t", session: DriveStub.session())
        }
        #expect(DriveStub.lastRequest == nil)
    }

    @Test("a failed trash is reported, not swallowed")
    func trashFailureThrows() async {
        DriveStub.reset(status: 404, body: Data(#"{"error":{"message":"File not found: abc."}}"#.utf8))
        await #expect(throws: GoogleDriveWriter.WriteError.http(404, "File not found: abc.")) {
            try await GoogleDriveWriter.trashFile(
                fileID: "abc", createdByUs: true, accessToken: "t", session: DriveStub.session())
        }
    }

    // MARK: - Scope

    @Test("the only scope needed is drive.file")
    func scopeIsNarrow() {
        // The whole point of the design. Creating a spreadsheet does not require
        // reach into the user's existing ones, and this pins that nobody widened
        // it later to make some edge case easier.
        #expect(GoogleDriveWriter.scope == "https://www.googleapis.com/auth/drive.file")
        #expect(!GoogleDriveWriter.scope.contains("spreadsheets"))
        #expect(!GoogleDriveWriter.scope.contains("drive.readonly"))
    }
}

/// The offer, as the answer menu sees it.
///
/// The parsing and the HTTP are covered above; what these pin is *when* the
/// offer appears. An export chip that shows up under every answer is noise, and
/// noise is how a genuinely useful offer gets dismissed unread.
@MainActor
@Suite("Spreadsheet export offer", .serialized)
struct SpreadsheetExportOfferTests {

    // The grant lives in UserDefaults, so these have to be set and put back —
    // serialized as well, since a leaked grant would silently change what a
    // later suite sees.
    private let previousServices = Config.googleGrantedServices
    private let previousVersion = Config.googleScopeVersion

    private func state(answer: String, google: Bool = true,
                       granted: Bool = true, current: Bool = true) -> AppState {
        Config.googleGrantedServices = granted ? [GoogleService.sheets.rawValue] : []
        Config.googleScopeVersion = current ? GoogleAuth.scopeVersion : 1
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.aiResponse = answer
        state.aiStreaming = false
        state.googleConnected = google
        return state
    }

    private func restore() {
        Config.googleGrantedServices = previousServices
        Config.googleScopeVersion = previousVersion
    }

    private let tabular = """
    Split by owner.

    | Owner | Task |
    | --- | --- |
    | Maria | Contract |
    | Ana | Backfill |
    """

    @Test("an answer with a table offers a spreadsheet")
    func offersForTables() {
        defer { restore() }
        let proposals = state(answer: tabular).answerSpreadsheetProposals
        #expect(proposals.count == 1)
        #expect(proposals.first?.summary.contains("2 rows") == true)
    }

    @Test("an ordinary answer offers nothing")
    func silentOtherwise() {
        defer { restore() }
        #expect(state(answer: "Maria sends the contract Friday.")
            .answerSpreadsheetProposals.isEmpty)
    }

    @Test("nothing is offered without Google connected")
    func requiresGoogle() {
        defer { restore() }
        // Otherwise the chip is a dead end that ends in a "connect Google"
        // error after the user already committed to the action.
        #expect(state(answer: tabular, google: false).answerSpreadsheetProposals.isEmpty)
    }

    @Test("nothing is offered while the answer is still streaming")
    func requiresFinishedAnswer() {
        defer { restore() }
        // A half-written table would export as a half-written table.
        let state = state(answer: tabular)
        state.aiStreaming = true
        #expect(state.answerSpreadsheetProposals.isEmpty)
    }

    @Test("an error is never offered as a spreadsheet")
    func refusesErrors() {
        defer { restore() }
        #expect(state(answer: "Error: provider unavailable\n\n" + tabular)
            .answerSpreadsheetProposals.isEmpty)
    }

    @Test("undo is offered only after something was created")
    func undoAppearsOnlyAfterCreation() {
        defer { restore() }
        #expect(state(answer: tabular).lastCreatedSpreadsheetTitle == nil)
    }

    @Test("undo with nothing to undo does nothing and reports no error")
    func undoIsANoOpWhenEmpty() async {
        defer { restore() }
        // It is reachable from a stale menu. Turning that into an error message
        // would be alarming for an action that did not happen.
        let state = state(answer: tabular)
        await state.undoLastSpreadsheetExport()
        #expect(state.lastError == nil)
    }

    @Test("a non-create proposal is refused rather than approximated")
    func refusesForeignProposal() async {
        defer { restore() }
        // The confirmation the user gave was for a deletion; performing "the
        // nearest thing this executor can do" instead is the exact failure the
        // boundary exists to prevent.
        let state = state(answer: tabular)
        await state.exportAnswerTableToGoogleSheets(
            .deleteFile(fileID: "abc", title: "t", reason: "stale"))
        #expect(state.lastError != nil)
        #expect(state.lastCreatedSpreadsheet == nil)
    }

    @Test("nothing is offered when the grant excluded Sheets")
    func requiresSheetsService() {
        defer { restore() }
        // Granular authorization: the user can connect Google and untick Sheets.
        #expect(state(answer: tabular, granted: false).answerSpreadsheetProposals.isEmpty)
    }

    @Test("nothing is offered on a grant that predates the write scope")
    func requiresCurrentScopeVersion() {
        defer { restore() }
        // drive.file was only added to the Sheets bundle in v6. A v5 Sheets
        // grant can read spreadsheets and create none, so the offer would take
        // the click and come back with a 403.
        #expect(state(answer: tabular, current: false).answerSpreadsheetProposals.isEmpty)
    }
}
