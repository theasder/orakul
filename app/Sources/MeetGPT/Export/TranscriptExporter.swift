import Foundation

/// Renders a recorded transcript to a plain-text file for download.
/// Pure + deterministic so the formatting is unit-testable without any UI.
enum TranscriptExporter {
    /// One timestamped line per entry under a small header naming the meeting
    /// and date. Private on-device lines stay anonymous unless a diarizer
    /// supplied a real speaker label.
    static func plainText(title: String,
                          date: Date,
                          entries: [TranscriptEntry],
                          timeZone: TimeZone = .current) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm:ss"

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            cleanTitle.isEmpty ? "Meeting transcript" : cleanTitle,
            day.string(from: date),
            "",
        ]
        for entry in entries {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let timestamp = clock.string(from: entry.timestamp)
            if let speaker = entry.attributionLabel {
                lines.append("\(timestamp)  \(speaker): \(text)")
            } else {
                lines.append("\(timestamp)  \(text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A filesystem-safe `.txt` name derived from the meeting title + date.
    static func suggestedFilename(title: String, date: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"

        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = base.isEmpty ? "transcript" : base
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = slug.unicodeScalars
            .map { forbidden.contains($0) || $0 == " " ? "-" : String($0) }
            .joined()
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let stem = safe.isEmpty ? "transcript" : safe
        return "\(stem)-\(day.string(from: date)).txt"
    }
}
