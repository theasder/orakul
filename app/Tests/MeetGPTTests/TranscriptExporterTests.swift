import Foundation
import Testing
@testable import MeetGPT

@Suite("Transcript exporter")
struct TranscriptExporterTests {
    private let tz = TimeZone(identifier: "UTC")!
    private func at(_ hms: (Int, Int, Int)) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day) = (2026, 7, 23)
        (c.hour, c.minute, c.second) = hms
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("renders a header and one timestamped, speaker-labeled line per entry")
    func rendersLines() {
        let entries = [
            TranscriptEntry(source: .mic, text: "Let's start.", timestamp: at((9, 0, 5))),
            TranscriptEntry(source: .system, text: "Sounds good.", timestamp: at((9, 0, 12)),
                            speaker: "Maria"),
        ]
        let out = TranscriptExporter.plainText(title: "Weekly sync",
                                               date: at((9, 0, 0)),
                                               entries: entries, timeZone: tz)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "Weekly sync")
        #expect(lines[1].contains("2026"))
        #expect(lines.contains("09:00:05  Вы: Let's start."))
        // Diarized name wins over the source fallback.
        #expect(lines.contains("09:00:12  Maria: Sounds good."))
    }

    @Test("falls back to You/Them, drops empty lines, and defaults an empty title")
    func fallbacksAndSkips() {
        let entries = [
            TranscriptEntry(source: .system, text: "Remote speaking.", timestamp: at((10, 0, 0))),
            TranscriptEntry(source: .mic, text: "   ", timestamp: at((10, 0, 3))),
        ]
        let out = TranscriptExporter.plainText(title: "  ", date: at((10, 0, 0)),
                                               entries: entries, timeZone: tz)
        #expect(out.hasPrefix("Транскрипт звонка\n"))
        #expect(out.contains("Собеседник: Remote speaking."))
        #expect(!out.contains("10:00:03"))   // whitespace-only entry skipped
    }

    @Test("filename is filesystem-safe and dated")
    func filenameSafety() {
        let name = TranscriptExporter.suggestedFilename(
            title: "Q3: Budget / Review?", date: at((0, 0, 0)))
        #expect(name.hasSuffix("-2026-07-23.txt"))
        for bad in ["/", ":", "?", "\\", " "] {
            #expect(!name.replacingOccurrences(of: ".txt", with: "").contains(bad))
        }
        #expect(TranscriptExporter.suggestedFilename(title: "", date: at((0, 0, 0)))
            == "transcript-2026-07-23.txt")
    }
}
