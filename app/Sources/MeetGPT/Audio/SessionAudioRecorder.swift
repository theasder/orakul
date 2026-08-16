import Foundation

/// Accumulates the full session's mono-16k samples so the recording can be
/// diarized at stop. Thread-safe; capped to bound memory on long meetings.
final class SessionAudioRecorder {
    private let sampleRate = 16_000
    private let cap: Int
    private var samples: [Int16] = []
    private var truncated = false
    private var sealed = false
    private var paused = false
    private let lock = NSLock()

    /// Default cap ≈ 60 minutes at 16 kHz mono (~115 MB).
    init(maxMinutes: Int = 60) {
        self.cap = 16_000 * 60 * maxMinutes
    }

    /// Small-cap seam for lifecycle/truncation tests without allocating an
    /// hour of PCM.
    init(maxSamplesForTesting: Int) {
        self.cap = max(0, maxSamplesForTesting)
    }

    func append(_ batch: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        guard !sealed, !paused else { return }
        let room = cap - samples.count
        let accepted = max(0, min(room, batch.count))
        if accepted < batch.count { truncated = true }
        guard accepted > 0 else { return }
        samples.append(contentsOf: batch.prefix(accepted))
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: false)
        truncated = false
        sealed = false
        paused = false
    }

    /// Capture continues while the UI session is paused, but retained audio
    /// must follow the consent-visible active intervals only.
    func pause() {
        lock.lock(); defer { lock.unlock() }
        paused = true
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return }
        paused = false
    }

    /// Freeze retained PCM at Stop. Audio callbacks queued after consent ended
    /// cannot extend a destructive post-call decode.
    func seal() {
        lock.lock(); defer { lock.unlock() }
        sealed = true
    }

    /// Drop old retained audio without reopening a stopped recorder. The next
    /// real recording calls `reset()` after capture starts.
    func discard() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: false)
        truncated = false
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return samples.isEmpty
    }

    var retainedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    var retainedDuration: TimeInterval {
        TimeInterval(retainedSampleCount) / TimeInterval(sampleRate)
    }

    func retainedDuration(from sampleOffset: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let start = max(0, min(sampleOffset, samples.count))
        return TimeInterval(samples.count - start) / TimeInterval(sampleRate)
    }

    var isTruncated: Bool {
        lock.lock(); defer { lock.unlock() }
        return truncated
    }

    /// Immutable PCM snapshot for bounded post-call windows. Keeping the split
    /// outside the lock prevents a long meeting from blocking the audio tap.
    func sampleSnapshot() -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    func sampleSnapshot(from sampleOffset: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let start = max(0, min(sampleOffset, samples.count))
        return Array(samples[start...])
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
