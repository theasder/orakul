import AppKit
import Foundation
import SwiftUI

/// Renders the transcript into one attributed string for an `NSTextView`, and
/// keeps an index from character ranges back to the entries that produced them.
///
/// The index is the reason this exists. Real text selection gives back a
/// character range and nothing else; without a map from range to entry, a
/// selection cannot be attributed to a speaker or a timestamp, and the quote
/// pasted into the composer would be anonymous text the model cannot place.
enum TranscriptTextRenderer {

    /// Where one entry's body text lives in the rendered string.
    struct Segment: Equatable {
        let entryID: UUID
        /// Range of the body text only — the gutter and speaker label are
        /// excluded so a selection maps to what was actually said.
        let bodyRange: NSRange
        let speaker: String?
        let timestamp: Date
        let text: String
    }

    struct Rendered {
        let attributed: NSAttributedString
        let segments: [Segment]
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Display label for an entry. Local capture tracks are deliberately
    /// anonymous unless a real diarizer supplied a speaker.
    static func label(for entry: TranscriptEntry) -> String? {
        entry.attributionLabel
    }

    /// Consecutive lines from one speaker within this gap share a gutter AND
    /// flow as one paragraph. Live streaming finalizes an utterance every few
    /// seconds, so a minute of one person talking used to render a stack of
    /// identical "HH:mm:ss Speaker A" labels — and after the labels were
    /// coalesced, a stack of one-sentence paragraphs ("phrases by paragraph").
    /// A reader wants the page of a book: one paragraph per speaking turn, a
    /// new one when the voice changes or the pause is long enough that the
    /// timestamp is doing real work again.
    static let coalesceGap: TimeInterval = 90

    /// A short entry whose words are already present in an adjacent entry on
    /// the OTHER capture track is the room's echo, not speech: the mic hears
    /// the speakers, so "вернется" lands on the mic track one second after the
    /// meeting said "вернет". Measured on a real 924-entry call: 412 of 923
    /// block breaks were mic↔system flips at 0–4 s gaps, and this rule removes
    /// 119 echo crumbs and a third of the false paragraph breaks while keeping
    /// every substantial interjection. Cross-track evidence is required — a
    /// short line between SAME-track neighbours is real speech and stays.
    static func isCrossTrackEcho(_ entry: TranscriptEntry,
                                 previous: TranscriptEntry?,
                                 next: TranscriptEntry?) -> Bool {
        let words = echoTokens(entry.text)
        guard !words.isEmpty, words.count <= 6 else { return false }
        var context: [String] = []
        var crossTrack = false
        if let previous {
            context += echoTokens(previous.text).suffix(20)
            if previous.source != entry.source { crossTrack = true }
        }
        if let next {
            context += echoTokens(next.text).prefix(20)
            if next.source != entry.source { crossTrack = true }
        }
        guard crossTrack, !context.isEmpty else { return false }
        // Prefix matching, not equality: inflected languages echo "вернет"
        // as "вернется", and exact tokens would call that real speech.
        let matched = words.filter { word in
            word.count < 4
                ? context.contains(word)
                : context.contains { $0.count >= 4 && $0.prefix(4) == word.prefix(4) }
        }
        return Double(matched.count) / Double(words.count) >= 0.6
    }

