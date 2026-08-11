import Foundation
import AppKit
import Combine
import SwiftUI
import Testing
@testable import MeetGPT

private final class ScrollTestDocumentView: NSView {
    private let usesFlippedCoordinates: Bool
    override var isFlipped: Bool { usesFlippedCoordinates }

    init(flipped: Bool) {
        self.usesFlippedCoordinates = flipped
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@Suite("Live scroll policy")
struct LiveScrollPolicyTests {
    @Test("content at or near the bottom stays in follow mode")
    func nearBottom() {
        #expect(LiveScrollPolicy.isNearBottom(documentMaxY: 800, visibleMaxY: 800))
        #expect(LiveScrollPolicy.isNearBottom(documentMaxY: 820, visibleMaxY: 800))
        #expect(LiveScrollPolicy.isNearBottom(documentMaxY: 400, visibleMaxY: 600))
    }

    @Test("manual scroll-away suspends automatic following")
    func awayFromBottom() {
        #expect(!LiveScrollPolicy.isNearBottom(documentMaxY: 900, visibleMaxY: 800))
    }

    @Test("normalized macOS scroller position is independent of view Y orientation")
    func normalizedScrollerPosition() {
        #expect(!LiveScrollPolicy.isNearBottom(scrollerValue: 0, scrollableDistance: 600))
        #expect(!LiveScrollPolicy.isNearBottom(scrollerValue: 0.95, scrollableDistance: 600))
        #expect(LiveScrollPolicy.isNearBottom(scrollerValue: 0.97, scrollableDistance: 600))
        #expect(LiveScrollPolicy.isNearBottom(scrollerValue: 0, scrollableDistance: 20))
        #expect(LiveScrollPolicy.scrollableDistance(
            viewportHeight: 400, knobProportion: 0.5, fallbackDocumentHeight: 400) == 400)
        #expect(LiveScrollPolicy.scrollableDistance(
            viewportHeight: 400, knobProportion: 0.25, fallbackDocumentHeight: 400) == 1_200)
    }

    @Test("answer scroll requests use a trailing throttle")
    func throttle() {
        #expect(LiveScrollPolicy.delayUntilNextScroll(lastScrollAt: nil, now: 10) == 0)
        #expect(abs(LiveScrollPolicy.delayUntilNextScroll(lastScrollAt: 10, now: 10.04) - 0.04) < 0.0001)
        #expect(LiveScrollPolicy.delayUntilNextScroll(lastScrollAt: 10, now: 10.08) == 0)
    }

    // Reported from a real call: "scrolling of assistant chat was glitching".
    // Streamed markdown grows the document BETWEEN the 80 ms scroll ticks, so a
    // tall paragraph could push the viewport past the 24 pt "near bottom" line
    // with no reader input — follow mode silently disengaged, the text kept
    // rendering below the fold, and the pane looked frozen mid-answer.

    @Test("following survives content growth smaller than the release distance")
    func followHysteresisKeepsFollowing() {
        // Already following + 60 pt of fresh content: stay engaged.
        #expect(LiveScrollPolicy.shouldFollow(currentlyFollowing: true, remainingDistance: 60))
        // A reader flick is far bigger than one streamed paragraph.
        #expect(!LiveScrollPolicy.shouldFollow(currentlyFollowing: true, remainingDistance: 300))
    }

    @Test("re-engaging still requires actually returning to the bottom")
    func followHysteresisReengagesTight() {
        // Not following: 60 pt away is NOT back at the bottom.
        #expect(!LiveScrollPolicy.shouldFollow(currentlyFollowing: false, remainingDistance: 60))
        #expect(LiveScrollPolicy.shouldFollow(currentlyFollowing: false, remainingDistance: 12))
    }

    @Test("the release distance is meaningfully wider than the engage distance")
    func hysteresisBandExists() {
        #expect(LiveScrollPolicy.followReleaseThreshold
                >= LiveScrollPolicy.nearBottomThreshold * 3)
    }

    @Test("streamed markdown prefixes cannot grow the cache without bound")
    func boundedMarkdownCache() {
        let cache = MarkdownCache()
        for index in 0..<(MarkdownCache.capacity * 3) {
            let key = String(repeating: "x", count: index + 1)
            _ = cache.value(for: key) { AttributedString(key) }
        }
        #expect(cache.map.count <= MarkdownCache.capacity)
    }

    @Test("microphone level work is sampled before reaching the main actor")
    func microphoneLevelGate() {
        let gate = AudioLevelUpdateGate(minimumInterval: 0.05)
        #expect(gate.shouldSample(at: 10.00))
        #expect(!gate.shouldSample(at: 10.02))
        #expect(gate.shouldSample(at: 10.05))
    }

    @MainActor
    @Test("recording clock publishes whole seconds without invalidating AppState")
    func isolatedRecordingClock() {
        let state = AppState()
        var clockPublications = 0
        var appPublications = 0
        let clockObservation = state.recordingClock.$elapsed.dropFirst().sink { _ in
            clockPublications += 1
        }
        let appObservation = state.objectWillChange.sink { _ in
            appPublications += 1
        }

        state.recordingClock.update(0.25)
        state.recordingClock.update(0.99)
        state.recordingClock.update(1.01)
        state.recordingClock.update(1.75)
        state.recordingClock.update(2.10)

        #expect(state.elapsed == 2)
        #expect(clockPublications == 2)
        #expect(appPublications == 0)

        state.recordingClock.reset()
        #expect(state.elapsed == 0)
        #expect(clockPublications == 3)
        _ = (clockObservation, appObservation)
    }

    @MainActor
    @Test("scroll observer tracks visual top and bottom for flipped and unflipped content",
          arguments: [true, false])
    func appKitScrollOrientation(flipped: Bool) async {
        var nearBottom = true
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = ScrollTestDocumentView(flipped: flipped)
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = LiveScrollPositionObserver.Coordinator(
            isNearBottom: Binding(get: { nearBottom }, set: { nearBottom = $0 }),
            threshold: 24
        )
        coordinator.attach(to: scrollView)

        let topY: CGFloat = flipped ? 0 : 400
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await drainMainQueue()
        #expect(!nearBottom)

        let bottomY: CGFloat = flipped ? 400 : 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await drainMainQueue()
        #expect(nearBottom)

        coordinator.detach()
    }

    @MainActor
    @Test("detaching an old coordinator cannot disable a replacement observer")
    func overlappingCoordinatorCleanup() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = ScrollTestDocumentView(flipped: true)
        let binding = Binding<Bool>(get: { true }, set: { _ in })
        let old = LiveScrollPositionObserver.Coordinator(isNearBottom: binding, threshold: 24)
        let replacement = LiveScrollPositionObserver.Coordinator(isNearBottom: binding, threshold: 24)

        old.attach(to: scrollView)
        replacement.attach(to: scrollView)
        old.detach()

        #expect(scrollView.contentView.postsBoundsChangedNotifications)
        replacement.detach()
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// AppKit-level coverage for the failure visible in the Instant transcript
/// screenshots: a very tall interim paragraph was repeatedly replaced by a
/// final block while bounds notifications raced the bottom anchor. The pane
/// alternated between following, detaching, and jumping several screens.
@MainActor
@Suite("Selectable transcript live scrolling", .serialized)
struct SelectableTranscriptLiveScrollTests {
    @MainActor
    private final class Harness {
        var followsLatest = true
        let scrollView: TranscriptScrollView
        let textView: TranscriptTextView
        let coordinator: SelectableTranscriptText.Coordinator

