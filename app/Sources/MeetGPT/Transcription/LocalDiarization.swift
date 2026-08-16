import Foundation
import FluidAudio

/// Private, post-call speaker diarization.
///
/// Audio and embeddings stay in this process. FluidAudio may download its
/// CoreML weights on first use, then caches them under Application Support.
/// orakul never persists the returned embeddings or builds voiceprints.
enum LocalDiarization {

    typealias Progress = @Sendable (Double) -> Void

    /// Explicit opt-in. Accuracy is still beta quality, so this must never be
    /// silently enabled for an existing user.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.localDiarization") }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.localDiarization") }
    }

    /// The product asks for the number of remote voices. Measurement showed
    /// that unconstrained clustering can invent eight voices in a two-person
    /// call. Keep this small and explicit instead of exposing an unsafe Auto.
    static let remoteSpeakerCountRange = 1...4

    /// Below this, clustering has too little evidence and a label is more
    /// likely to mislead than help.
    static let minimumSeconds: Double = 20

    static func canRun(sampleCount: Int, sampleRate: Int = 16_000) -> Bool {
        guard sampleRate > 0 else { return false }
        return Double(sampleCount) / Double(sampleRate) >= minimumSeconds
    }

    static func normalizedRemoteSpeakerCount(_ count: Int) -> Int {
        min(max(count, remoteSpeakerCountRange.lowerBound), remoteSpeakerCountRange.upperBound)
    }

    /// Convert the retained PCM away from the main actor and stop promptly if
    /// the user starts a new call or presses Cancel.
    static func floatSamples(from pcm16: ArraySlice<Int16>) async throws -> [Float] {
        let conversion = Task.detached(priority: .utility) {
            var output: [Float] = []
            output.reserveCapacity(pcm16.count)
            let batchSize = 65_536
            var start = pcm16.startIndex
            while start < pcm16.endIndex {
                try Task.checkCancellation()
                let remaining = pcm16.distance(from: start, to: pcm16.endIndex)
                let end = pcm16.index(start, offsetBy: min(batchSize, remaining))
                output.append(contentsOf: pcm16[start..<end].map { Float($0) / 32_768 })
                start = end
            }
            return output
        }
        return try await withTaskCancellationHandler {
            try await conversion.value
        } onCancel: {
            conversion.cancel()
        }
    }

    /// Speaker turns for mono float samples. A speaker count is mandatory:
    /// the measured automatic-count mode is deliberately not exposed.
    static func segments(
        samples: [Float],
        sampleRate: Int = 16_000,
        expectedRemoteSpeakerCount: Int,
        clusteringThreshold: Double? = nil,
        progress: Progress? = nil
    ) async throws -> [SpeakerSegment] {
        guard canRun(sampleCount: samples.count, sampleRate: sampleRate) else { return [] }
        try Task.checkCancellation()

        var config = OfflineDiarizerConfig.default
        config.sampleRate = sampleRate
        if let clusteringThreshold {
            config.clusteringThreshold = clusteringThreshold
        }
        config = config.withSpeakers(
            exactly: normalizedRemoteSpeakerCount(expectedRemoteSpeakerCount)
        )

        progress?(0)
        let models = try await Runtime.shared.models { update in
            progress?(min(0.2, max(0, update.fractionCompleted * 0.2)))
        }
        try Task.checkCancellation()
        progress?(0.2)

        // Managers are configuration-bound. Models are read-only and cached;
        // a fresh manager prevents concurrent calls with different counts from
        // changing each other's result.
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audio: samples) { complete, total in
            let fraction = total > 0 ? Double(complete) / Double(total) : 0
            progress?(0.2 + min(0.5, max(0, fraction * 0.5)))
        }
        try Task.checkCancellation()
        progress?(1)

        return result.segments.compactMap { segment in
            let start = segment.startTimeSeconds
            let end = segment.endTimeSeconds
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  !segment.speakerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return SpeakerSegment(
                speakerID: segment.speakerId,
                startSeconds: start,
                endSeconds: end
            )
        }
    }

    /// Serializes the first model load. Only CoreML weights are retained; no
    /// recording-derived embeddings or speaker identity data leave the call.
    private actor Runtime {
        static let shared = Runtime()
        private var cachedModels: OfflineDiarizerModels?
        private var loading: Task<OfflineDiarizerModels, Error>?

        func models(progress: ProgressHandler?) async throws -> OfflineDiarizerModels {
            if let cachedModels { return cachedModels }
            if let loading {
                return try await withTaskCancellationHandler {
                    try await loading.value
                } onCancel: {
                    loading.cancel()
                }
            }

            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let models = try await OfflineDiarizerModels.load(
                    from: OfflineDiarizerModels.defaultModelsDirectory(),
                    progressHandler: progress
                )
                try Task.checkCancellation()
                return models
            }
            loading = task
            do {
                let models = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                cachedModels = models
                loading = nil
                return models
            } catch {
                loading = nil
                throw error
            }
        }
    }
}