    private static func echoTokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func render(entries allEntries: [TranscriptEntry],
                       provisional: [ProvisionalLine],
                       appearance: NSAppearance?) -> Rendered {
        // Echo crumbs are dropped from the RENDER only: exports, persistence
        // and the AI's context keep every entry, so nothing said is lost —
        // the reader just stops seeing the room's reverb as a speaker turn.
        let entries = allEntries.indices.compactMap { index -> TranscriptEntry? in
            let entry = allEntries[index]
            let previous = index > 0 ? allEntries[index - 1] : nil
            let next = index + 1 < allEntries.count ? allEntries[index + 1] : nil
            return isCrossTrackEcho(entry, previous: previous, next: next) ? nil : entry
        }
        let output = NSMutableAttributedString()
        var segments: [Segment] = []

        let inkColor = resolve(Theme.ink, appearance: appearance)
        let tertiary = resolve(Theme.inkTertiary, appearance: appearance)

        var previous: TranscriptEntry?
        for entry in entries {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2.5
            paragraph.paragraphSpacing = 10

            let label = label(for: entry)
            let accent = resolve(SpeakerPalette.color(for: entry), appearance: appearance)

            // Same voice continuing? Extend the block instead of re-stamping
            // the gutter. The segment index below still records every entry
            // separately, so selection and quoting lose nothing.
            let continues: Bool = previous.map {
                self.label(for: $0) == label
                    && $0.source == entry.source
                    && entry.timestamp.timeIntervalSince($0.timestamp) <= coalesceGap
            } ?? false

            if !continues {
                // Close the previous block's paragraph, then a blank line
                // between blocks; none inside one.
                if previous != nil { output.append(NSAttributedString(string: "\n\n")) }
                // Gutter: timestamp + speaker, styled so it reads as metadata
                // and never as something the person said.
                let timestamp = timeFormatter.string(from: entry.timestamp)
                let heading = label.map { "\(timestamp)  \($0)" } ?? timestamp
                let head = NSAttributedString(
                    string: heading + "\n",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: accent,
                        .paragraphStyle: paragraph
                    ])
                output.append(head)
            } else {
                // Book-dialog joiner: the same voice keeps ONE flowing
                // paragraph. A six-second streaming boundary is a fact about
                // the transcriber, not a paragraph break the reader should see.
                output.append(NSAttributedString(
                    string: " ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: inkColor,
                        .paragraphStyle: paragraph
                    ]))
            }

            let bodyStart = output.length
            let body = NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: inkColor,
                    .paragraphStyle: paragraph
                ])
            output.append(body)
            segments.append(Segment(
                entryID: entry.id,
                bodyRange: NSRange(location: bodyStart, length: body.length),
                speaker: label,
                timestamp: entry.timestamp,
                text: entry.text))

            previous = entry
        }
        if previous != nil { output.append(NSAttributedString(string: "\n\n")) }

        // In-progress speech, dimmed. Not indexed: it has no stable id yet and
        // will be replaced by a finalized entry, so quoting it would cite text
        // that is about to change.
        for line in provisional {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2.5
            paragraph.paragraphSpacing = 10
            output.append(NSAttributedString(
                string: line.text + "\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: tertiary,
                    .paragraphStyle: paragraph
                ]))
        }

        return Rendered(attributed: output, segments: segments)
    }

    /// Entries a character range touches, in transcript order. A range that
    /// clips one word of a line still counts that line — the user selected part
    /// of it, and attribution needs the whole utterance's speaker.
    static func segments(in range: NSRange, of segments: [Segment]) -> [Segment] {
        guard range.length > 0 else { return [] }
        return segments.filter { NSIntersectionRange($0.bodyRange, range).length > 0 }
    }

    /// The quote for a selection: exactly the selected characters, per line,
    /// attributed. Partial lines are quoted partially — quoting the whole line
    /// when the user highlighted six words puts words in their mouth.
    static func quote(for range: NSRange,
                      in segments: [Segment],
                      fullText: String) -> String {
        let touched = self.segments(in: range, of: segments)
        guard !touched.isEmpty else { return "" }
        let nsText = fullText as NSString

        return touched.map { segment in
            let overlap = NSIntersectionRange(segment.bodyRange, range)
            let spoken = overlap.length > 0 ? nsText.substring(with: overlap) : segment.text
            let time = timeFormatter.string(from: segment.timestamp)
            let attribution = segment.speaker.map { " \($0):" } ?? ""
            return "[\(time)]\(attribution) \(spoken.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        .joined(separator: "\n")
    }

    /// Resolve a dynamic SwiftUI color for the text view's current appearance.
    /// NSTextView takes concrete NSColors, so a dynamic color would otherwise
    /// bake whichever appearance happened to be active at render time.
    private static func resolve(_ color: SwiftUI.Color, appearance: NSAppearance?) -> NSColor {
        let nsColor = NSColor(color)
        guard let appearance else { return nsColor }
        var resolved = nsColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = nsColor.usingColorSpace(.sRGB) ?? nsColor
        }
        return resolved
    }
}
