import Foundation
import FluidAudio

/// Live captions on Parakeet TDT v3, for the languages it serves well.
///
/// Measured on real Russian work calls (2026-08-09): Parakeet tracked the
/// independent cloud engine twice as closely as Whisper large on Russian
/// prose (mean disagreement 0.135 against 0.255) and ran five to eight times
/// faster — but it transliterates embedded English tech vocabulary
/// ("finalizeDecision" became "паналайз") where Whisper renders it verbatim.
/// So this engine takes the LIVE captions only, where speed and prose win;
/// the post-call whole-file pass stays on Whisper for terms and punctuation.
/// `retranscribeSessionLocally` constructs its Whisper service directly, so
/// nothing here can leak into the final transcript.
///
/// Experimental: off by default (`Config.parakeetLiveEnabled`), and served
/// only when the user has EXPLICITLY picked a supported language — "multi"
/// keeps Whisper, because auto-detected Hindi or Mandarin would land on a
/// model that cannot hear them.
final class ParakeetLiveTranscription: TranscriptionService {

    /// Parakeet TDT v3 coverage: the 25 European languages of its training
    /// set. Deliberately conservative — a language missing here falls back to
    /// Whisper, which costs latency, not correctness.
    static let supportedLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el",
        "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es",
        "sv", "ru", "uk",
    ]

    static func shouldServe(language: String,
                            enabled: Bool = Config.parakeetLiveEnabled) -> Bool {
        enabled && supportedLanguages.contains(
            language.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private let language: String

    init(language: String) {
        self.language = language
    }

    func transcribe(wav: Data) async throws -> String {
        try await transcribe(wav: wav, streamID: nil)
    }

    func transcribe(wav: Data, streamID: String?) async throws -> String {
        let samples = LocalWhisperTranscription.floatSamples(fromWAV: wav)
        guard !samples.isEmpty else { return "" }
        return try await ParakeetRuntime.shared.transcribe(samples: samples,
                                                           streamID: streamID,
                                                           language: language)
    }
}

/// One model in memory, loaded on first use. The v3 download is ~600 MB, so
/// it happens lazily behind the experimental flag rather than at launch —
/// and inside the actor, so a burst of first chunks cannot race two loads.
///
/// The TDT decoder is STATEFUL: `TdtDecoderState` carries linguistic context
/// across chunk boundaries, per stream, so the mic and the meeting each keep
/// their own thread of context — the same mechanism that lets Meetily stream
/// without overlap decoding or seam stitching.
actor ParakeetRuntime {
    static let shared = ParakeetRuntime()

    private var manager: AsrManager?
    private var states: [String: TdtDecoderState] = [:]

    /// Old calls leave their stream states behind; past this many, start over
    /// rather than grow forever. Losing cross-chunk context once in a long
    /// session costs one seam, not a transcript.
    private static let maximumTrackedStreams = 16

    func transcribe(samples: [Float], streamID: String?, language: String) async throws -> String {
        let manager = try await loadedManager()
        if states.count > Self.maximumTrackedStreams { states.removeAll() }
        let key = streamID ?? "default"
        var state = try states[key] ?? TdtDecoderState()
        // NO language hint, measured (2026-08-10, real Russian IT call): the
        // script-aware filter biases decoding toward the language's own
        // script, which is exactly wrong for code-switched work speech — with
        // the "ru" hint even "LLM" and "decision" came back Cyrillic ("ЛЛМ",
        // "десин") where the unhinted decode kept them Latin. A work call in
        // any of these languages is bilingual by nature; the decoder must be
        // free to write both scripts.
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        states[key] = state
        return result.text
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let fresh = AsrManager(config: .default)
        try await fresh.loadModels(models)
        manager = fresh
        return fresh
    }
}
