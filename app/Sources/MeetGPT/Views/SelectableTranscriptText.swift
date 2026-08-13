import AppKit
import SwiftUI

/// The transcript as one selectable `NSTextView`.
///
/// SwiftUI's `.textSelection(.enabled)` lets a user copy but never tells the app
/// what was selected, so "select a phrase and ask about it" is impossible with
/// it. AppKit gives the selected range, which is the whole point of dropping to
/// a representable here.
///
/// Three behaviours have to survive the move from the SwiftUI row list: follow-
/// the-latest scrolling that stops when the user scrolls up, live appends while
/// recording without rebuilding the world on every chunk, and speaker rename
/// from the context menu.
struct SelectableTranscriptText: NSViewRepresentable {
    let entries: [TranscriptEntry]
    let provisional: [ProvisionalLine]
    /// Whether to keep pinning to the bottom as new speech lands.
    @Binding var followsLatest: Bool
    /// Emitted whenever the selection changes: the attributed quote, or "".
    let onSelectionChange: (String) -> Void
    let onRenameSpeaker: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange, onRenameSpeaker: onRenameSpeaker)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.textContainerInset = NSSize(width: 20, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scroll = TranscriptScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.onReaderScroll = { [weak coordinator = context.coordinator] in
            coordinator?.readerWillScroll()
        }

        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.observeScroll()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onRenameSpeaker = onRenameSpeaker
        context.coordinator.followsLatest = $followsLatest
        context.coordinator.apply(
            entries: entries,
            provisional: provisional,
            appearance: scroll.effectiveAppearance,
            shouldScrollToBottom: followsLatest)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: (String) -> Void
        var onRenameSpeaker: (String) -> Void
        var followsLatest: Binding<Bool>?
        weak var textView: TranscriptTextView?
        weak var scrollView: NSScrollView?

        private(set) var segments: [TranscriptTextRenderer.Segment] = []
        /// Identity of what is currently rendered. Re-rendering an unchanged
        /// transcript would clear the user's selection on every state tick — the
        /// bug that makes a selectable live transcript unusable.
        private var renderedFingerprint: String = ""
        /// The SwiftUI binding is the public source of truth, while this local
        /// copy lets us distinguish a "Последняя" request from an ordinary update
        /// whose rendered transcript has not changed.
        private var lastRequestedFollow = true
        /// Replacing an attributed string changes both the document height and
        /// the clip bounds. Those AppKit notifications are programmatic, not a
        /// reader deciding to leave the live tail, so they must not mutate the
        /// binding. The generation also invalidates a stale, coalesced anchor.
        private var viewportMutationGeneration: UInt = 0
        private var activeViewportMutation: UInt?
        private var pendingViewportSettle: DispatchWorkItem?
        private var pendingPositionPublish: DispatchWorkItem?
        private var pendingPositionIsReaderDriven = false
        /// Set by a scroll-wheel/live-scroll gesture before AppKit moves the
        /// clip view. It makes even a small deliberate scroll use the tight
        /// engage threshold rather than the content-growth release threshold.
        private var nextBoundsChangeIsReaderDriven = false

        init(onSelectionChange: @escaping (String) -> Void,
             onRenameSpeaker: @escaping (String) -> Void) {
            self.onSelectionChange = onSelectionChange
            self.onRenameSpeaker = onRenameSpeaker
        }

        func apply(entries: [TranscriptEntry],
                   provisional: [ProvisionalLine],
                   appearance: NSAppearance,
                   shouldScrollToBottom: Bool) {
            let fingerprint = Self.fingerprint(entries: entries, provisional: provisional,
                                               appearance: appearance)
            let contentChanged = fingerprint != renderedFingerprint
            let followWasRequested = shouldScrollToBottom && !lastRequestedFollow
            lastRequestedFollow = shouldScrollToBottom

            // "Последняя" has to work even when no new words landed between the
            // reader scrolling away and pressing the button.
            guard contentChanged || followWasRequested else { return }
            if !contentChanged {
                scheduleViewport(.followBottom)
                return
            }
            renderedFingerprint = fingerprint

            guard let textView, let storage = textView.textStorage else { return }
            // Preserve the selection across an append: new speech arriving must
            // not yank a quote out from under someone mid-drag.
            let previousSelection = textView.selectedRange()

            let rendered = TranscriptTextRenderer.render(
                entries: entries, provisional: provisional, appearance: appearance)
            segments = rendered.segments

            let preservedOrigin = scrollView?.contentView.bounds.origin ?? .zero
            let viewportIntent: ViewportIntent = shouldScrollToBottom
                ? .followBottom
                : .preserve(preservedOrigin)
            beginViewportMutation()

            storage.beginEditing()
            storage.setAttributedString(rendered.attributed)
            storage.endEditing()

            let length = storage.length
            if previousSelection.length > 0,
               NSMaxRange(previousSelection) <= length {
                textView.setSelectedRange(previousSelection)
            }

            // NSTextKit can defer the new document geometry until the next run
            // loop. Anchor once synchronously after forcing layout, then once
            // more on the next turn. Rapid interim chunks replace the pending
            // settle instead of queuing a procession of stale scrolls.
            scheduleViewport(viewportIntent)
        }

        private enum ViewportIntent {
            case followBottom
            case preserve(NSPoint)
        }

        private func beginViewportMutation() {
            viewportMutationGeneration &+= 1
            activeViewportMutation = viewportMutationGeneration
            pendingViewportSettle?.cancel()
            pendingViewportSettle = nil
            pendingPositionPublish?.cancel()
            pendingPositionPublish = nil
            pendingPositionIsReaderDriven = false
        }

        private func scheduleViewport(_ intent: ViewportIntent) {
            if activeViewportMutation == nil {
                beginViewportMutation()
            }
            let generation = viewportMutationGeneration
            // Applying immediately keeps an already-laid-out document pinned;
            // the coalesced pass catches NSTextKit's deferred height update.
            applyViewport(intent)

            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.activeViewportMutation == generation else { return }
                self.applyViewport(intent)
                // Leave suppression in place for one additional queue turn.
                // NSTextKit may publish the bounds change caused by the layout
                // we just forced after this block returns.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.activeViewportMutation == generation else { return }
                    self.activeViewportMutation = nil
                    self.pendingViewportSettle = nil
                }
            }
            pendingViewportSettle = work
            DispatchQueue.main.async(execute: work)
        }

        private func applyViewport(_ intent: ViewportIntent) {
            guard let textView, let scrollView else { return }
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()
            scrollView.tile()

            let clipView = scrollView.contentView
            switch intent {
            case .followBottom:
                // `scrollRangeToVisible` consults glyph geometry, and the
                // explicit visual-bottom anchor removes its "already visible"
                // ambiguity when a provisional shrinks into a final line.
                let length = textView.textStorage?.length ?? 0
                textView.scrollRangeToVisible(NSRange(location: length, length: 0))
                if let documentView = scrollView.documentView {
                    var origin = clipView.bounds.origin
                    origin.y = documentView.isFlipped
                        ? max(documentView.bounds.minY,
                              documentView.bounds.maxY - clipView.bounds.height)
                        : documentView.bounds.minY
                    clipView.scroll(to: origin)
                }
            case .preserve(let origin):
                // The transcript only appends/replaces its live tail. Keeping
                // the exact clip origin therefore keeps the same historical
                // lines under a reader's eyes while fresh speech arrives.
                if let documentView = scrollView.documentView {
                    var clamped = origin
                    clamped.x = min(max(clamped.x, documentView.bounds.minX),
                                    max(documentView.bounds.minX,
                                        documentView.bounds.maxX - clipView.bounds.width))
                    clamped.y = min(max(clamped.y, documentView.bounds.minY),
                                    max(documentView.bounds.minY,
                                        documentView.bounds.maxY - clipView.bounds.height))
                    clipView.scroll(to: clamped)
                }
            }
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Cheap identity for "has anything visible changed". Entry ids plus the
        /// provisional text catch every case that alters the rendering without
        /// hashing the whole transcript body on every tick.
        private static func fingerprint(entries: [TranscriptEntry],
                                        provisional: [ProvisionalLine],
                                        appearance: NSAppearance) -> String {
            var parts: [String] = [appearance.name.rawValue, String(entries.count)]
            if let last = entries.last {
                parts.append(last.id.uuidString)
                parts.append(String(last.text.count))
                parts.append(last.speaker ?? "")
                parts.append(last.transcriptionEngine?.rawValue ?? "")
            }
            // Speaker rename rewrites labels across the whole transcript, so the
            // set of labels has to be part of the identity.
            parts.append(Set(entries.compactMap(\.speaker)).sorted().joined(separator: ","))
            parts.append(entries.map { $0.transcriptionEngine?.rawValue ?? "legacy" }
                .joined(separator: ","))
            parts.append(provisional.map(\.text).joined(separator: "|"))
            return parts.joined(separator: "#")
        }

        // MARK: Selection

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let quote = TranscriptTextRenderer.quote(
                for: range, in: segments, fullText: textView.string)
            onSelectionChange(quote)
        }

        /// The speaker label under the current selection, for the rename item.
        func speakerForSelection() -> String? {
            guard let textView else { return nil }
            let touched = TranscriptTextRenderer.segments(
                in: textView.selectedRange(), of: segments)
            // Only offer rename for a real diarized label, never "You"/"Them".
            return touched.compactMap(\.speaker)
                .first(where: { $0 != "You" && $0 != "Them" })
        }

        func requestRename(_ speaker: String) { onRenameSpeaker(speaker) }

        // MARK: Scroll following

        func observeScroll() {
            guard let scrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(liveScrollWillStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView)
        }

        /// Called before a wheel/trackpad/scroller gesture moves the viewport.
        /// Cancelling a deferred bottom anchor here prevents a reader gesture
        /// from racing an interim transcript update.
        func readerWillScroll() {
            pendingViewportSettle?.cancel()
            pendingViewportSettle = nil
            pendingPositionPublish?.cancel()
            pendingPositionPublish = nil
            pendingPositionIsReaderDriven = false
            activeViewportMutation = nil
            nextBoundsChangeIsReaderDriven = true
        }

        @objc private func liveScrollWillStart() {
            readerWillScroll()
        }

        /// Scrolling up detaches from the live tail; returning to the bottom
        /// re-attaches. Same contract the SwiftUI list had.
        @objc private func boundsChanged() {
            guard activeViewportMutation == nil else { return }
            let readerDriven = nextBoundsChangeIsReaderDriven
            nextBoundsChangeIsReaderDriven = false
            if readerDriven {
                // Direct document geometry is already current here. Publishing
                // synchronously closes the race where a transcript chunk lands
                // between the reader gesture and a deferred intent update.
                pendingPositionPublish?.cancel()
                pendingPositionPublish = nil
                pendingPositionIsReaderDriven = false
                publishPosition(readerDriven: true)
                return
            }
            schedulePositionPublish(readerDriven: readerDriven)
        }

        private func schedulePositionPublish(readerDriven: Bool) {
            pendingPositionIsReaderDriven = pendingPositionIsReaderDriven || readerDriven
            pendingPositionPublish?.cancel()
            let generation = viewportMutationGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.activeViewportMutation == nil,
                      self.viewportMutationGeneration == generation else { return }
                self.pendingPositionPublish = nil
                let explicitlyMovedByReader = self.pendingPositionIsReaderDriven
                self.pendingPositionIsReaderDriven = false
                self.publishPosition(readerDriven: explicitlyMovedByReader)
            }
            pendingPositionPublish = work
            DispatchQueue.main.async(execute: work)
        }

        private func publishPosition(readerDriven: Bool) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let visible = scrollView.documentVisibleRect
            let remaining = documentView.isFlipped
                ? documentView.bounds.maxY - visible.maxY
                : visible.minY - documentView.bounds.minY
            let currentlyFollowing = followsLatest?.wrappedValue ?? lastRequestedFollow
            // Content growth gets the wide release side of the hysteresis.
            // An explicit reader gesture uses the tight side immediately: even
            // a one-line scroll means "let me read here".
            let atBottom = LiveScrollPolicy.shouldFollow(
                currentlyFollowing: readerDriven ? false : currentlyFollowing,
                remainingDistance: remaining)
            lastRequestedFollow = atBottom
            if followsLatest?.wrappedValue != atBottom {
                followsLatest?.wrappedValue = atBottom
            }
        }

        deinit {
            pendingViewportSettle?.cancel()
            pendingPositionPublish?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// Identifies real wheel/trackpad input before AppKit posts the same bounds
/// notification used by programmatic transcript updates.
final class TranscriptScrollView: NSScrollView {
    var onReaderScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onReaderScroll?()
        super.scrollWheel(with: event)
    }
}

/// NSTextView subclass that contributes transcript-specific context-menu items.
final class TranscriptTextView: NSTextView {
    weak var coordinator: SelectableTranscriptText.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let coordinator else { return menu }

        if selectedRange().length > 0 {
            let ask = NSMenuItem(title: "Спросить об этом",
                                 action: #selector(askAboutSelection), keyEquivalent: "")
            ask.target = self
            menu.insertItem(ask, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        if let speaker = coordinator.speakerForSelection() {
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "Переименовать «\(speaker)»…",
                                    action: #selector(renameSpeaker), keyEquivalent: "")
            rename.target = self
            rename.representedObject = speaker
            menu.addItem(rename)
        }
        return menu
    }

    /// Posted rather than called directly so the SwiftUI layer owns what "ask"
    /// means — the text view's job ends at reporting the selection.
    @objc private func askAboutSelection() {
        NotificationCenter.default.post(name: .transcriptAskAboutSelection, object: nil)
    }

    @objc private func renameSpeaker(_ sender: NSMenuItem) {
        guard let speaker = sender.representedObject as? String else { return }
        coordinator?.requestRename(speaker)
    }
}

extension Notification.Name {
    static let transcriptAskAboutSelection = Notification.Name("transcriptAskAboutSelection")
}
