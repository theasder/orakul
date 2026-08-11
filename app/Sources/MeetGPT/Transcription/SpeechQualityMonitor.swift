import Foundation

/// A rolling read on how well recognition is going, so the UI can stop presenting
/// garbled text as evidence.
///
/// A blind-spot card quotes the transcript to show what it is about. When the
/// audio is poor the quote is mangled, and a mangled quote is worse than none: it
/// makes a correct finding look wrong and invites the user to distrust the panel.
///
/// The signal is already produced and thrown away. `LocalWhisperTranscription`
/// evaluates every segment against `isReliable` and DROPS the failures, logging
/// each one. Nothing aggregates that, so "the mic is struggling right now" was
/// visible in the log and nowhere else. This counts accept/reject over a moving
/// window; a high reject rate means the audio, not the model, is the problem.
///
/// Deliberately a ratio over a window rather than a running average: quality
/// changes within a call — someone joins from a car, a fan starts — and a
/// lifetime average would be dominated by whichever half came first.
final class SpeechQualityMonitor: @unchecked Sendable {
    /// Shared because the two capture tracks feed one perception of "the audio is
    /// bad". Injectable in tests via the initializer.
    static let shared = SpeechQualityMonitor()

    /// Segments considered before a verdict is offered. Below this the sample is
    /// too small — one dropped segment out of three is not a bad connection.
    static let minimumSample = 12

    /// Reject rate above which quotes are suppressed. Whisper discards the odd
    /// segment on clean audio too, so this sits well clear of normal operation.
    static let poorRejectRate = 0.4

    /// How many verdicts the window holds.
    static let windowSize = 40

    private let lock = NSLock()
    private var window: [Bool] = []          // true = accepted
    private let capacity: Int
    private let sampleFloor: Int
    private let threshold: Double

    init(windowSize: Int = SpeechQualityMonitor.windowSize,
         minimumSample: Int = SpeechQualityMonitor.minimumSample,
         poorRejectRate: Double = SpeechQualityMonitor.poorRejectRate) {
        self.capacity = max(1, windowSize)
        self.sampleFloor = max(1, minimumSample)
        self.threshold = poorRejectRate
    }

    func record(accepted: Bool) {
        lock.lock(); defer { lock.unlock() }
        window.append(accepted)
        if window.count > capacity { window.removeFirst(window.count - capacity) }
    }

    /// Cleared between calls: the previous meeting's room says nothing about this
    /// one, and carrying it over would suppress quotes on a clean call.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        window.removeAll()
    }

    /// Nil until the sample is large enough — the caller treats nil as "assume
    /// fine", so a fresh call shows quotes immediately rather than withholding
    /// them until it has evidence of success.
    var rejectRate: Double? {
        lock.lock(); defer { lock.unlock() }
        guard window.count >= sampleFloor else { return nil }
        let rejected = window.filter { !$0 }.count
        return Double(rejected) / Double(window.count)
    }

    var isPoor: Bool {
        guard let rate = rejectRate else { return false }
        return rate > threshold
    }
}