        init(width: CGFloat = 320, height: CGFloat = 180) {
            coordinator = SelectableTranscriptText.Coordinator(
                onSelectionChange: { _ in }, onRenameSpeaker: { _ in })
            textView = TranscriptTextView(
                frame: NSRect(x: 0, y: 0, width: width, height: height))
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 20, height: 12)
            textView.textContainer?.widthTracksTextView = true
            textView.delegate = coordinator
            textView.coordinator = coordinator

            scrollView = TranscriptScrollView(
                frame: NSRect(x: 0, y: 0, width: width, height: height))
            scrollView.hasVerticalScroller = true
            scrollView.documentView = textView
            scrollView.onReaderScroll = { [weak coordinator] in
                coordinator?.readerWillScroll()
            }
            scrollView.tile()
            scrollView.layoutSubtreeIfNeeded()

            coordinator.textView = textView
            coordinator.scrollView = scrollView
            coordinator.followsLatest = Binding(
                get: { [weak self] in self?.followsLatest ?? true },
                set: { [weak self] in self?.followsLatest = $0 })
            coordinator.observeScroll()
        }

        func apply(entries: [TranscriptEntry],
                   provisional: [ProvisionalLine] = [],
                   follow: Bool? = nil) {
            let requested = follow ?? followsLatest
            coordinator.apply(
                entries: entries,
                provisional: provisional,
                appearance: NSAppearance(named: .aqua)!,
                shouldScrollToBottom: requested)
        }

