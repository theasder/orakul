import Foundation
import Testing
@testable import MeetGPT

/// Reading text size.
///
/// The acceptance criteria for this were specific: it must survive relaunch,
/// change the transcript and the answer, and NOT resize chrome so far that
/// controls collide. The last one is why this is a reading-only multiplier
/// rather than a global type scale, and most of these tests defend that
/// boundary rather than the arithmetic.
@Suite("Reading text scale")
struct ReadingTextScaleTests {

    // MARK: - Bounds

    @Test("clamps anything outside the supported range")
    func clampsOutOfRange() {
        #expect(ReadingTextScale.clamp(5.0) == ReadingTextScale.largest)
        #expect(ReadingTextScale.clamp(0.1) == ReadingTextScale.smallest)
        #expect(ReadingTextScale.clamp(1.15) == 1.15)
    }

    @Test("refuses values that would make the app unreadable")
    func refusesDegenerateValues() {
        // A preference file can be hand-edited or carried from a build with
        // different bounds. Zero or negative would render nothing; NaN
        // propagates into every frame calculation.
        #expect(ReadingTextScale.clamp(0) == ReadingTextScale.standard)
        #expect(ReadingTextScale.clamp(-2) == ReadingTextScale.standard)
        #expect(ReadingTextScale.clamp(.nan) == ReadingTextScale.standard)
        // Infinity falls back to STANDARD rather than to largest: a non-finite
        // value is corruption, not a request for very big text, and the safe
        // reading of corruption is "leave it as it was".
        #expect(ReadingTextScale.clamp(.infinity) == ReadingTextScale.standard)
    }

    @Test("every offered step is within bounds and ordered")
    func stepsAreValid() {
        #expect(ReadingTextScale.steps == ReadingTextScale.steps.sorted())
        for step in ReadingTextScale.steps {
            #expect(ReadingTextScale.clamp(step) == step, "\(step) is not selectable")
        }
        #expect(ReadingTextScale.steps.contains(ReadingTextScale.standard))
    }

    // MARK: - Point sizes

    @Test("standard scale leaves the existing size untouched")
    func standardIsIdentity() {
        // Anyone who never opens the setting must see exactly what they saw
        // before it existed.
        #expect(ReadingTextScale.pointSize(base: 15, scale: 1.0) == 15)
    }

    @Test("rounds to whole points")
    func roundsToWholePoints() {
        // Fractional sizes render, but paragraphs that round differently get
        // different line heights, which reads as uneven spacing rather than as
        // a bigger font.
        let size = ReadingTextScale.pointSize(base: 15, scale: 1.15)
        #expect(size == size.rounded())
    }

    @Test("grows monotonically across the steps")
    func growsMonotonically() {
        var previous = 0.0
        for step in ReadingTextScale.steps {
            let size = ReadingTextScale.pointSize(base: 15, scale: step)
            #expect(size >= previous, "step \(step) did not grow")
            previous = size
        }
    }

    @Test("the largest step stays within a sane reading size")
    func largestIsStillReasonable() {
        // The acceptance criterion is no clipping at the smallest supported
        // window. 15pt at 1.6 is 24pt, which wraps in a 420pt column rather
        // than overflowing it.
        #expect(ReadingTextScale.pointSize(base: 15, scale: ReadingTextScale.largest) <= 24)
    }

    @Test("an out-of-range scale cannot produce an out-of-range size")
    func sizeIsClampedToo() {
        // pointSize clamps internally, so a caller that skipped the clamp
        // cannot bypass the bound.
        #expect(ReadingTextScale.pointSize(base: 15, scale: 100) <= 24)
        #expect(ReadingTextScale.pointSize(base: 15, scale: .nan) == 15)
    }

    // MARK: - Stepping

    @Test("steps up and down through the offered values")
    func stepsThroughValues() {
        #expect(ReadingTextScale.step(from: 1.0, by: 1) == 1.15)
        #expect(ReadingTextScale.step(from: 1.15, by: -1) == 1.0)
    }

    @Test("stops at the ends rather than wrapping")
    func doesNotWrap() {
        // Wrapping from largest back to smallest on a held keypress is never
        // what was meant.
        #expect(ReadingTextScale.step(from: ReadingTextScale.largest, by: 1)
                == ReadingTextScale.largest)
        #expect(ReadingTextScale.step(from: ReadingTextScale.smallest, by: -1)
                == ReadingTextScale.smallest)
    }

    @Test("steps sensibly from a value that is not one of the steps")
    func stepsFromOffGridValue() {
        // A stored value from an older build may sit between steps; stepping
        // must still move, and move in the right direction.
        let up = ReadingTextScale.step(from: 1.07, by: 1)
        #expect(up > 1.0)
        #expect(ReadingTextScale.steps.contains(up))
    }

    // MARK: - Label

    @Test("labels the scale as a percentage")
    func labelsAsPercentage() {
        #expect(ReadingTextScale.label(for: 1.0) == "100%")
        #expect(ReadingTextScale.label(for: 1.15) == "115%")
        #expect(ReadingTextScale.label(for: ReadingTextScale.largest) == "160%")
    }

    @Test("labels a degenerate value as the default rather than as junk")
    func labelsDegenerateValue() {
        #expect(ReadingTextScale.label(for: .nan) == "100%")
    }

    // MARK: - Persistence

    @MainActor
    @Test("survives a relaunch")
    func persistsAcrossLaunches() {
        let previous = Config.readingTextScale
        defer { Config.readingTextScale = previous }

        Config.readingTextScale = 1.3
        // Reading it back is what a relaunch does; the value lives in
        // UserDefaults, not in the view.
        #expect(Config.readingTextScale == 1.3)
    }

    @MainActor
    @Test("a stored value outside the range is repaired on read")
    func repairsStoredValue() {
        let previous = Config.readingTextScale
        defer { Config.readingTextScale = previous }

        // Written past the setter, as a hand-edited plist or an older build
        // would be.
        UserDefaults.standard.set(9.0, forKey: "appearance.readingScale")
        #expect(Config.readingTextScale == ReadingTextScale.largest)
    }

    @MainActor
    @Test("defaults to unchanged when nothing was ever set")
    func defaultsToStandard() {
        let previous = Config.readingTextScale
        defer { Config.readingTextScale = previous }

        UserDefaults.standard.removeObject(forKey: "appearance.readingScale")
        #expect(Config.readingTextScale == ReadingTextScale.standard)
    }

    @MainActor
    @Test("setting it through app state writes through and repaints")
    func appStatePublishesAndPersists() {
        let previous = Config.readingTextScale
        defer { Config.readingTextScale = previous }

        let state = AppState(credentialStore: InMemoryKeychain())
        state.readingTextScale = 1.45

        // Published so the surfaces repaint immediately — a size control that
        // needs a relaunch reads as broken — and written through so it lasts.
        #expect(state.readingTextScale == 1.45)
        #expect(Config.readingTextScale == 1.45)
    }
}
