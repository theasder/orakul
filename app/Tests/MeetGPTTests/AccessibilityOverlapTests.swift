import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// Accessibility settings interact, rather than arriving one at a time. These
/// 16 permutations keep the interrupting prompt surface usable when large text,
/// bold legibility, right-to-left layout, and appearance overlap. The live
/// artifact snapshot separately records the read-only OS contrast,
/// reduce-motion, differentiate-without-color, and VoiceOver values.
@MainActor
@Suite("Accessibility feature overlaps")
struct AccessibilityOverlapTests {
    private var pending: PendingClarification {
        PendingClarification(
            prompt: "How should the rollout proceed?",
            images: [],
            questions: [ClarifyingQuestion(
                question: "Which constraint matters most?",
                header: "Priority",
                options: [
                    .init(label: "SLA safety", detail: "Prefer lower operational risk."),
                    .init(label: "Delivery speed", detail: "Prefer the earliest launch."),
                ])])
    }

    @Test("poll controls survive every accessibility overlap")
    func allEnvironmentPermutationsRenderTheCompletePoll() throws {
        var fingerprints: Set<String> = []
        for largeText in [false, true] {
            for rightToLeft in [false, true] {
                for boldText in [false, true] {
                    for dark in [false, true] {
                        let view = ClarificationCard(
                            pending: pending,
                            onResolve: { _ in },
                            onSkip: {})
                            .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .medium)
                            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                            .environment(\.legibilityWeight, boldText ? .bold : nil)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let inspected = try view.inspect()

                        #expect(throws: Never.self) { try inspected.find(text: "BEFORE I ANSWER") }
                        #expect(throws: Never.self) { try inspected.find(text: "Which constraint matters most?") }
                        #expect(throws: Never.self) { try inspected.find(text: "SLA safety") }
                        #expect(throws: Never.self) { try inspected.find(text: "Delivery speed") }
                        #expect(throws: Never.self) { try inspected.find(button: "Answer anyway") }
                        #expect(throws: Never.self) {
                            try inspected.find(button: "Continue without answering")
                        }

                        fingerprints.insert(
                            "large=\(largeText) rtl=\(rightToLeft) bold=\(boldText) dark=\(dark)")
                    }
                }
            }
        }
        #expect(fingerprints.count == 16)
    }
}
