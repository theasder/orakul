import AppKit
import SwiftUI

/// Shared policy for live transcript/answer panes. Content follows only while
/// the reader is already at the bottom; scrolling upward transfers control to
/// the reader until they return or press "Последняя".
enum LiveScrollPolicy {
    static let nearBottomThreshold: CGFloat = 24
    /// How far the bottom may drift before follow mode DISENGAGES. Wider than
    /// the engage distance on purpose (hysteresis): streamed markdown grows the
    /// document between 80 ms scroll ticks, so a single tall paragraph could
    /// push the viewport past the tight line with no reader input — follow
    /// silently stopped and the answer kept rendering below the fold. A real
    /// reader flick moves hundreds of points; one streamed batch never does.
    static let followReleaseThreshold: CGFloat = 160
    static let answerScrollInterval: TimeInterval = 0.08

    /// Whether follow mode should be engaged, given where the viewport sits
    /// now. Engaging is tight (the reader really returned); releasing is loose
    /// (content growth alone must not break follow).
    static func shouldFollow(currentlyFollowing: Bool, remainingDistance: CGFloat) -> Bool {
        guard remainingDistance.isFinite else { return true }
        let threshold = currentlyFollowing ? followReleaseThreshold : nearBottomThreshold
        return max(0, remainingDistance) <= threshold
    }

    static func isNearBottom(documentMaxY: CGFloat,
                             visibleMaxY: CGFloat,
                             threshold: CGFloat = nearBottomThreshold) -> Bool {
        guard documentMaxY.isFinite, visibleMaxY.isFinite else { return true }
        return documentMaxY - visibleMaxY <= max(0, threshold)
    }

    /// `NSView` coordinate orientation is not stable across SwiftUI scroll
    /// content: a regular VStack and LazyVStack can expose opposite visual Y
    /// directions. `NSScroller.floatValue` is stable (0 = top, 1 = bottom), so
    /// convert it back to remaining points for a direction-independent check.
    static func isNearBottom(scrollerValue: CGFloat,
                             scrollableDistance: CGFloat,
                             threshold: CGFloat = nearBottomThreshold) -> Bool {
        guard scrollerValue.isFinite, scrollableDistance.isFinite else { return true }
        let distance = max(0, scrollableDistance)
        let normalized = min(1, max(0, scrollerValue))
        return (1 - normalized) * distance <= max(0, threshold)
    }

    /// Infer the full scrollable range from AppKit's scrollbar geometry. This
    /// remains accurate when SwiftUI's document view reports a viewport-sized
    /// `bounds` (seen in the assistant's regular VStack).
    static func scrollableDistance(viewportHeight: CGFloat,
                                   knobProportion: CGFloat,
                                   fallbackDocumentHeight: CGFloat) -> CGFloat {
        let viewport = max(0, viewportHeight)
        let proportion = min(1, max(0, knobProportion))
        if proportion > 0, proportion < 1 {
            return viewport * (1 - proportion) / proportion
        }
        return max(0, fallbackDocumentHeight - viewport)
    }

    static func delayUntilNextScroll(lastScrollAt: TimeInterval?,
                                     now: TimeInterval,
                                     minimumInterval: TimeInterval = answerScrollInterval) -> TimeInterval {
        guard let lastScrollAt else { return 0 }
        return max(0, max(0, minimumInterval) - max(0, now - lastScrollAt))
    }
}

/// macOS 13-compatible scroll-position observer. SwiftUI's modern scroll
/// geometry APIs are newer than our deployment target, so observe the backing
/// NSClipView. Document growth alone does not disable following; an actual
/// reader scroll updates the binding immediately.
struct LiveScrollPositionObserver: NSViewRepresentable {
    @Binding var isNearBottom: Bool
    var threshold: CGFloat = LiveScrollPolicy.nearBottomThreshold

