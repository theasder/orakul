import CoreGraphics
import Testing
@testable import MeetGPT

/// The theme and role chips used to share one `HStack`, so a narrow sidebar cut
/// both labels to "Auto · Fundraising / inv…". Wrapping is what replaced that:
/// a chip keeps its full label and moves down a line instead of shrinking.
@Suite("Chip flow wrapping")
struct ChipFlowPackingTests {
    private let spacing: CGFloat = 4

    private func size(_ width: CGFloat, _ height: CGFloat = 20) -> CGSize {
        CGSize(width: width, height: height)
    }

    @Test("chips that fit stay on one line")
    func fitsOnOneLine() {
        let lines = ChipFlowPacking.lines(
            sizes: [size(120), size(90)], maxWidth: 300, spacing: spacing)

        #expect(lines.count == 1)
        #expect(lines[0].indices == [0, 1])
        #expect(lines[0].width == 214)   // 120 + 4 + 90
    }

    @Test("the second chip wraps rather than squeezing the first")
    func wrapsInsteadOfTruncating() {
        let lines = ChipFlowPacking.lines(
            sizes: [size(180), size(140)], maxWidth: 220, spacing: spacing)

        #expect(lines.count == 2)
        #expect(lines[0].indices == [0])
        #expect(lines[1].indices == [1])
    }

    @Test("a chip wider than the panel still gets its own line")
    func oversizeChipKeepsItsLine() {
        // Measured at panel width by the layout, so this is a chip whose label
        // has already wrapped inside the capsule — it must not drag a neighbour
        // onto the same line.
        let lines = ChipFlowPacking.lines(
            sizes: [size(220, 34), size(90)], maxWidth: 220, spacing: spacing)

        #expect(lines.count == 2)
        #expect(lines[0].indices == [0])
        #expect(lines[0].height == 34)
        #expect(lines[1].indices == [1])
    }

    @Test("line height follows the tallest chip on it")
    func lineHeightIsTheTallestChip() {
        let lines = ChipFlowPacking.lines(
            sizes: [size(60, 20), size(60, 34)], maxWidth: 300, spacing: spacing)

        #expect(lines.count == 1)
        #expect(lines[0].height == 34)
    }

    @Test("no chips means no lines")
    func emptyStaysEmpty() {
        #expect(ChipFlowPacking.lines(sizes: [], maxWidth: 300, spacing: spacing).isEmpty)
    }
}
