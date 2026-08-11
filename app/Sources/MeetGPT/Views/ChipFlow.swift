import SwiftUI

/// One laid-out line of chips: which chips are on it, and how big it is.
struct ChipFlowLine: Equatable {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
}

/// Where chips break onto the next line — the whole of the layout's arithmetic,
/// kept apart from SwiftUI so it can be tested with plain sizes.
enum ChipFlowPacking {
    static func lines(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> [ChipFlowLine] {
        var lines: [ChipFlowLine] = []
        var line = ChipFlowLine()
        for index in sizes.indices {
            let size = sizes[index]
            let extended = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            // A chip wider than the panel still gets its own line — there is
            // nowhere narrower for it to go.
            if !line.indices.isEmpty, extended > maxWidth {
                lines.append(line)
                line = ChipFlowLine()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// A row of chips that WRAPS rather than shrinks.
///
/// `HStack` divides a narrow panel among its children, so the theme and role
/// chips in the sidebar both ended as "Auto · Fundraising / inv…" — a chip that
/// hides the value it exists to display is worse than a second line. This lays
/// each chip out at its natural width, starts a new line when the next one no
/// longer fits, and only lets a chip wrap internally when it alone is wider
/// than the panel.
struct ChipFlow: Layout {
    var spacing: CGFloat = Space.xs
    var lineSpacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = ChipFlowPacking.lines(sizes: measure(subviews, maxWidth: maxWidth),
                                          maxWidth: maxWidth, spacing: spacing)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in ChipFlowPacking.lines(sizes: sizes, maxWidth: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in line.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// Natural size per chip, re-proposed at panel width for any chip that is
    /// wider than the panel on its own, so its label wraps inside the capsule
    /// instead of overflowing the sidebar.
    private func measure(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let natural = subview.sizeThatFits(.unspecified)
            guard natural.width > maxWidth else { return natural }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }
}
