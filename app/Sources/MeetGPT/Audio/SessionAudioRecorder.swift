import Foundation

/// Accumulates the full session's mono-16k samples so the recording can be
/// diarized at stop. Thread-safe; capped to bound memory on long meetings.
final class SessionAudioRecorder {
    private let sampleRate = 16_000
    private let cap: Int
    private var samples: [Int16] = []
    private let lock = NSLock()

    /// Default cap ≈ 60 minutes at 16 kHz mono (~115 MB).
    init(maxMinutes: Int = 60) {
        self.cap = 16_000 * 60 * maxMinutes
    }

    func append(_ batch: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        let room = cap - samples.count
        guard room > 0 else { return }
        samples.append(contentsOf: batch.prefix(room))
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: false)
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return samples.isEmpty
    }

    /// Snapshot the accumulated audio as a PCM-16 WAV.
    func makeWAV() -> Data {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return Data() }
        return WAVEncoder.encode(samples: snapshot, sampleRate: sampleRate)
    }
}
