import SwiftUI

// MARK: - Surfaces

/// A raised paper card: warm fill, soft hairline, gentle continuous corners.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Space.l
    var radius: CGFloat = Radius.m
    var fill: Color = Theme.surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = Space.l, radius: CGFloat = Radius.m, fill: Color = Theme.surface) -> some View {
        modifier(CardModifier(padding: padding, radius: radius, fill: fill))
    }

    /// A low, warm shadow for floating elements (the record pill, toasts).
    func softShadow(_ strength: Double = 1) -> some View {
        shadow(color: Color(hex: 0x2A2419, alpha: 0.10 * strength), radius: 14 * strength, x: 0, y: 5 * strength)
    }
}

/// A thin warm rule. Use instead of the default `Divider` for control.
struct Hairline: View {
    var vertical = false
    var strong = false
    var body: some View {
        Rectangle()
            .fill(strong ? Theme.hairlineStrong : Theme.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Small-caps tracked section label, e.g. "TRANSCRIPT".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Typo.label)
            .tracking(0.9)
            .foregroundStyle(Theme.inkTertiary)
    }
}

// MARK: - Button styles

/// Primary clay pill — the single loud action surface.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }

    private struct StyleBody: View {
        let configuration: PrimaryButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Typo.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.l)
                .padding(.vertical, 9)
                .background(Capsule().fill(hovering ? Theme.accentHover : Theme.accent))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: configuration.isPressed)
        }
    }
}

/// Quiet button — text/icon that warms on hover. For secondary actions.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, prominent: prominent)
    }

    private struct StyleBody: View {
        let configuration: QuietButtonStyle.Configuration
        let prominent: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Typo.callout.weight(.medium))
                .foregroundStyle(prominent ? Theme.accentText : Theme.inkSecondary)
                .padding(.horizontal, Space.m)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(hovering ? Theme.surfaceHover : .clear)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: Radius.s))
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// Compact circular icon button (settings gear, copy, remove).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration, size: size) }

    private struct StyleBody: View {
        let configuration: IconButtonStyle.Configuration
        let size: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(hovering ? Theme.ink : Theme.inkSecondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(hovering ? Theme.surfaceHover : .clear)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
        }
    }
}

// MARK: - Status dot

/// A colored live-status dot. Its halo is intentionally static: a permanent
/// animation here keeps SwiftUI rendering even while the user is trying to
/// scroll a transcript or streamed answer.
struct StatusDot: View {
    var color: Color
    var live: Bool = false
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            if live {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: size * 1.9, height: size * 1.9)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Level meter

/// Five thin bars that rise with the live mic level. Decorative-honest:
/// driven by real RMS from `AudioMeterState.level`, falls flat when idle.
struct LevelMeter: View {
    var level: CGFloat        // 0...1
    var active: Bool
    var tint: Color = Theme.recordRed

    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? tint : Theme.inkTertiary.opacity(0.5))
                    .frame(width: 2.5, height: 17)
                    .scaleEffect(x: 1, y: scale(i), anchor: .center)
            }
        }
        .frame(height: 18)
    }

    private func scale(_ i: Int) -> CGFloat {
        let base: CGFloat = 3.5
        let peak: CGFloat = 17
        guard active else { return base / peak }
        let v = min(1, level * weights[i] * 1.5)
        return (base + (peak - base) * v) / peak
    }
}

// MARK: - Flow layout

/// Wrapping flow layout (macOS 13 `Layout`). Used for the prompt chip cloud —
/// an intentional, grid-breaking composition rather than a uniform card grid.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s
    var lineSpacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        let resolvedWidth = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: resolvedWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Live affordances

/// A solid caret appended to streaming text. Avoiding a permanent animation
/// keeps answer scrolling responsive on machines already busy transcribing.
struct TypingCaret: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 2, height: 15)
    }
}

/// Three static graduated dots used as a listening / thinking affordance.
struct BreathingDots: View {
    var tint: Color = Theme.inkTertiary

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(tint)
                    .frame(width: 4, height: 4)
                    .opacity(1 - Double(i) * 0.25)
            }
        }
    }
}

/// A timer label that observes only the lightweight recording clock, keeping
/// its once-per-second invalidation out of the main application model.
struct RecordingElapsedLabel: View {
    @ObservedObject var clock: RecordingClockState

    var body: some View {
        Text(formatElapsed(clock.elapsed))
            .monospacedDigit()
    }
}
