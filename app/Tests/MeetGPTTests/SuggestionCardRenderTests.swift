import Testing
import SwiftUI
import AppKit
@testable import MeetGPT

/// Pixel tests for the blind-spot cards.
///
/// Every other test in this suite asserts behaviour, and a card's job is how it
/// READS — which behaviour cannot express. `ImageRenderer` rasterises the real
/// view (macOS 13+, the app's floor) so the output can be inspected without
/// launching the app, and the PNGs land in a directory a human or an agent can
/// open afterwards.
///
/// Deliberately NOT golden-image comparison. Pinning a hash would fail on every
/// font-metric change across OS versions and teach everyone to regenerate the
/// baseline without looking, which is worse than no test. These assert the
/// properties that actually matter — it renders, it is not blank, a hunch is
/// visibly taller than the observation it would otherwise have been flattened
/// into — and leave the image for eyes.
@Suite("Suggestion card rendering")
@MainActor
struct SuggestionCardRenderTests {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/cruxwing-render", isDirectory: true)

    private let hunch = Suggestion(
        title: "Procurement is the real blocker",
        detail: "Legal named twice, budget never.",
        kind: .hypothesis,
        evidence: "Legal still needs to look at the liability cap",
        claim: "They will stall at procurement, not on price",
        cheapTest: "Ask who signs once legal clears it, rather than what it costs",
        costOfMissing: "A discount given to solve a problem that was never price")

    private let risk = Suggestion(
        title: "Loud accounts are not the market",
        detail: "Three enterprise mentions stood in for demand.",
        kind: .risk,
        evidence: "Three of the four enterprise accounts brought it up")

    /// Render one card at the sidebar's real width and write it out.
    private func render(_ suggestion: Suggestion, appearance: NSAppearance.Name,
                        name: String) throws -> (image: NSImage, bytes: Int) {
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true)

        // The card is width-constrained by the sidebar; rendering it unbounded
        // would produce a single long line and prove nothing about wrapping.
        let view = SuggestionCard(suggestion: suggestion, onAsk: {}, onDismiss: {})
            .frame(width: 300)
            .padding(12)
            .background(Theme.canvas)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        // Theme tokens come from `NSColor(name:dynamicProvider:)`, which resolves
        // against the current DRAWING appearance. Setting `NSAppearance.current`
        // does not affect it — the first version of this harness did exactly that
        // and produced byte-identical light and dark PNGs while both assertions
        // passed, so the dark-mode test was checking nothing at all.
        let resolved = try #require(NSAppearance(named: appearance))
        var rendered: NSImage?
        resolved.performAsCurrentDrawingAppearance {
            rendered = renderer.nsImage
        }

        let image = try #require(rendered, "\(name) produced no image")
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        return (image, png.count)
    }

    @Test("a hunch card renders in both appearances, and is not blank")
    func hunchRenders() throws {
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"),
                                    (NSAppearance.Name.darkAqua, "dark")] {
            let (image, bytes) = try render(hunch, appearance: appearance, name: "hunch-\(label)")
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
            // A blank or single-colour PNG compresses to almost nothing; real text
            // and a tinted panel do not.
            #expect(bytes > 3_000, "hunch-\(label) looks blank at \(bytes) bytes")
        }
    }

    @Test("light and dark actually differ — the appearance is really applied")
    func appearancesDiffer() throws {
        // The guard against the harness bug this suite already had once: if the
        // drawing appearance is not applied, both variants rasterise identically
        // and every dark-mode assertion above passes without testing dark mode.
        let light = try pngData(hunch, appearance: .aqua, name: "diff-light")
        let dark = try pngData(hunch, appearance: .darkAqua, name: "diff-dark")
        #expect(light != dark, "light and dark rendered identically — the appearance is not being applied")
    }

    private func pngData(_ suggestion: Suggestion, appearance: NSAppearance.Name,
                         name: String) throws -> Data {
        _ = try render(suggestion, appearance: appearance, name: name)
        return try Data(contentsOf: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    @Test("a hunch is visibly taller than the observation it used to be flattened into")
    func hunchIsTallerThanRisk() throws {
        // The regression this guards: before the kind existed, a hypothesis was
        // mapped to .advice and rendered as an ordinary card, losing the claim,
        // the test and the cost. If the extra block ever stops rendering, the
        // heights converge and this fails.
        let hunchImage = try render(hunch, appearance: .aqua, name: "compare-hunch").image
        let riskImage = try render(risk, appearance: .aqua, name: "compare-risk").image
        #expect(hunchImage.size.height > riskImage.size.height + 20,
                "hunch \(hunchImage.size.height) vs risk \(riskImage.size.height) — the claim/test block is missing")
    }

    @Test("an untestable hunch renders as a plain card, with no empty panel")
    func untestableRendersPlain() throws {
        // Demoted server-side and client-side, so it should be indistinguishable
        // from any other advice card — crucially NOT a card with a heading and an
        // empty box under it.
        let demoted = Suggestion(
            title: "Procurement may be the blocker", detail: "Legal named twice.",
            kind: .advice, evidence: "Legal still needs to look at the liability cap")
        let plain = try render(demoted, appearance: .aqua, name: "demoted-advice").image
        let full = try render(hunch, appearance: .aqua, name: "compare-hunch-2").image
        #expect(plain.size.height < full.size.height)
    }

    @Test("long text wraps instead of clipping the card")
    func longTextWraps() throws {
        // A sidebar card cannot scroll horizontally; an over-long test has to grow
        // the card downward or it silently loses the end of the sentence.
        let verbose = Suggestion(
            title: "Procurement is the real blocker", detail: "d", kind: .hypothesis,
            evidence: "Legal still needs to look at the liability cap",
            claim: String(repeating: "They will stall at procurement rather than on price. ", count: 3),
            cheapTest: String(repeating: "Ask precisely who signs this once legal has cleared it. ", count: 3),
            costOfMissing: "A needless discount")
        let short = try render(hunch, appearance: .aqua, name: "wrap-short").image
        let long = try render(verbose, appearance: .aqua, name: "wrap-long").image
        #expect(long.size.height > short.size.height, "long text did not grow the card — it is being clipped")
        #expect(long.size.width == short.size.width, "the card widened instead of wrapping")
    }

    @Test("every kind renders, so no case produces a broken card")
    func allKindsRender() throws {
        for kind in [SuggestionKind.question, .risk, .missingInfo, .advice, .hypothesis] {
            let suggestion = Suggestion(
                title: "Title for \(kind.label)", detail: "Detail line.", kind: kind,
                evidence: "Legal still needs to look at the liability cap",
                claim: kind == .hypothesis ? "A claim" : nil,
                cheapTest: kind == .hypothesis ? "Ask who signs this document" : nil)
            let (_, bytes) = try render(suggestion, appearance: .aqua, name: "kind-\(kind.rawValue)")
            #expect(bytes > 2_000, "\(kind) rendered near-blank at \(bytes) bytes")
        }
    }
}

