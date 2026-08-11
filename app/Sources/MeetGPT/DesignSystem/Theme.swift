import AppKit
import SwiftUI

// MARK: - Color hex convenience

extension Color {
    /// Build an sRGB color from a 0xRRGGBB literal. Keeps the palette readable.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Palette

/// A color that resolves to `light` or `dark` for the current appearance, so
/// the whole palette flips when the app's effective appearance changes
/// (driven by `AppearanceController` / the Settings theme switcher).
private func dyn(_ light: Color, _ dark: Color) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(isDark ? dark : light)
    })
}

/// Warm, paper-based palette — Granola's editorial calm in light; a warm,
/// low-glare charcoal in dark (not a flat developer-tool grey). Each token
/// carries both variants and resolves per appearance.
enum Theme {
    // Surfaces — neon-noir dark, matching the landing (true black #050409 +
    // violet-ink raises); a cool near-white light variant carrying the same
    // violet accent.
    static let canvas        = dyn(Color(hex: 0xF6F5FB), Color(hex: 0x050409)) // app background, the "desk"
    static let sidebar       = dyn(Color(hex: 0xEEEDF6), Color(hex: 0x08070E)) // left rail, slightly deeper
    static let surface       = dyn(Color(hex: 0xFFFFFF), Color(hex: 0x0F0C1A)) // raised cards / fields
    static let surfaceHover  = dyn(Color(hex: 0xF0EEF8), Color(hex: 0x17121F)) // hover fill on quiet controls
    static let surfaceSunken = dyn(Color(hex: 0xEAE8F3), Color(hex: 0x030308)) // inset wells (notes, empty)

    // Ink (cool near-black → muted → faint  |  landing off-white → muted). All
    // meet WCAG AA for body/label text on their surfaces in both appearances.
    static let ink           = dyn(Color(hex: 0x18151F), Color(hex: 0xEDEAF6))
    static let inkSecondary  = dyn(Color(hex: 0x5E5772), Color(hex: 0xADA6C6))
    static let inkTertiary   = dyn(Color(hex: 0x6E6683), Color(hex: 0x857EA0))

    // Hairlines (dark ink at low alpha in light; white / violet at low alpha in dark)
    static let hairline       = dyn(Color(hex: 0x191626, alpha: 0.08), Color(hex: 0xFFFFFF, alpha: 0.09))
    static let hairlineStrong = dyn(Color(hex: 0x191626, alpha: 0.14), Color(hex: 0x9678EB, alpha: 0.24))

    // Accent — the landing's electric violet (brightened in dark). `accent` is
    // the brand fill (white text on it clears AA); `accentText` is a tuned shade
    // for accent-colored TEXT on the surfaces.
    static let accent        = dyn(Color(hex: 0x7C4DD8), Color(hex: 0x9A6BFF))
    static let accentHover   = dyn(Color(hex: 0x6C3ECF), Color(hex: 0xAE86FF))
    static let accentText    = dyn(Color(hex: 0x6A3BCF), Color(hex: 0xB79BFF))
    static let accentSoft    = dyn(Color(hex: 0x7C4DD8, alpha: 0.12), Color(hex: 0x9A6BFF, alpha: 0.22))
    static let accentTint    = dyn(Color(hex: 0x7C4DD8, alpha: 0.06), Color(hex: 0x9A6BFF, alpha: 0.12))

    // Semantic — aligned to the landing's neon vocabulary (violet / cyan /
    // magenta), brightened in dark to hold contrast on true black.
    static let recordRed     = dyn(Color(hex: 0xCB4734), Color(hex: 0xF05A6A)) // live recording (glyphs/dots)
    static let speakerThem   = dyn(Color(hex: 0x2E90C6), Color(hex: 0x4FBBEA)) // system audio (remote) = cyan
    static let speakerYou    = dyn(Color(hex: 0xB23DA0), Color(hex: 0xD24BC0)) // microphone (you) = magenta
    static let amber         = dyn(Color(hex: 0xC5860E), Color(hex: 0xF5A623)) // starting / transitional
    static let danger        = dyn(Color(hex: 0xB5482F), Color(hex: 0xF06A85))
    static let dangerSoft    = dyn(Color(hex: 0xB5482F, alpha: 0.10), Color(hex: 0xF06A85, alpha: 0.18))
}

// MARK: - Typography

/// A deliberate scale. Headings use the rounded system design for warmth;
/// body uses the default system face; timestamps use monospaced digits.
enum Typo {
    static let displayL  = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let title     = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let headline  = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let bodyStrong = Font.system(size: 14, weight: .semibold)
    static let body      = Font.system(size: 14, weight: .regular)
    static let reading   = Font.system(size: 15, weight: .regular) // transcript / AI prose
    static let callout   = Font.system(size: 13, weight: .regular)
    static let label     = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let caption   = Font.system(size: 11, weight: .regular)
    /// Readable CONTENT in the left column — a blind spot's detail, its quoted
    /// evidence, a hunch's claim and test.
    ///
    /// The sidebar was almost entirely `caption` (11pt) while the transcript and
    /// assistant panes read at `reading` (15pt), so the substance of a blind spot
    /// was set at metadata size next to prose four points larger. 13pt closes
    /// most of that gap without matching it: the column is ~300pt wide and cards
    /// stack, so 15pt there would wrap hard and push the second card below the
    /// fold. True metadata — section headers, counts, status lines — stays
    /// `caption`, which is what it is for.
    static let sidebarBody = Font.system(size: 13, weight: .regular)
    /// `reading`, scaled by the user's reading-size preference. Only the two
    /// long-form surfaces use this; chrome keeps the fixed sizes above so a
    /// large setting cannot collide the controls.
    static func reading(scale: Double) -> Font {
        Font.system(size: ReadingTextScale.pointSize(base: 15, scale: scale), weight: .regular)
    }

    static let mono      = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let monoL     = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let monoS     = Font.system(size: 10, weight: .regular, design: .monospaced)
}

// MARK: - Spacing, radii, motion

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat  = 4
    static let s: CGFloat   = 8
    static let m: CGFloat   = 12
    static let l: CGFloat   = 16
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let s: CGFloat    = 7
    static let m: CGFloat    = 11
    static let l: CGFloat    = 16
    static let pill: CGFloat = 999
}

enum Motion {
    static let quick = Animation.easeOut(duration: 0.13)
    static let smooth = Animation.easeInOut(duration: 0.22)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

/// Shared top inset for the sidebar and the content panes (main + studio).
/// History, because this number has flip-flopped: 30 once collided the brand
/// with the traffic lights, the short-window fix raised it to 52, and the
/// owner then unified everything at 16 after checking the real window — the
/// brand row clears the lights horizontally, so the tall clearance was dead
/// space. If a future layout moves the brand back under the lights, raise the
/// SIDEBAR's own padding there; do not grow this shared constant again.
let kContentTopInset: CGFloat = 16

// MARK: - Helpers

/// Format an elapsed interval as `m:ss` (or `h:mm:ss` past an hour).
func formatElapsed(_ t: TimeInterval) -> String {
    let total = Int(t.rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}
