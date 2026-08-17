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

    // MARK: Google Slides

    @Test("extracts Slides ids from normal and account-qualified editor URLs")
    func slidesURLs() {
        #expect(SourceURL.googleSlidesID(
            from: "https://docs.google.com/presentation/d/1Slide_ABC-9/edit") == "1Slide_ABC-9")
        #expect(SourceURL.googleSlidesID(
            from: "https://docs.google.com/presentation/u/0/d/1Slide_ABC-9/edit") == "1Slide_ABC-9")
        #expect(SourceURL.googleSlidesID(from: "1Slide_ABC-9") == "1Slide_ABC-9")
    }

    @Test("Slides parser rejects non-Slides URLs")
    func slidesWrongPath() {
        #expect(SourceURL.googleSlidesID(
            from: "https://docs.google.com/spreadsheets/d/1SheetXYZ/edit") == nil)
    }

    // MARK: Google Forms

    @Test("extracts the API form id from editor URLs")
    func formsEditorURL() {
        #expect(SourceURL.googleFormID(
            from: "https://docs.google.com/forms/d/1Form_ABC-9/edit") == "1Form_ABC-9")
        #expect(SourceURL.googleFormID(
            from: "https://docs.google.com/forms/u/1/d/1Form_ABC-9/edit") == "1Form_ABC-9")
        #expect(SourceURL.googleFormID(from: "1Form_ABC-9") == "1Form_ABC-9")
    }

    @Test("rejects public responder links because /d/e ids are not Forms API ids")
    func formsPublishedURL() {
        #expect(SourceURL.googleFormID(
            from: "https://docs.google.com/forms/d/e/1FAIpQLScPublished/viewform") == nil)
        #expect(SourceURL.googleFormID(from: "https://forms.gle/short-code") == nil)
    }
}
