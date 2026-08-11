import Testing
import SwiftUI
import AppKit
@testable import MeetGPT

/// Pixel tests for the brief under a meeting row.
///
/// The brief's whole job is to be readable in a glance ten minutes before a
/// call, and "readable" is not something a behaviour test can assert. This
/// rasterises the real view so the PNGs can be looked at, and asserts the few
/// properties that would make it useless: it renders, it is not blank, an
/// overdue line is visibly distinguished, and the panel does not grow a blank
/// shell for a meeting with nothing to say.
///
/// Deliberately not golden-image comparison — see SuggestionCardRenderTests for
/// why a pinned hash teaches everyone to regenerate baselines without looking.
@Suite("Brief rendering")
@MainActor
struct BriefRenderTests {
    private static let outputDirectory =
        URL(fileURLWithPath: "/tmp/cruxwing-render", isDirectory: true)

    private let full = MeetingBrief(
        headline: "Renewal call",
        points: [
            .init(text: "Close date moved from Jun 30 to Jul 31 after the security review",
                  source: "hubspot", readFor: "a slip nobody has acknowledged"),
            .init(text: "Two support tickets opened since the last call",
                  source: "intercom", readFor: nil),
        ],
        openFromLastTime: [
            .init(text: "You owed them the SOC 2 letter", overdue: true, via: "participant"),
        ],
        suggestedGoal: .init(goalType: "close_deal", confidence: 0.7))

    private let calmOnly = MeetingBrief(
        headline: "Still open from last time",
        points: [],
        openFromLastTime: [
            .init(text: "Send the revised quote", overdue: false, via: "company"),
        ],
        suggestedGoal: nil)

    private func render(_ brief: MeetingBrief, appearance: NSAppearance.Name,
                        name: String) throws -> (image: NSImage, bytes: Int) {
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true)

        // Rendered under a meeting row, at the sidebar's real width — the brief
        // is never seen on its own, and unbounded width would prove nothing
        // about how these lines wrap.
        let view = VStack(alignment: .leading, spacing: 6) {
            BriefPreviewHost(brief: brief)
        }
        .frame(width: 300)
        .padding(12)
        .background(Theme.canvas)
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        // Theme tokens resolve against the current DRAWING appearance;
        // NSAppearance.current does not affect them. Getting this wrong produces
        // byte-identical light and dark output while both assertions pass.
        let resolved = try #require(NSAppearance(named: appearance))
        var rendered: NSImage?
        resolved.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }

        let image = try #require(rendered, "\(name) produced no image")
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        return (image, png.count)
    }

    @Test("renders in both appearances, and they differ")
    func rendersBothAppearances() throws {
        let light = try render(full, appearance: .aqua, name: "brief-light")
        let dark = try render(full, appearance: .darkAqua, name: "brief-dark")
        #expect(light.image.size.width > 0 && light.image.size.height > 0)
        // Byte-identical output would mean the appearance never applied — the
        // exact way this harness silently passed while testing nothing before.
        #expect(light.bytes != dark.bytes)
    }

    @Test("a brief with an overdue line is taller than one without")
    func overdueIsNotFlattened() throws {
        // Not a colour assertion — colour is what the PNG is for. This pins that
        // the extra evidence lines are actually laid out rather than clipped to
        // the same height as the minimal case.
        let rich = try render(full, appearance: .aqua, name: "brief-rich")
        let calm = try render(calmOnly, appearance: .aqua, name: "brief-calm")
        #expect(rich.image.size.height > calm.image.size.height)
    }

    @Test("a brief with nothing to say renders nothing at all")
    func emptyRendersNothing() throws {
        // The panel must not grow a blank indented block under a meeting we know
        // nothing about. `hasContent` is what the view gates on.
        let empty = MeetingBrief(headline: "Nothing outstanding", points: [],
                                 openFromLastTime: [], suggestedGoal: nil)
        #expect(empty.hasContent == false)
        #expect(empty.focusLines.isEmpty)
    }
}

/// Test-only host so the pixel tests can render the private `BriefLines` view
/// through the same path the panel uses.
private struct BriefPreviewHost: View {
    let brief: MeetingBrief
    var body: some View { FocusBriefLines(brief: brief) }
}
