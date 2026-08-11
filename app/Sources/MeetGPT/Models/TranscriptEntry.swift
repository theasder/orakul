import Foundation

enum TranscriptSource: String, Codable {
    case system   // remote participants, captured via ScreenCaptureKit
    case mic      // local user, captured via AVAudioEngine
}

/// A provisional (interim) transcript line, shown dimmed until it's finalized.
struct ProvisionalLine: Identifiable {
    let source: TranscriptSource
    let text: String
    var id: String { source.rawValue }
}

struct TranscriptEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let source: TranscriptSource
    let text: String
    let timestamp: Date
    /// Diarized speaker label (e.g. "Speaker A"), when known.
    let speaker: String?
    /// Engine that produced this line. Optional keeps already-saved sessions
    /// decodable. This is entry-level rather than session-level because a live
    /// call can switch engines: only the locally produced lines must suppress
    /// source-based attribution.
    let transcriptionEngine: TranscriptionEngine?

    init(id: UUID = UUID(), source: TranscriptSource, text: String,
         timestamp: Date = Date(), speaker: String? = nil,
         transcriptionEngine: TranscriptionEngine? = nil) {
        self.id = id
        self.source = source
        self.text = text
        self.timestamp = timestamp
        self.speaker = speaker
        self.transcriptionEngine = transcriptionEngine
    }

    /// Speaker text that is safe to present or quote. The private on-device
    /// engine recognizes two capture tracks, not two trustworthy identities:
    /// speaker output can reach both ScreenCaptureKit and the microphone, so
    /// calling those tracks "Them" and "You" invents a speaker turn. A real
    /// diarized label always wins. Older/cloud entries retain the source label.
    var attributionLabel: String? {
        if let named = speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !named.isEmpty {
            return named
        }
        guard transcriptionEngine != .local else { return nil }
        return source == .mic ? "You" : "Them"
    }

    func recordingEngineIfMissing(_ engine: TranscriptionEngine?) -> TranscriptEntry {
        guard transcriptionEngine == nil, let engine else { return self }
        return TranscriptEntry(
            id: id, source: source, text: text, timestamp: timestamp,
            speaker: speaker, transcriptionEngine: engine)
    }
}
