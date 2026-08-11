import SwiftUI

/// Stable, distinct colors for diarized speakers. The mic side is always the
/// "You" green; system-side speakers get a palette hue chosen by a
/// deterministic hash of the label — same speaker, same color, every launch
/// (Swift's `hashValue` is seeded per-process, so it can't be used here).
enum SpeakerPalette {
    /// Hues picked to sit comfortably in the warm theme while staying apart.
    private static let colors: [Color] = [
        Theme.speakerThem,        // blue — first remote speaker keeps the classic hue
        Color(hex: 0x7B5AA6),     // violet
        Color(hex: 0x2F7E7A),     // teal
        Color(hex: 0xA34E7C),     // magenta
        Color(hex: 0xB07A2A),     // ochre
        Color(hex: 0x4A5AA8),     // indigo
        Color(hex: 0x8A6A4F),     // umber
        Color(hex: 0x5E7A33),     // olive
    ]

    static func color(for entry: TranscriptEntry) -> Color {
        if entry.source == .mic { return Theme.speakerYou }
        guard let speaker = entry.speaker, !speaker.isEmpty else { return Theme.speakerThem }
        return color(forLabel: speaker)
    }

    static func color(forLabel label: String) -> Color {
        colors[Int(stableHash(label) % UInt64(colors.count))]
    }

    /// FNV-1a — deterministic across launches.
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