/// Quotes are withheld while recognition is struggling: a mangled quote makes a
/// correct finding look wrong and teaches the user to distrust the panel.
@Suite("Speech quality gating")
@MainActor
struct SpeechQualityGateTests {
    private let suggestion = Suggestion(
        title: "Loud accounts are not the market", detail: "Three mentions stood in for demand.",
        kind: .risk, evidence: "Three of the four enterprise accounts brought it up")

    @Test("hiding the quote shortens the card but keeps the finding")
    func hidingQuoteShrinksCard() throws {
        let shown = SuggestionCard(suggestion: suggestion, onAsk: {}, onDismiss: {},
                                  hideEvidence: false)
        let hidden = SuggestionCard(suggestion: suggestion, onAsk: {}, onDismiss: {},
                                   hideEvidence: true)
        func height(_ card: SuggestionCard) throws -> CGFloat {
            let renderer = ImageRenderer(content: card.frame(width: 300).padding(12))
            renderer.scale = 2
            return try #require(renderer.nsImage).size.height
        }
        let withQuote = try height(shown)
        let without = try height(hidden)
        #expect(without < withQuote, "the quote was not actually removed")
        // The finding itself must survive — this suppresses evidence, not content.
        #expect(without > 40)
    }

    @Test("a monitor with too small a sample assumes the audio is fine")
    func smallSampleAssumesFine() {
        // A fresh call must show quotes immediately rather than withholding them
        // until it has proof of success.
        let monitor = SpeechQualityMonitor(windowSize: 40, minimumSample: 12)
        for _ in 0..<5 { monitor.record(accepted: false) }
        #expect(monitor.rejectRate == nil)
        #expect(monitor.isPoor == false)
    }

    @Test("a high reject rate reads as poor")
    func highRejectRateIsPoor() {
        let monitor = SpeechQualityMonitor(windowSize: 40, minimumSample: 10, poorRejectRate: 0.4)
        for _ in 0..<8 { monitor.record(accepted: false) }
        for _ in 0..<4 { monitor.record(accepted: true) }
        #expect(monitor.isPoor)
    }

    @Test("occasional rejects on clean audio are not poor")
    func occasionalRejectsAreFine() {
        // Whisper discards the odd segment on good audio too; the threshold has to
        // sit clear of normal operation or quotes vanish on every call.
        let monitor = SpeechQualityMonitor(windowSize: 40, minimumSample: 10, poorRejectRate: 0.4)
        for _ in 0..<2 { monitor.record(accepted: false) }
        for _ in 0..<18 { monitor.record(accepted: true) }
        #expect(monitor.isPoor == false)
    }

    @Test("the window forgets — quality recovers within a call")
    func windowMovesOn() {
        let monitor = SpeechQualityMonitor(windowSize: 10, minimumSample: 5, poorRejectRate: 0.4)
        for _ in 0..<10 { monitor.record(accepted: false) }
        #expect(monitor.isPoor)
        for _ in 0..<10 { monitor.record(accepted: true) }
        #expect(monitor.isPoor == false, "a fixed window must let a call recover")
    }

    @Test("reset clears the previous call's room")
    func resetClears() {
        let monitor = SpeechQualityMonitor(windowSize: 40, minimumSample: 5)
        for _ in 0..<20 { monitor.record(accepted: false) }
        #expect(monitor.isPoor)
        monitor.reset()
        #expect(monitor.rejectRate == nil)
        #expect(monitor.isPoor == false)
    }
}