        var remainingDistance: CGFloat {
            guard let document = scrollView.documentView else { return 0 }
            let visible = scrollView.documentVisibleRect
            return max(0, document.isFlipped
                       ? document.bounds.maxY - visible.maxY
                       : visible.minY - document.bounds.minY)
        }

        func readerScroll(toY y: CGFloat) {
            coordinator.readerWillScroll()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func readerScrollToBottom() {
            guard let document = scrollView.documentView else { return }
            let y = document.isFlipped
                ? max(document.bounds.minY,
                      document.bounds.maxY - scrollView.contentView.bounds.height)
                : document.bounds.minY
            readerScroll(toY: y)
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func history(count: Int = 24) -> [TranscriptEntry] {
        (0..<count).map { index in
            TranscriptEntry(
                source: .system,
                text: "Historical line \(index): "
                    + String(repeating: "stable context for the reader ", count: 5),
                timestamp: base.addingTimeInterval(TimeInterval(index * 100)),
                speaker: index.isMultiple(of: 2) ? "Speaker A" : "Speaker B",
                transcriptionEngine: .deepgram)
        }
    }

    @Test("large Instant provisional becoming final stays pinned through later lines")
    func largeProvisionalFinalizationStaysPinned() async {
        let harness = Harness()
        var entries = history()
        harness.apply(entries: entries)
        await settleAppKit()

        // Keep a real quote selected while the live tail changes. A scroll fix
        // must not regress transcript selection.
        let selection = harness.coordinator.segments[3].bodyRange
        harness.textView.setSelectedRange(selection)

        let hugeInterim = String(
            repeating: "Трейсы каждого вызова и офлайн-оценка на golden dataset. ",
            count: 220)
        harness.apply(
            entries: entries,
            provisional: [ProvisionalLine(source: .system, text: hugeInterim)])
        await settleAppKit()
        #expect(harness.followsLatest)
        #expect(harness.remainingDistance <= 1)
        #expect(harness.textView.selectedRange() == selection)

        // The interim is replaced, not appended, then more final lines arrive
        // in rapid succession. Every replacement must remain visually pinned.
        entries.append(TranscriptEntry(
            source: .system,
            text: String(repeating: "Финальная версия технического объяснения. ", count: 55),
            timestamp: base.addingTimeInterval(2_500),
            speaker: "Speaker A", transcriptionEngine: .deepgram))
        harness.apply(entries: entries)
        await settleAppKit()
        #expect(harness.followsLatest)
        #expect(harness.remainingDistance <= 1)
        #expect(harness.textView.selectedRange() == selection)

        for index in 0..<5 {
            entries.append(TranscriptEntry(
                source: .system,
                text: "Subsequent finalized line \(index) after the interim replacement.",
                timestamp: base.addingTimeInterval(2_510 + TimeInterval(index)),
                speaker: "Speaker A", transcriptionEngine: .deepgram))
            harness.apply(entries: entries)
        }
        await settleAppKit()
        #expect(harness.followsLatest)
        #expect(harness.remainingDistance <= 1)
        #expect(harness.textView.selectedRange() == selection)
    }

    @Test("manual scroll-away preserves viewport across interim and final replacement")
    func manualScrollAwayPreservesViewport() async {
        let harness = Harness()
        var entries = history(count: 32)
        harness.apply(entries: entries)
        await settleAppKit()
        #expect(harness.remainingDistance <= 1)

        harness.readerScroll(toY: 260)
        await settleAppKit()
        #expect(!harness.followsLatest)
        let readerOrigin = harness.scrollView.contentView.bounds.origin.y

        let hugeInterim = String(
            repeating: "Live provisional material below the reader viewport. ", count: 260)
        harness.apply(
            entries: entries,
            provisional: [ProvisionalLine(source: .system, text: hugeInterim)],
            follow: false)
        await settleAppKit()
        #expect(!harness.followsLatest)
        #expect(abs(harness.scrollView.contentView.bounds.origin.y - readerOrigin) <= 0.5)

        entries.append(TranscriptEntry(
            source: .system,
            text: String(repeating: "Finalized replacement remains below. ", count: 35),
            timestamp: base.addingTimeInterval(3_300),
            speaker: "Speaker A", transcriptionEngine: .deepgram))
        harness.apply(entries: entries, follow: false)
        await settleAppKit()
        #expect(!harness.followsLatest)
        #expect(abs(harness.scrollView.contentView.bounds.origin.y - readerOrigin) <= 0.5)

        // Reaching the bottom deliberately re-engages follow mode.
        harness.readerScrollToBottom()
        await settleAppKit()
        #expect(harness.followsLatest)
        #expect(harness.remainingDistance <= LiveScrollPolicy.nearBottomThreshold)
    }

    @Test("Latest re-engages and anchors even when transcript text is unchanged")
    func latestAnchorsUnchangedTranscript() async {
        let harness = Harness()
        let entries = history(count: 28)
        harness.apply(entries: entries)
        await settleAppKit()

        harness.readerScroll(toY: 180)
        await settleAppKit()
        #expect(!harness.followsLatest)
        #expect(harness.remainingDistance > LiveScrollPolicy.nearBottomThreshold)

        // This is exactly what the SwiftUI "Latest" button does. The renderer
        // fingerprint is unchanged, so only the false→true intent transition
        // can trigger the anchor.
        harness.followsLatest = true
        harness.apply(entries: entries, follow: true)
        await settleAppKit()
        #expect(harness.followsLatest)
        #expect(harness.remainingDistance <= 1)
    }

    @Test("small explicit reader scroll wins over follow hysteresis")
    func smallReaderScrollDetaches() async {
        let harness = Harness()
        let entries = history(count: 28)
        harness.apply(entries: entries)
        await settleAppKit()

        let bottomY = harness.scrollView.contentView.bounds.origin.y
        // Sixty points is deliberately inside the 160-point content-growth
        // release band. A real reader gesture still has to detach immediately,
        // even when AppKit coalesces several bounds notifications for it.
        harness.readerScroll(toY: bottomY - 60)
        harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomY - 62))
        harness.scrollView.reflectScrolledClipView(harness.scrollView.contentView)
        await settleAppKit()

        #expect(!harness.followsLatest)
        #expect(harness.remainingDistance > LiveScrollPolicy.nearBottomThreshold)
        #expect(harness.remainingDistance < LiveScrollPolicy.followReleaseThreshold)
    }

    private func settleAppKit(turns: Int = 4) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
