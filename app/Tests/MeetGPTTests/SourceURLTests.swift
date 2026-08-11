import Testing
import Foundation
@testable import MeetGPT

/// URL/ID extraction for the connector services. `SourceURL` accepts either a
/// pasted Google URL or a bare document ID and pulls out the canonical ID, or
/// returns nil when the input is junk. Pin the pure regex + bare-ID logic.
@Suite("Source URL parsing")
struct SourceURLTests {
    // MARK: Google Docs

    @Test("extracts the id from a full /document/d/<id>/edit URL")
    func docFullURL() {
        #expect(SourceURL.googleDocID(from: "https://docs.google.com/document/d/1AbC_dEf-123/edit") == "1AbC_dEf-123")
    }

    @Test("extracts the doc id past trailing query params")
    func docTrailingParams() {
        #expect(SourceURL.googleDocID(from: "https://docs.google.com/document/d/1AbC_dEf-123/edit?usp=sharing&foo=bar") == "1AbC_dEf-123")
    }

    @Test("accepts a bare doc id unchanged")
    func docBareID() {
        #expect(SourceURL.googleDocID(from: "1AbC_dEf-123") == "1AbC_dEf-123")
    }

    @Test("returns nil for a doc URL with a missing id")
    func docMissingID() {
        #expect(SourceURL.googleDocID(from: "https://docs.google.com/document/d//edit") == nil)
    }

    @Test("returns nil for junk doc input")
    func docJunk() {
        #expect(SourceURL.googleDocID(from: "not a valid id!!!") == nil)
        #expect(SourceURL.googleDocID(from: "") == nil)
        #expect(SourceURL.googleDocID(from: "   ") == nil)
    }

    @Test("returns nil when a sheets URL is handed to the doc parser (wrong host/path)")
    func docWrongPath() {
        #expect(SourceURL.googleDocID(from: "https://docs.google.com/spreadsheets/d/1SheetXYZ/edit") == nil)
    }

    // MARK: Google Sheets

    @Test("extracts the id from a full /spreadsheets/d/<id>/edit URL")
    func sheetFullURL() {
        #expect(SourceURL.googleSheetID(from: "https://docs.google.com/spreadsheets/d/1SheetXYZ_9-0/edit") == "1SheetXYZ_9-0")
    }

    @Test("extracts the sheet id past trailing query params")
    func sheetTrailingParams() {
        #expect(SourceURL.googleSheetID(from: "https://docs.google.com/spreadsheets/d/1SheetXYZ_9-0/edit#gid=0") == "1SheetXYZ_9-0")
    }

    @Test("accepts a bare sheet id unchanged")
    func sheetBareID() {
        #expect(SourceURL.googleSheetID(from: "1SheetXYZ_9-0") == "1SheetXYZ_9-0")
    }

    @Test("returns nil for a sheet URL with a missing id")
    func sheetMissingID() {
        #expect(SourceURL.googleSheetID(from: "https://docs.google.com/spreadsheets/d//edit") == nil)
    }

    @Test("returns nil for junk sheet input")
    func sheetJunk() {
        #expect(SourceURL.googleSheetID(from: "definitely/not an id") == nil)
        #expect(SourceURL.googleSheetID(from: "") == nil)
    }

    @Test("returns nil when a doc URL is handed to the sheet parser (wrong host/path)")
    func sheetWrongPath() {
        #expect(SourceURL.googleSheetID(from: "https://docs.google.com/document/d/1DocABC/edit") == nil)
    }
}
