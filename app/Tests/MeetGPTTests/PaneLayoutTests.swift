import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// Backlog item 3 — collapsible panes. The acceptance criteria, as tests:
/// independent toggles, persistence across launches, and above all the
/// no-lockout rule: no sequence of toggles reaches a window with nothing in
/// it, and no persisted value restores one.
@Suite("Pane layout")
struct PaneLayoutTests {

    // MARK: - Independence

    @Test("each pane toggles without touching the others")
    func togglesAreIndependent() {
        let hidden = PaneLayout.all.toggling(.sidebar)
        #expect(!hidden.sidebar)
        #expect(hidden.transcript)
        #expect(hidden.assistant)
    }

    @Test("every single-pane window is reachable", arguments: PaneLayout.Pane.allCases)
    func singlePaneWindows(pane: PaneLayout.Pane) {
        // The point of the feature: transcript-only reading pane,
        // assistant-only answer pane.
        var layout = PaneLayout.all
        for other in PaneLayout.Pane.allCases where other != pane {
            layout = layout.toggling(other)
        }
        #expect(layout.isVisible(pane))
        #expect(layout.visibleCount == 1)
    }

    // MARK: - The no-lockout rule

    @Test("hiding the last visible pane is a no-op", arguments: PaneLayout.Pane.allCases)
    func lastPaneCannotHide(pane: PaneLayout.Pane) {
        var layout = PaneLayout.all
        for other in PaneLayout.Pane.allCases where other != pane {
            layout = layout.toggling(other)
        }
        #expect(layout.toggling(pane) == layout, "the last pane must refuse to hide")
    }

    @Test("no toggle sequence reaches an empty window")
    func exhaustiveNoLockout() {
        // Every layout state × every toggle: 8 states, 3 toggles each. Small
        // enough to enumerate, so enumerate rather than argue.
        for mask in 0..<8 {
            let start = PaneLayout(sidebar: mask & 1 != 0,
                                   transcript: mask & 2 != 0,
                                   assistant: mask & 4 != 0)
            guard start.visibleCount > 0 else { continue }
            for pane in PaneLayout.Pane.allCases {
                #expect(start.toggling(pane).visibleCount > 0)
            }
        }
    }

    // MARK: - Persistence

    @Test("a layout survives the encode/decode round trip")
    func roundTrip() {
        let layout = PaneLayout(sidebar: false, transcript: true, assistant: false)
        #expect(PaneLayout.decode(layout.encoded) == layout)
    }

    @Test("junk, old schemas, and nil restore to everything visible", arguments: [
        nil, "", "not json", "[1,2,3]", "{\"sidebar\":true}",
    ] as [String?])
    func badPersistedValues(raw: String?) {
        // Partial JSON ({"sidebar":true}) is an old or foreign schema — the
        // decoder requires all three keys, so it corrects to .all rather than
        // guessing the missing panes.
        #expect(PaneLayout.decode(raw) == .all)
    }

    @Test("a persisted all-hidden layout is corrected on read")
    func allHiddenIsCorrected() {
        let bad = PaneLayout(sidebar: false, transcript: false, assistant: false)
        #expect(PaneLayout.decode(bad.encoded) == .all,
                "a window with zero panes is a bug with a memory, not a layout")
    }

    // MARK: - The store

    @MainActor
    @Test("the store persists through UserDefaults and re-reads on init")
    func storePersists() {
        let saved = UserDefaults.standard.string(forKey: PaneLayoutStore.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: PaneLayoutStore.key) }
            else { UserDefaults.standard.removeObject(forKey: PaneLayoutStore.key) }
        }
        let store = PaneLayoutStore()
        store.replace(.all)
        store.toggle(.assistant)
        #expect(!store.layout.assistant)
        // A second store — a relaunch — reads the same layout back.
        #expect(PaneLayoutStore().layout == store.layout)
    }

    @MainActor
    @Test("replace refuses an all-hidden layout")
    func replaceGuards() {
        let saved = UserDefaults.standard.string(forKey: PaneLayoutStore.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: PaneLayoutStore.key) }
            else { UserDefaults.standard.removeObject(forKey: PaneLayoutStore.key) }
        }
        let store = PaneLayoutStore()
        store.replace(PaneLayout(sidebar: false, transcript: false, assistant: false))
        #expect(store.layout == .all)
    }
}
