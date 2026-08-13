import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// The Fireflies import picker — the entry point that closed PROJECT_STATUS
/// item 18. The import CORE has 24 tests; these cover the seam the picker adds:
/// which of the three panel states renders, what gates the affordance, and how
/// the state layer behaves with no connection behind it.
@MainActor
@Suite("Fireflies import picker")
struct FirefliesImportPickerTests {

    private func state() -> AppState { AppState(credentialStore: InMemoryKeychain()) }

    private func meeting(id: String = "m1", title: String = "Weekly sync") -> FirefliesPastCalls.MeetingSummary {
        FirefliesPastCalls.MeetingSummary(
            id: id, title: title,
            date: Date(timeIntervalSince1970: 1_754_700_000),
            participants: ["Ana", "Leo", "Sam", "Kim"],
            durationSeconds: 1_860)
    }

    private func inspect(_ state: AppState) throws -> InspectableView<ViewType.ClassifiedView> {
        try FirefliesImportPicker(isPresented: .constant(true))
            .environmentObject(state)
            .inspect()
    }

    // MARK: - Which panel renders

    @Test("busy with nothing loaded yet shows the loading state")
    func loadingState() throws {
        let state = state()
        state.firefliesImportBusy = true
        let text = try inspect(state).findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(text.contains { $0.contains("Загружаю звонки из Fireflies") })
    }

    @Test("a failure with no list shows the error and a retry")
    func failureState() throws {
        let state = state()
        state.firefliesImportError = "Couldn't reach Fireflies: offline."
        let view = try inspect(state)
        let text = try view.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(text.contains { $0.contains("Couldn't reach Fireflies") })
        #expect(throws: Never.self) { _ = try view.find(button: "Ещё раз") }
    }

    @Test("meetings render as rows")
    func listState() throws {
        let state = state()
        state.firefliesMeetings = [meeting(), meeting(id: "m2", title: "Design review")]
        let text = try inspect(state).findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(text.contains { $0.contains("Weekly sync") })
        #expect(text.contains { $0.contains("Design review") })
    }

    @Test("an empty title still renders a recognisable row")
    func untitledMeeting() throws {
        let state = state()
        state.firefliesMeetings = [meeting(title: "")]
        let text = try inspect(state).findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(text.contains { $0.contains("Untitled meeting") })
    }

    @Test("an import failure AFTER a loaded list shows above the rows, keeping the list")
    func postListError() throws {
        // The distinct case: the list loaded fine, then one import failed. The
        // user is still choosing — the rows must survive alongside the reason.
        let state = state()
        state.firefliesMeetings = [meeting()]
        state.firefliesImportError = "Couldn't import that meeting: no transcript."
        let text = try inspect(state).findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(text.contains { $0.contains("Couldn't import that meeting") })
        #expect(text.contains { $0.contains("Weekly sync") }, "the list must not vanish")
    }

    // MARK: - The gate

    @Test("the affordance is gated on a connected Fireflies")
    func gateRequiresConnection() {
        // No MCP manager at all — the button would be an invitation to an
        // error dialog, so it must not exist.
        #expect(!state().canImportFromFireflies)
    }

    // MARK: - State layer without a connection

    @Test("loading with no manager is a safe no-op")
    func loadWithoutManager() {
        let state = state()
        state.loadFirefliesMeetings()
        #expect(!state.firefliesImportBusy)
        #expect(state.firefliesMeetings.isEmpty)
    }

    @Test("importing with no manager reports failure instead of hanging")
    func importWithoutManager() async {
        let state = state()
        var outcome: Bool?
        state.importFirefliesMeeting(meeting()) { outcome = $0 }
        // The callback is synchronous on this path — the guard fires before
        // any task is spawned.
        #expect(outcome == false)
    }
}