    func makeCoordinator() -> Coordinator {
        Coordinator(isNearBottom: $isNearBottom, threshold: threshold)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onAttach = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.attach(to: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.isNearBottom = $isNearBottom
        context.coordinator.threshold = threshold
        nsView.onAttach = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.attach(to: scrollView)
        }
        if let scrollView = nsView.enclosingScrollView {
            context.coordinator.attach(to: scrollView)
        }
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: NSView {
        var onAttach: ((NSScrollView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onAttach?(self.enclosingScrollView)
            }
        }
    }

    final class Coordinator {
        var isNearBottom: Binding<Bool>
        var threshold: CGFloat
        private weak var scrollView: NSScrollView?
        private weak var clipView: NSClipView?
        private var boundsObserver: NSObjectProtocol?
        private var publishScheduled = false
        private var attachmentGeneration = 0

        init(isNearBottom: Binding<Bool>, threshold: CGFloat) {
            self.isNearBottom = isNearBottom
            self.threshold = threshold
        }

        func attach(to scrollView: NSScrollView?) {
            guard let scrollView else {
                detach()
                return
            }
            let clipView = scrollView.contentView
            guard self.scrollView !== scrollView || self.clipView !== clipView else { return }
            detach()
            attachmentGeneration &+= 1
            self.scrollView = scrollView
            self.clipView = clipView
            clipView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak clipView] _ in
                guard let clipView else { return }
                self?.schedulePublish(for: clipView)
            }
            schedulePublish(for: clipView)
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            // Leave bounds notifications enabled. SwiftUI can briefly overlap
            // old/new representable coordinators for the same clip view; an old
            // coordinator restoring `false` would silently disable the new one.
            // With no observer installed, the notification has no app-side work.
            boundsObserver = nil
            clipView = nil
            scrollView = nil
            publishScheduled = false
            attachmentGeneration &+= 1
        }

        /// AppKit posts `boundsDidChange` before the vertical scroller has
        /// reflected the new clip origin. Coalesce to the next main-queue turn,
        /// validate the exact attachment, then read the updated scroller.
        private func schedulePublish(for clipView: NSClipView) {
            guard self.clipView === clipView, !publishScheduled else { return }
            publishScheduled = true
            let generation = attachmentGeneration
            DispatchQueue.main.async { [weak self, weak clipView] in
                guard let self else { return }
                guard generation == self.attachmentGeneration,
                      let clipView,
                      self.clipView === clipView,
                      let scrollView = self.scrollView,
                      scrollView.contentView === clipView else { return }
                self.publishScheduled = false
                scrollView.reflectScrolledClipView(clipView)
                self.publishPosition()
            }
        }

        private func publishPosition() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let viewportHeight = scrollView.contentView.bounds.height
            let documentHeight = documentView.bounds.height
            let remaining: CGFloat
            if let scroller = scrollView.verticalScroller {
                let scrollableDistance = LiveScrollPolicy.scrollableDistance(
                    viewportHeight: viewportHeight,
                    knobProportion: CGFloat(scroller.knobProportion),
                    fallbackDocumentHeight: documentHeight
                )
                let normalized = min(1, max(0, CGFloat(scroller.floatValue)))
                remaining = (1 - normalized) * max(0, scrollableDistance)
            } else {
                // Defensive fallback for a custom NSScrollView with no
                // scroller. Standard SwiftUI ScrollView always supplies one.
                let visible = scrollView.documentVisibleRect
                remaining = documentView.isFlipped
                    ? documentView.bounds.maxY - visible.maxY
                    : visible.minY - documentView.bounds.minY
            }
            // Hysteresis: releasing follow takes a real reader flick; content
            // growth between scroll ticks must not break it.
            let nearBottom = LiveScrollPolicy.shouldFollow(
                currentlyFollowing: isNearBottom.wrappedValue,
                remainingDistance: remaining)
            if isNearBottom.wrappedValue != nearBottom {
                isNearBottom.wrappedValue = nearBottom
            }
        }
    }
}

struct JumpToLatestButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Последняя", systemImage: "arrow.down")
                .font(Typo.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Space.m)
                .padding(.vertical, 7)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                .softShadow(0.65)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
