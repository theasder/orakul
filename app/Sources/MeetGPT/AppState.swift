import AVFoundation
import Combine
import Foundation
import MCP
import os
import SwiftUI
import OrakulCore

/// Audio callbacks can arrive hundreds of times per second. Gate meter work on
/// that callback thread so RMS calculation and MainActor publication happen at
/// a visual frame rate instead of invalidating the full UI per audio buffer.
final class AudioLevelUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastSampleAt: TimeInterval?

    init(minimumInterval: TimeInterval = 0.05) {
        self.minimumInterval = max(0, minimumInterval)
    }

    func shouldSample(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastSampleAt, now - lastSampleAt < minimumInterval { return false }
        lastSampleAt = now
        return true
    }
}

/// Low-overhead, thread-safe proof that each side of a duplex recording is
/// still delivering real buffers. The live Zoom-like fixture reads these
/// counters instead of inferring microphone health from transcript text (echo
/// cancellation may correctly leave the mic transcript empty).
struct AudioTrackDiagnosticSnapshot: Sendable {
    let bufferCount: Int
    let rmsSampleCount: Int
    let rmsSum: Double
    let maxRMS: Double
    let nonSilentSampleCount: Int
    let lastBufferAt: Double?
}

final class AudioTrackDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0
    private var rmsSampleCount = 0
    private var rmsSum = 0.0
    private var maxRMS = 0.0
    private var nonSilentSampleCount = 0
    private var lastBufferAt: Double?

    func reset() {
        lock.lock()
        bufferCount = 0
        rmsSampleCount = 0
        rmsSum = 0
        maxRMS = 0
        nonSilentSampleCount = 0
        lastBufferAt = nil
        lock.unlock()
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        bufferCount += 1
        let shouldMeasure = bufferCount == 1 || bufferCount.isMultiple(of: 5)
        lastBufferAt = Date().timeIntervalSince1970
        lock.unlock()
        guard shouldMeasure else { return }

        let rms = Double(AudioLevel.rms(buffer))
        lock.lock()
        rmsSampleCount += 1
        rmsSum += rms
        maxRMS = max(maxRMS, rms)
        if rms > 0.001 { nonSilentSampleCount += 1 }
        lock.unlock()
    }

    func snapshot() -> AudioTrackDiagnosticSnapshot {
        lock.lock(); defer { lock.unlock() }
        return AudioTrackDiagnosticSnapshot(
            bufferCount: bufferCount,
            rmsSampleCount: rmsSampleCount,
            rmsSum: rmsSum,
            maxRMS: maxRMS,
            nonSilentSampleCount: nonSilentSampleCount,
            lastBufferAt: lastBufferAt)
    }
}

/// Audio chunk callbacks run off the main actor. This locked token lets Stop
/// invalidate already-emitted chunks, then assign only the final partial flush
/// to a fresh generation without racing those callbacks.
final class RecordingGenerationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int
    /// Audio on this route cannot predate route installation. Clamping avoids
    /// placing a newly routed large buffer before an earlier route's final.
    private var routeStartedAt: Date
    private var routeRetiredAt: Date?
    private var streamingRetiredAt: Date?

    init(_ generation: Int, routeStartedAt: Date = Date()) {
        self.generation = generation
        self.routeStartedAt = routeStartedAt
    }

    func read() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func set(_ generation: Int) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
    }

    static func nextRouteStart(after boundary: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
            boundary.timeIntervalSinceReferenceDate.nextUp)
    }

    /// The credit-cap fallback reuses the same token captured by its dormant
    /// chunk handlers. Advance that token to a new route epoch while keeping a
    /// separate clamp for late streaming finals.
    func transitionFromStreamingToChunked(at boundary: Date) -> Date {
        lock.lock(); defer { lock.unlock() }
        if streamingRetiredAt == nil { streamingRetiredAt = boundary }
        let next = Self.nextRouteStart(after: boundary)
        routeStartedAt = next
        routeRetiredAt = nil
        return next
    }

    /// One handoff boundary closes every old producer. Chunk callbacks flushed
    /// just after the switch and trailing stream finals are both clamped to the
    /// same old-route endpoint.
    func retireRoute(at timestamp: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if routeRetiredAt == nil { routeRetiredAt = timestamp }
        if streamingRetiredAt == nil { streamingRetiredAt = timestamp }
    }

    /// Clamp late CloseStream finals to the instant their stream stopped
    /// receiving audio. New-engine chunks are timestamped after this boundary,
    /// so a slow server final cannot reorder pre-switch speech behind them.
    func retireStreamingResults(at timestamp: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if streamingRetiredAt == nil { streamingRetiredAt = timestamp }
    }

    func timestampForStreamingResult(arrivedAt timestamp: Date = Date()) -> Date {
        lock.lock(); defer { lock.unlock() }
        let retiredAt = streamingRetiredAt ?? routeRetiredAt
        guard let retiredAt else { return timestamp }
        return min(timestamp, retiredAt)
    }

    func captureStart(duration: TimeInterval, completedAt: Date = Date()) -> Date {
        lock.lock(); defer { lock.unlock() }
        let completion = routeRetiredAt.map { min(completedAt, $0) } ?? completedAt
        return max(routeStartedAt,
                   completion.addingTimeInterval(-max(0, duration)))
    }
}

/// Counts work emitted by one chunked transcription route. An engine handoff
/// closes the route only after its buffers have atomically moved elsewhere;
/// already-emitted chunks are then allowed to finish before the old model is
/// unloaded. Stop/new-recording invalidation remains the separate generation
/// boundary enforced by `dispatchTranscription`.
final class TranscriptionRouteLease: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var inFlight = 0
    private var onDrained: (() -> Void)?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        inFlight += 1
        return true
    }

    func finish() {
        let completion: (() -> Void)?
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        inFlight = max(0, inFlight - 1)
        if !accepting, inFlight == 0 {
            completion = onDrained
            onDrained = nil
        } else {
            completion = nil
        }
        if inFlight == 0 {
            waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: false)
        } else {
            waiters = []
        }
        lock.unlock()
        completion?()
        waiters.forEach { $0.resume() }
    }

    /// Wait for work emitted before Stop. Call only after both audio buffers
    /// have synchronously flushed, so no new lease belongs to this route.
    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if inFlight == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    @discardableResult
    func retire(whenDrained completion: @escaping () -> Void) -> Bool {
        let runImmediately: Bool
        lock.lock()
        guard accepting else {
            lock.unlock()
            return false
        }
        accepting = false
        if inFlight == 0 {
            runImmediately = true
        } else {
            onDrained = completion
            runImmediately = false
        }
        lock.unlock()
        if runImmediately { completion() }
        return true
    }
}

/// Session-scoped switch flipped when a metered live stream (Deepgram via
/// credit grant) hits its cap mid-call. The Deepgram-mode chunkers consult it
/// on every emitted chunk: nil → chunks are discarded (the stream carries the
/// transcript); a transcriber → the same chunkers now feed on-device Whisper,
/// so the recording continues seamlessly. Audio callbacks read it off the
/// main actor — hence the lock.
final class LiveStreamDegradeState: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: TranscriptionService?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return transcriber != nil
    }

    func activeTranscriber() -> TranscriptionService? {
        lock.lock(); defer { lock.unlock() }
        return transcriber
    }

    func activate(_ service: TranscriptionService) {
        lock.lock(); defer { lock.unlock() }
        guard transcriber == nil else { return }
        transcriber = service
    }
}

/// Bounded bridge for the short Local→Instant startup window. Fixed chunks
/// emitted after the atomic cutover cannot go to Local immediately (that would
/// duplicate a successful Deepgram stream), but they must remain recoverable
/// if either socket fails before both tracks are ready. Pre-ready Deepgram
/// finals are staged for the same reason: commit them only on success, discard
/// them when the buffered PCM is replayed through the restored local route.
final class DeepgramPreReadyBuffer: @unchecked Sendable {
    struct Chunk {
        let wav: Data
        let duration: TimeInterval
        let source: TranscriptSource
        let capturedAt: Date
    }

    struct Result {
        let text: String
        let source: TranscriptSource
        let speakerIndex: Int?
        let receivedAt: Date
    }

    enum ResultDisposition {
        case buffered
        case deliver(Result)
        case discard
    }

    private enum Phase: Equatable { case pending, healthy, rollback }
    /// The readiness deadline is 12 s. One extra maximum callback interval
    /// covers scheduler skew while keeping memory below roughly 1 MB total for
    /// two mono WAV tracks.
    static let maximumSecondsPerTrack: TimeInterval = 15

    private let lock = NSLock()
    private var phase: Phase = .pending
    private var chunks: [Chunk] = []
    private var results: [Result] = []
    private var secondsBySource: [TranscriptSource: TimeInterval] = [:]

    /// Returns true while this handoff owns the chunk (buffered or deliberately
    /// capped). false means the handoff resolved and the normal fallback route
    /// may handle it.
    func capture(
        wav: Data,
        duration: TimeInterval,
        source: TranscriptSource,
        capturedAt: Date
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .pending else { return false }
        let used = secondsBySource[source, default: 0]
        guard used + duration <= Self.maximumSecondsPerTrack else {
            // This should be unreachable before the 12 s timeout; fail closed
            // on memory rather than growing without bound.
            return true
        }
        secondsBySource[source] = used + duration
        chunks.append(Chunk(
            wav: wav, duration: duration, source: source,
            capturedAt: capturedAt))
        return true
    }

    func stage(_ result: Result) -> ResultDisposition {
        lock.lock(); defer { lock.unlock() }
        switch phase {
        case .pending:
            results.append(result)
            return .buffered
        case .healthy:
            return .deliver(result)
        case .rollback:
            return .discard
        }
    }

    /// Commit provider finals and discard PCM: only one representation of the
    /// startup window is ever admitted on a successful handoff.
    func commitSuccessful() -> [Result] {
        lock.lock(); defer { lock.unlock() }
        guard phase == .pending else { return [] }
        phase = .healthy
        chunks.removeAll(keepingCapacity: false)
        secondsBySource.removeAll(keepingCapacity: false)
        let committed = results
        results.removeAll(keepingCapacity: false)
        return committed
    }

    /// Discard staged provider text and return PCM exactly once for restored
    /// Local transcription.
    func drainForRollback() -> [Chunk] {
        lock.lock(); defer { lock.unlock() }
        guard phase == .pending else { return [] }
        phase = .rollback
        results.removeAll(keepingCapacity: false)
        let drained = chunks.sorted { $0.capturedAt < $1.capturedAt }
        chunks.removeAll(keepingCapacity: false)
        secondsBySource.removeAll(keepingCapacity: false)
        return drained
    }
}

/// Resolves the short interval between selecting Instant and Deepgram proving
/// that its socket is usable. A terminal failure in that interval restores the
/// engine that was already transcribing the call; after both tracks are ready,
/// later outages use Deepgram's normal reconnect/degrade behavior.
final class DeepgramHandoffState: @unchecked Sendable {
    enum Track: Hashable { case system, microphone }
    enum FailureDisposition: Equatable {
        case claimedRollback
        case rollbackAlreadyClaimed
        case healthyStream
    }

    /// A socket that never produces a server frame is not a successful live
    /// switch. Deepgram's reconnect loop is intentionally unbounded for an
    /// established stream, but during a handoff the previous engine is still
    /// available and is the safer place to return after this deadline.
    /// Сколько ждать готовности обеих дорожек, прежде чем откатиться.
    ///
    /// `@TaskLocal`, чтобы тест мог его отодвинуть. Двенадцать секунд — это
    /// настоящие секунды стенных часов, и в тесте они шли параллельно с 2668
    /// другими: при полной загрузке машины `DeepgramHandoffIntegrationTests`
    /// не успевал дойти от `startDeepgram` до отметки готовности за это время,
    /// таймер срабатывал первым, `drainForRollback` переводил буфер в
    /// `.rollback`, и `commitSuccessful` возвращал пустой массив. Наружу это
    /// выглядело как пустой транскрипт и «плавающий» тест, который в одиночку
    /// всегда проходил — потому что в одиночку двенадцати секунд хватало.
    ///
    /// Продакшен читает то же значение: `Task {}` наследует task-local, а
    /// подмены там нет, поэтому остаются те же двенадцать секунд.
    @TaskLocal static var readinessTimeoutNanoseconds: UInt64 = 12_000_000_000

    private let lock = NSLock()
    private var readyTracks: Set<Track> = []
    private var routesCutOver = false
    private enum Resolution: Equatable { case pending, healthy, rollbackClaimed }
    private var resolution: Resolution = .pending

    /// Returns true exactly once, when both live tracks have proven usable and
    /// the retained audio buffers have atomically moved to those tracks.
    func markReady(_ track: Track) -> Bool {
        lock.lock(); defer { lock.unlock() }
        readyTracks.insert(track)
        return claimReadinessIfComplete()
    }

    func markRoutesCutOver() -> Bool {
        lock.lock(); defer { lock.unlock() }
        routesCutOver = true
        return claimReadinessIfComplete()
    }

    private func claimReadinessIfComplete() -> Bool {
        guard readyTracks.count == 2, routesCutOver,
              resolution == .pending else {
            return false
        }
        resolution = .healthy
        return true
    }

    func claimPreReadyFailure() -> FailureDisposition {
        lock.lock(); defer { lock.unlock() }
        switch resolution {
        case .pending:
            resolution = .rollbackClaimed
            return .claimedRollback
        case .rollbackClaimed:
            return .rollbackAlreadyClaimed
        case .healthy:
            return .healthyStream
        }
    }
}

/// Serial off-main lane for the comparatively expensive bundled-skill lookup.
/// A rapid sequence of prompts cancels older AppState tasks; canceled calls
/// queued behind the initial catalog load are discarded before doing another
/// full relevance pass. This avoids both a MainActor freeze and detached work
/// that survives after its answer has been superseded.
private actor BundledSkillGuidanceWorker {
    static let shared = BundledSkillGuidanceWorker()

    func resolve(promptID: String?, query: String) -> String? {
        guard !Task.isCancelled else { return nil }
        return BundledSkillRouter.guidance(for: promptID, query: query)
    }
}

/// Kept separate from AppState so a 20 Hz decorative meter refresh does not
/// invalidate transcript rows, streamed Markdown, or the rest of the window.
@MainActor
final class AudioMeterState: ObservableObject {
    @Published private(set) var level: CGFloat = 0

    func update(_ raw: CGFloat) {
        let target = min(1, max(0, raw))
        // Fast attack, slow release for a natural-feeling meter.
        if target > level {
            level = level * 0.4 + target * 0.6
        } else {
            level = level * 0.82 + target * 0.18
        }
    }

    func reset() { level = 0 }
}

/// The timer is kept out of `AppState` so a once-per-second label refresh does
/// not invalidate the transcript, prompt controls, and streamed Markdown.
/// Values are quantized because every consumer displays or accounts in whole
/// seconds; publishing sub-second changes only creates redundant layout work.
@MainActor
final class RecordingClockState: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0

    func update(_ raw: TimeInterval) {
        let seconds = floor(max(0, raw))
        guard seconds != elapsed else { return }
        elapsed = seconds
    }

    func reset() {
        guard elapsed != 0 else { return }
        elapsed = 0
    }
}

/// Thread-safe per-request staging for streamed model deltas. Providers may
/// call their delta closure from arbitrary queues; draining at a visual cadence
/// avoids creating one main-actor task and one whole-window render per token.
final class AIStreamDeltaBuffer: @unchecked Sendable {
    static let publishInterval: TimeInterval = 0.08
    private let lock = NSLock()
    private var pending = ""
    /// The complete callback stream for this request. Most gateways also return
    /// this text, but retaining it closes a real failure mode: a gateway can
    /// successfully emit every SSE delta and still return an empty aggregate.
    /// The answer pipeline used to overwrite the visible deltas with that empty
    /// return value, leaving a completed workflow and a blank dialog.
    private var complete = ""

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        lock.lock()
        pending += delta
        complete += delta
        lock.unlock()
    }

    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = ""
        return value
    }

    func completeText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }
}

struct TranscriptionPerformanceNotice: Equatable {
    enum Action: Equatable { case none, useDeepgram }
    let message: String
    let action: Action
}

private struct PersistedConnectionSnapshot: Sendable {
    let googleTokens: GoogleTokens?
    let wheesprSession: WheesprSession?
    let googleCacheRevision: UInt64
    let wheesprCacheRevision: UInt64
}

@MainActor
final class AppState: ObservableObject {
    enum RecordingStatus: Equatable {
        case idle
        case starting
        case recording
        /// Capture, background scanning and credit consumption are suspended,
        /// but the session, its transcript and its goal are alive. Distinct
        /// from `.stopping`, which is on its way to finalisation.
        case paused
        case stopping
        case error(String)
    }

    enum AssistantAnswerExportError: LocalizedError {
        case noAnswer
        case answerStillStreaming
        case answerChanged

        var errorDescription: String? {
            switch self {
            case .noAnswer:
                return "Экспортировать нечего: ответа пока нет."
            case .answerStillStreaming:
                return "Ответ ещё пишется — дождитесь конца и повторите."
            case .answerChanged:
                return "Пока придумывалось название, ответ успел смениться. Повторите экспорт."
            }
        }
    }

    /// Where the transcription engine is in its lifecycle. Drives the transcript
    /// panel's empty state so a first-run on-device model download reads as
    /// "preparing" instead of a broken, blank transcript — and a failure is
    /// surfaced rather than silently swallowed.
    enum TranscriptionState: Equatable {
        case idle       // nothing to prepare yet (before recording / cloud engine)
        case preparing  // downloading / loading the on-device model
        case ready      // engine is ready to transcribe
        case failed(String)
    }

    @Published var status: RecordingStatus = .idle
    @Published var transcriptionState: TranscriptionState = .idle
    @Published var transcriptionPerformanceNotice: TranscriptionPerformanceNotice?

    // First-run pre-flight: live permission status the onboarding screen shows.
    @Published var micGranted: Bool = Permissions.microphone == .granted
    @Published var screenRecordingGranted: Bool = false   // resolved async
    /// App light/dark theme preference (Settings → Appearance).
    @Published var appAppearance: AppAppearance = Config.appAppearance
    /// Shared scene route so main-window actions can open a specific Settings tab.
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published var transcript: [TranscriptEntry] = [] {
        didSet { transcriptRevision &+= 1 }
    }
    /// Every transcript mutation invalidates post-call rewrite snapshots.
    /// Fireflies and Local refinement both check this before committing, so a
    /// slower pass cannot overwrite a newer transcript even when cancellation
    /// is cooperative only.
    private var transcriptRevision = 0

    /// Whether any AI action ran during THIS recording. Distinct from the
    /// once-per-device `first_ai_action` activation flag: abandonment is a
    /// per-session question, so it needs a per-session answer.
    var sessionUsedAI = false

    /// Where this instance reports usage. Injected rather than calling
    /// `FunnelTracker` directly so a test observes its OWN state's events: a
    /// global observer is shared with every suite running in parallel, and an
    /// unrelated test that pauses a recording would land in another test's
    /// assertions. Absence assertions — "a refused call reports nothing" — are
    /// exactly the ones that race, and exactly the ones worth having.
    let analytics: (AnalyticsEvent) -> Void
    @Published var contextFiles: [ImportedContextFile] = []
    /// Folders attached as standing context. Kept separate from `contextFiles`
    /// so the whole folder detaches in one action, and so the UI can show what a
    /// scan left out rather than presenting its contents as hand-picked.
    @Published private(set) var contextFolders: [ContextFolder] = []
    @Published var contextNotes: String = ""
    @Published var contextImporting: Bool = false
    /// Images pinned to the next AI message (sent to the vision model).
    @Published var pendingImages: [Attachment] = []
    /// True while an audio/video attachment is being decoded + transcribed.
    @Published var attaching = false
    /// A prompt held back until the user resolves its ambiguity. Non-nil means
    /// the clarification card is on screen and no model call has been spent on
    /// the request yet — see `ask(_:)`.
    @Published var pendingClarification: PendingClarification?
    /// True while tier 2 is deciding whether the request needs clarifying. Shown
    /// as a quiet inline state rather than the full workflow trace, because most
    /// assessments end in "no question needed" and never produce a card.
    @Published private(set) var clarifying = false
    @Published var aiResponse: String = ""
    /// Exact user/button request that produced the visible assistant answer.
    /// Kept separately because the composer and follow-up chips clear as soon
    /// as a run begins, while DOCX export may happen much later.
    @Published private(set) var aiResponsePrompt: String = ""
    /// The free-form request most recently accepted by the composer, published
    /// synchronously before clarification or grounding begins. This prevents
    /// Send from looking like it discarded the message while preflight work is
    /// still deciding whether the answer can start.
    @Published private(set) var submittedPromptPreview: String?
    /// Stable identity and lifecycle metadata for the visible assistant run.
    /// These remain populated after completion so a state dump can correlate
    /// the prompt injection with its exact terminal result.
    @Published private(set) var aiResponseID: UUID?
    @Published private(set) var aiResponsePromptID: String?
    @Published private(set) var aiResponseStartedAt: Date?
    @Published private(set) var aiResponseCompletedAt: Date?
    @Published private(set) var aiResponseStatus: AIExchangeStatus?
    /// Immutable picker selection captured when this answer began (for example
    /// `auto:anthropic`), not necessarily the concrete model ultimately routed
    /// on the wire. Settings may change while grounding is in flight, but one
    /// visible answer never changes routing policy mid-request.
    @Published private(set) var aiResponseModelID: String?
    /// LLM-created title cached for the visible answer. Re-exporting the same
    /// answer must not spend another model call.
    @Published private(set) var aiResponseExportTitle: String?
    /// Completed turns BEFORE the live one, oldest first. The live turn is
    /// aiResponsePrompt + aiResponse; this is everything the dialog used to
    /// throw away when the next prompt was pressed.
    @Published private(set) var aiHistory: [AIExchange] = []
    /// Automation/evaluation evidence for every terminal attempt, including
    /// blank cancellations which correctly stay out of the visible dialog.
    /// This is runtime evidence; successful visible turns continue to persist
    /// through `aiHistory` exactly as before.
    /// Reading text size for the transcript and the assistant answer.
    ///
    /// Published rather than read straight from Config at each call site so a
    /// change repaints immediately — a size control that needs a relaunch to
    /// take effect reads as broken.
    @Published var readingTextScale: Double = Config.readingTextScale {
        didSet { Config.readingTextScale = readingTextScale }
    }

    @Published private(set) var aiExchangeEvidence: [AIExchange] = []

    /// Record what the user thought of an archived answer.
    ///
    /// Local only: it is written into the session file beside the transcript,
    /// prompt and answer that produced it, and sent nowhere. Re-rating the same
    /// answer replaces the earlier verdict rather than appending, so the stored
    /// value is always the user's current opinion.
    func recordAnswerFeedback(_ feedback: AnswerFeedback?, forExchange id: UUID) {
        guard let index = aiHistory.firstIndex(where: { $0.id == id }) else { return }
        aiHistory[index].feedback = feedback
        // The evidence ledger carries the same turn; keeping them in step stops
        // an export disagreeing with what the user sees.
        if let evidenceIndex = aiExchangeEvidence.firstIndex(where: { $0.id == id }) {
            aiExchangeEvidence[evidenceIndex].feedback = feedback
        }
        persistCurrentSession()
    }

    /// Feedback on the answers of THIS session, newest first. The reflection
    /// harness reads the same field from saved sessions.
    var answerFeedbackSoFar: [(exchange: AIExchange, feedback: AnswerFeedback)] {
        aiHistory.compactMap { exchange in
            exchange.feedback.map { (exchange, $0) }
        }.sorted { $0.feedback.at > $1.feedback.at }
    }
    /// Bounds memory and the saved-session file on a long meeting with many
    /// prompt presses. Oldest turns drop first.
    static let maxArchivedExchanges = 20
    @Published var aiStreaming: Bool = false {
        didSet {
            guard aiStreaming != oldValue else { return }
            if aiStreaming {
                workflowSteps = []; stepSeq = 0      // a new run → fresh thinking log
                workflowTracePreplanned = false
            } else {
                terminalizeAssistantAnswer()
                // Close every live row without changing the planned row count.
                // A queued step that the run did not need is an honest skip, not
                // a success. Stable rows prevent answer-pane jumps while recording.
                for index in workflowSteps.indices {
                    switch workflowSteps[index].status {
                    case .running:
                        workflowSteps[index].status = .succeeded
                    case .pending:
                        workflowSteps[index].status = .skipped
                        if workflowSteps[index].detail == nil {
                            workflowSteps[index].detail = "Not needed for this run"
                        }
                    case .succeeded, .skipped, .failed:
                        break
                    }
                }
                devCallDiagnostics.record(
                    event: "workflow_terminal_snapshot",
                    fields: ["steps": workflowSteps.map(diagnosticWorkflowStep)])
            }
        }
    }
    /// Current pipeline stage while a prompt-button workflow runs (e.g.
    /// "Checking Notion, Linear…", "Auditing draft…"). nil when idle/drafting.
    /// The setter also feeds `workflowSteps` — the visible "thinking process".
    @Published var aiStage: String? {
        didSet {
            guard let label = aiStage, !label.isEmpty, label != oldValue else { return }
            recordWorkflowStage(label)
        }
    }
    /// The live "thinking process": an ordered, de-duplicated log of the pipeline
    /// stages for the current run, derived from `aiStage` transitions. Shown as a
    /// collapsible step panel above the answer; reset on every new run.
    @Published var workflowSteps: [WorkflowStep] = []
    private var stepSeq = 0
    private var workflowTracePreplanned = false

    /// Install the complete operational plan before any network call starts.
    /// Later updates mutate these rows in place, keeping the assistant layout
    /// stable even when several connected apps are searched in parallel.
    func installWorkflowPlan(_ steps: [WorkflowStep]) {
        workflowSteps = steps
        stepSeq = steps.map(\.id).max() ?? 0
        workflowTracePreplanned = !steps.isEmpty
        devCallDiagnostics.record(
            event: "workflow_plan",
            fields: ["steps": steps.map(diagnosticWorkflowStep)])
    }

    /// Advance a preplanned app row without exposing tool arguments, payloads,
    /// credentials, or private model reasoning.
    private func updateWorkflowStep(appID: String,
                                    label: String? = nil,
                                    status: WorkflowStep.Status,
                                    detail: String? = nil,
                                    tool: String? = nil) {
        guard let index = workflowSteps.firstIndex(where: { step in
            step.app?.id == appID && (label == nil || step.label == label)
        }) else { return }
        workflowSteps[index].status = status
        if let detail { workflowSteps[index].detail = detail }
        if let tool { workflowSteps[index].tool = tool }
        devCallDiagnostics.record(
            event: "workflow_step",
            fields: diagnosticWorkflowStep(workflowSteps[index]))
    }

    /// Legacy callers still set `aiStage`. When a complete plan exists, match
    /// that stage to its stable row; otherwise retain the original append-only
    /// behavior used by simple/free-form runs and older tests.
    private func recordWorkflowStage(_ label: String) {
        if workflowTracePreplanned,
           let index = workflowSteps.firstIndex(where: { $0.label == label && !$0.status.isTerminal }) {
            for other in workflowSteps.indices where other != index && workflowSteps[other].status == .running {
                workflowSteps[other].status = .succeeded
            }
            workflowSteps[index].status = .running
            devCallDiagnostics.record(
                event: "workflow_step",
                fields: diagnosticWorkflowStep(workflowSteps[index]))
            return
        }

        if let last = workflowSteps.indices.last { workflowSteps[last].done = true }
        stepSeq += 1
        workflowSteps.append(WorkflowStep(id: stepSeq, label: label, done: false))
        if let step = workflowSteps.last {
            devCallDiagnostics.record(
                event: "workflow_step", fields: diagnosticWorkflowStep(step))
        }
    }

    private func diagnosticWorkflowStep(_ step: WorkflowStep) -> [String: Any] {
        var fields: [String: Any] = [
            "id": step.id,
            "label": step.label,
            "status": step.status.rawValue,
            "done": step.done,
        ]
        if let detail = step.detail { fields["detail"] = detail }
        if let app = step.app {
            fields["app"] = [
                "id": app.id, "name": app.name, "connection": app.kind.rawValue,
            ]
        }
        if let tool = step.tool { fields["tool"] = tool }
        return fields
    }
    /// The last typed artifact a structured button produced (Tasks/Summary) —
    /// the seam for export (CSV → Sheets, actions → the ledger).
    @Published var lastStructuredArtifact: StructuredArtifact?

    /// The action items of the last Tasks-button run, when the current artifact
    /// is a tasks artifact — drives the "Send to tracker" write-back affordance.
    var currentTaskItems: [TasksArtifact.Item]? {
        if case .tasks(let artifact) = lastStructuredArtifact { return artifact.items }
        return nil
    }
    @Published var lastError: String?

    /// Пропал ли звук собеседников посреди записи.
    ///
    /// Отдельно от `lastError`, потому что это не ошибка операции, а состояние
    /// идущего звонка: запись продолжается, но пишется половина. Сбрасывается
    /// при старте следующей записи — иначе предупреждение с прошлого звонка
    /// встретит человека на следующем и будет врать.
    @Published private(set) var systemAudioLostDuringRecording = false

    /// Пропал ли микрофон посреди записи.
    ///
    /// Отдельно от системного звука, потому что пропадает другая половина
    /// разговора и человек должен понимать какая: «вас не слышно» и «их не
    /// слышно» требуют разных действий.
    @Published private(set) var microphoneLostDuringRecording = false

    /// Микрофон не удалось вернуть после смены аудиоустройства.
    func noteMicrophoneLost() {
        guard isRecording else { return }
        microphoneLostDuringRecording = true
        lastError = "Микрофон пропал — записываются только собеседники. "
            + "Обычно это отключившиеся наушники или вынутый USB-микрофон; "
            + "проверьте устройство ввода и начните запись заново."
    }

    /// Единственное место, где этот флаг поднимается.
    func noteSystemAudioLost() {
        guard isRecording else { return }   // после «Стоп» это не новость
        systemAudioLostDuringRecording = true
        lastError = "Звук собеседников пропал — запись продолжается только с микрофона. "
            + "Обычно это отозванное разрешение «Запись экрана» или отключённый дисплей."
    }

    /// Connected work-apps (MCP), attached by the app root so prompt-button
    /// workflows can ground from live sources. Weak: the app scene owns it.
    weak var mcp: MCPConnectionManager? {
        didSet { bindWorkflowDesigner(to: mcp) }
    }
    private var mcpCapabilityObservation: AnyCancellable?

    enum ConnectedGlossarySuggestionStatus: Equatable {
        case idle
        case loading
        case ready
        case empty
        case unavailable(String)
        case failed(String)

        var snapshotValue: String {
            switch self {
            case .idle: return "idle"
            case .loading: return "loading"
            case .ready: return "ready"
            case .empty: return "empty"
            case .unavailable: return "unavailable"
            case .failed: return "failed"
            }
        }
    }

    /// Suggestions are intentionally ephemeral and review-only. They never
    /// enter engine configuration until `acceptConnectedGlossarySuggestion`.
    @Published private(set) var connectedGlossarySuggestions: [ConnectedGlossarySuggestion] = []

    /// A connected app has vocabulary worth mining and nobody has looked yet.
    /// Set on connection (free), cleared once a review has been generated.
    @Published private(set) var glossaryReviewPending = false
    @Published private(set) var connectedGlossarySuggestionStatus: ConnectedGlossarySuggestionStatus = .idle
    @Published private(set) var connectedGlossarySuggestionMetrics: ConnectedGlossarySuggestionMetrics?
    @Published private(set) var connectedGlossarySuggestionMessage: String?
    @Published private(set) var connectedGlossaryAcceptedCount = 0
    @Published private(set) var connectedGlossaryRejectedCount = 0
    private var connectedGlossaryRejectedKeys: Set<String> = []
    private var connectedGlossaryGeneration = 0
    private struct ConnectedGlossaryCache {
        let key: String
        let at: Date
        let generation: ConnectedGlossarySuggestionService.Generation
    }
    private var connectedGlossaryCache: ConnectedGlossaryCache?
    private static let connectedGlossaryCacheTTL: TimeInterval = 5 * 60

    /// Recomputed recipes for every built-in and user-created prompt. The
    /// workflow is refreshed only when verified connection capabilities change
    /// or a custom prompt is saved/edited — never on transcript/audio updates.
    @Published private(set) var designedPromptWorkflows: [String: PromptWorkflow] = [:]
    @Published private(set) var promptWorkflowSources: [String: [WorkflowApp]] = [:]

    /// Session cache for button grounding — a re-pressed button within the TTL
    /// reuses its snippets instead of re-fanning out to every connected app.
    private var groundingCache: [String: (at: Date, snippets: [GroundingSnippet])] = [:]
    private static let groundingTTL: TimeInterval = 120

    /// Structured fact-check results + progress, shown in a color-coded sheet.
    @Published var factChecking = false
    /// Injectable so tests never write meetings into the real Application
    /// Support store — switching calls now saves, so this is load-bearing.
    private let sessionStore: SessionStore
    @Published var factClaims: [FactClaim] = []
    /// One-line rhetoric flag from the background watch (empty = nothing flagged).
    @Published var rhetoricNote = ""
    @Published var facilitationNote = ""
    /// The Efficiency Engine's scored follow-up for the decision filed on this
    /// call. Held as data, not only as the prose it renders into, so it
    /// survives the answer being replaced and can be persisted with the call.
    @Published private(set) var efficiencyFollowUp: SavedFollowUp?
    @Published var showFactCheck = false
    @Published var factCheckError: String?
    /// What the web lane did for the LAST manual check (item 11): sources it
    /// read, or the reason it did not run. Nil for ordinary context-only checks,
    /// and never set by the background cadence loop — searching the web is a
    /// per-request, user-initiated act.
    @Published var factCheckSearch: FactCheckService.WebSearchOutcome?

    /// Optional explicit objective. When empty, AI context can fall back to the
    /// calendar-backed meeting title without repeating that title in this field.
    /// Editing this must refresh blind spots — it is the whole input to them.
    @Published var callGoal: String = "" {
        didSet {
            guard callGoal != oldValue else { return }
            // A user edit takes ownership: the goal is theirs now, not a proposal.
            if !isApplyingProposedGoal { goalWasProposed = false }
            requestBlindSpotRefresh()
        }
    }
    /// True while the field holds an inferred goal the user has not touched.
    @Published private(set) var goalWasProposed = false
    private var isApplyingProposedGoal = false

    /// Goal inferred from the opening minutes and offered as a one-tap chip
    /// when no explicit goal is set. Calendar names belong in `meetingTitle`.
    @Published var suggestedGoal: String?
    private var goalSuggestTask: Task<Void, Never>?

    /// Rolling digest of the call so far (A2): every couple of minutes a fast
    /// model folds new transcript into this running summary, so prompt-button
    /// runs on long calls keep early decisions instead of losing them to
    /// truncation. Kept after recording stops (post-call button presses), reset
    /// when a new recording starts.
    private(set) var callDigest = ""
    private var digestedEntryCount = 0
    private var digestTask: Task<Void, Never>?

    /// Saved meeting sessions (transcript + AI output + digest), newest first.
    /// Persisted per recording so nothing dies on quit (M3); restorable from
    /// the sidebar history.
    @Published var savedSessions: [SavedSession] = []
    // Internal (not private) so the session-lifecycle test can assert a new
    // recording gets its own id.
    var currentSessionID = UUID()

    /// Optional manual override for the call's domain theme. When nil, the theme
    /// is inferred from the goal + transcript and its skill pack is layered onto
    /// every AI action for this call. Set from a theme picker (Settings/overlay).
    @Published var callThemeOverride: CallTheme?

    /// What this capture represents. Automatic inference is intentionally only
    /// a suggestion: tutorials and ordinary YouTube playback can resemble a
    /// call acoustically, so an explicit per-call choice always wins and stays
    /// stable while windows/apps change underneath the recording.
    @Published private(set) var recordingContextSelection = RecordingContextSelection.automatic
    @Published private(set) var detectedRecordingContext: RecordingContextKind = .meeting

    // MARK: Onboarding sample run
    //
    // The first-run sample is a written call replayed into the real workspace.
    // It is fiction, and fiction must not reach anything that claims to be a
    // record: not History, not the decision ledger, not the usage counters that
    // decide when the paywall may appear. One flag guards all three, in one
    // place, rather than a condition at each call site that a later edit can
    // forget.

    @Published private(set) var sampleRunActive = false

    /// The sample's 📌 result. Its own property, deliberately not
    /// `ledgerDecisions`: the ledger holds confirmed team decisions, and a
    /// fictional row in it — even locally, even labelled — destroys the one
    /// thing it sells.
    @Published private(set) var samplePinnedDecision: SampleCall.PreparedDecision?

    /// What the workspace held before the sample borrowed it.
    private var sampleRestorePoint: (transcript: [TranscriptEntry],
                                     suggestions: [Suggestion],
                                     title: String)?

    func startSampleRun() {
        guard !sampleRunActive, !isRecording else { return }
        sampleRestorePoint = (transcript, suggestions, meetingTitle)
        sampleRunActive = true
        samplePinnedDecision = nil
        transcript = []
        suggestions = []
        meetingTitle = SampleCall.mobileBeta.title
        devCallDiagnostics.record(event: "sample_started", fields: [:])
    }

    /// Confirms the sample's decision candidate — a preview row and nothing
    /// else. No ledger call, no network, no team lookup.
    func pinSampleDecision() {
        guard sampleRunActive else { return }
        samplePinnedDecision = SampleCall.mobileBeta.preparedDecision
        devCallDiagnostics.record(event: "sample_decision_logged", fields: [:])
    }

    /// Hands the workspace back exactly as the sample found it.
    func endSampleRun() {
        guard sampleRunActive else { return }
        let restore = sampleRestorePoint
        sampleRunActive = false
        samplePinnedDecision = nil
        sampleRestorePoint = nil
        transcript = restore?.transcript ?? []
        suggestions = restore?.suggestions ?? []
        meetingTitle = restore?.title ?? ""
        devCallDiagnostics.record(event: "sample_ended", fields: [:])
    }

    /// Whether the detector has actually looked yet. `detectedRecordingContext`
    /// starts at `.meeting` because that is also the detector's no-signal
    /// fallback, so without this flag the chip presents an untested default as
    /// a finding ("Auto · Meeting") in the moment the user decides whether to
    /// override it.
    @Published private(set) var hasDetectedRecordingContext = false

    var effectiveRecordingContextLabel: String {
        recordingContextSelection.resolvedDisplayLabel(detected: detectedRecordingContext)
    }

    var effectiveRecordingContextKind: RecordingContextKind? {
        recordingContextSelection.resolvedKind(detected: detectedRecordingContext)
    }

    var effectiveRecordingContextGuidance: String {
        recordingContextSelection.promptGuidance(detected: detectedRecordingContext)
    }

    func selectRecordingContext(
        _ mode: RecordingContextSelection.Mode,
        customLabel: String? = nil
    ) {
        let next = RecordingContextSelection(mode: mode, customLabel: customLabel)
        guard next != recordingContextSelection else { return }
        let previouslyEnabled = automaticCopilotEnabled
        recordingContextSelection = next
        reconcileCopilotAccounting(previouslyEnabled: previouslyEnabled)
        groundingCache.removeAll(keepingCapacity: true)
        requestBlindSpotRefresh()
        devCallDiagnostics.record(event: "recording_context_changed", fields: [
            "selection": mode.rawValue,
            "resolved": effectiveRecordingContextLabel,
            "manual": !next.isAutomatic,
        ])
        if !transcript.isEmpty || isViewingRestoredSession {
            persistCurrentSession()
        }
    }

    /// Apply a best-effort detector result only to this session. Tests call the
    /// value seam directly; production obtains it from visible window metadata
    /// after capture starts. Manual selection remains untouched and therefore
    /// keeps winning even if inference changes later.
    func applyDetectedRecordingContext(
        _ kind: RecordingContextKind,
        for sessionID: UUID? = nil
    ) {
        if let sessionID, sessionID != currentSessionID { return }
        // Set before the no-change guard: confirming the default IS a result,
        // and the chip needs to stop advertising a guess once one exists.
        hasDetectedRecordingContext = true
        guard detectedRecordingContext != kind else { return }
        let previouslyEnabled = automaticCopilotEnabled
        detectedRecordingContext = kind
        reconcileCopilotAccounting(previouslyEnabled: previouslyEnabled)
        if recordingContextSelection.isAutomatic {
            groundingCache.removeAll(keepingCapacity: true)
            requestBlindSpotRefresh()
        }
        devCallDiagnostics.record(event: "recording_context_detected", fields: [
            "detected": kind.rawValue,
            "resolved": effectiveRecordingContextLabel,
            "manualOverride": !recordingContextSelection.isAutomatic,
        ])
    }

    /// Probes what is on screen when a recording starts, then a few more times
    /// across the first minute. The later looks are the ones that matter in
    /// practice: people press Record and only then open the lecture, the
    /// podcast or the call window, and a single snapshot at t=0 files that
    /// whole session as a meeting.
    ///
    /// Stops as soon as something is positively identified, the user picks a
    /// type themselves, or the recording ends — see
    /// `RecordingContextDetector.shouldProbeAgain`.
    private func detectVisibleRecordingContext(for sessionID: UUID) async {
        var pendingDelays = RecordingContextDetector.visibleContextProbeDelays[...]
        while status == .recording, sessionID == currentSessionID {
            let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let detected = await RecordingContextDetector.inferVisibleContext(
                additionalTitles: title.isEmpty ? [] : [title])
            guard status == .recording, sessionID == currentSessionID else { return }
            applyDetectedRecordingContext(detected, for: sessionID)
            guard RecordingContextDetector.shouldProbeAgain(
                    after: detected,
                    manualOverride: !recordingContextSelection.isAutomatic),
                  let seconds = pendingDelays.first else { return }
            pendingDelays = pendingDelays.dropFirst()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    /// The user's job position (RoleSkillMatrix id). Persisted; selects the role
    /// skill layer — role-specific method hints per prompt button — applied on
    /// top of the call theme. nil = no role layer.
    @Published var userRoleID: String? = Config.userRoleID {
        didSet { Config.userRoleID = userRoleID }
    }

    /// The theme in effect right now (override, else inferred).
    var activeCallTheme: CallTheme {
        CallTheme.resolve(
            override: callThemeOverride,
            goal: effectiveCallGoal,
            transcript: transcriptText
        )
    }
    /// Proactive blind-spot suggestions surfaced during the call.
    @Published var suggestions: [Suggestion] = []

    /// The post-call reflection artefact: what the transcript does NOT contain.
    ///
    /// Nil until the pass has run, and stays nil when the pass found nothing
    /// worth saying — the UI shows no section rather than an empty one, because
    /// an empty heading reads as a broken feature.
    @Published private(set) var reflectionArtefact: PostCallReflection.Artefact?

    @Published private(set) var reflectionRunning = false

    /// Whether the reflection pass may be offered right now.
    var canRunPostCallReflection: Bool {
        !reflectionRunning
            && PostCallReflection.canRun(isRecording: status == .recording,
                                         transcript: transcriptText)
    }
    /// A transient provider outage must not look like an indefinitely idle
    /// feature. The UI shows a bounded message; raw vendor bodies never enter it.
    @Published private(set) var blindSpotFailureMessage: String?
    private(set) var dismissedSuggestionTitles: Set<String> = []

    struct BlindSpotActivity: Equatable {
        let attempts: Int
        let successes: Int
        let emptyResults: Int
        let failures: Int
        let lastSuccessAt: Double?
        let lastFailureAt: Double?
        let paidProbeTick: Int
        let lastAttemptID: String?
        let lastBackendCorrelationID: String?
        let lastProbeIDs: [String]
        let lastStartedAt: Double?
        let lastCompletedAt: Double?
        let lastResultCount: Int?
        let lastOutcome: String?
        let lastGrounded: Bool
        let lastProvider: String?
        let lastModel: String?
        let lastProviderLatencyMs: Int?
        let lastChargedCredits: Int?
        let lastCacheHit: Bool?
        let lastProviderAttemptCount: Int?
        let lastProviderAttempts: [BrainstormService.ExecutionTrace.ProviderAttempt]
    }

    /// One immutable, bounded request assembled by the ambient Blind Spot
    /// scheduler. Keeping this as a value makes the transcript/signature/spend
    /// baseline describe the same instant even when more captions arrive at an
    /// `await` boundary.
    struct BlindSpotProviderRequest: Equatable {
        let goal: String
        let transcript: String
        let priorTitles: [String]
        let accessToken: String?
        let guidance: String?
        let context: String?
        let probe: String
        let theme: String
        let grounded: Bool
        /// Item 10, design #2: tell the scan it may emit a connector `probeQuery`,
        /// set only when a searchable connector is available so the server never
        /// asks for a query the app cannot run. Defaults false — the post-call
        /// reflection pass and any other caller opt out for free.
        var canProbe: Bool = false
    }

    /// Dev-only evidence for a connector workflow used by the fixed synthetic
    /// live-call fixture. No credentials are retained.
    struct BlindSpotConnectorDevTrace: Equatable {
        let probeID: String
        let startedAt: Double
        let completedAt: Double
        let latencyMs: Int
        let outcome: String
        let resultCount: Int
        let sourceIDs: [String]
    }

    /// Exact synthetic request evidence exposed only through the nonce-gated,
    /// owner-only dev hook. Production OSLog remains metadata-only.
    struct BlindSpotDevTrace: Equatable {
        let generation: Int
        let sessionID: String
        let preparedAt: Double
        let goal: String
        let transcript: String
        let priorTitles: [String]
        let guidance: String?
        let localContext: String?
        var context: String?
        let probe: String
        let theme: String
        var grounded: Bool
        var requestPayload: String?
        var tokenLookupStartedAt: Double?
        var tokenLookupCompletedAt: Double?
        var connectorStartedAt: Double?
        var connectorCompletedAt: Double?
        var connectorWorkflows: [BlindSpotConnectorDevTrace]
        var groundedCycleConsumedAt: Double?
        var connectorPackStartedAt: Double?
        var connectorPackCompletedAt: Double?
        var providerStartedAt: Double?
        var providerCompletedAt: Double?
    }

    private var blindSpotAttempts = 0
    private var blindSpotSuccesses = 0
    private var blindSpotEmptyResults = 0
    private var blindSpotFailures = 0
    private var blindSpotLastSuccessAt: Double?
    private var blindSpotLastFailureAt: Double?
    private var blindSpotLastAttemptID: String?
    private var blindSpotLastBackendCorrelationID: String?
    private var blindSpotLastProbeIDs: [String] = []
    /// Item 10, design #2: the connector search query the LAST scan asked for, or
    /// nil. Consumed by the NEXT grounded cycle — it replaces the heuristic query
    /// for that one search (no extra call, a smarter one) and is cleared on use.
    private var blindSpotPendingProbeQuery: String?
    private var blindSpotLastStartedAt: Double?
    private var blindSpotLastCompletedAt: Double?
    private var blindSpotLastResultCount: Int?
    private var blindSpotLastOutcome: String?
    private var blindSpotLastGrounded = false
    private var blindSpotLastProvider: String?
    private var blindSpotLastModel: String?
    private var blindSpotLastProviderLatencyMs: Int?
    private var blindSpotLastChargedCredits: Int?
    private var blindSpotLastCacheHit: Bool?
    private var blindSpotLastProviderAttemptCount: Int?
    private var blindSpotLastProviderAttempts: [BrainstormService.ExecutionTrace.ProviderAttempt] = []
    /// Every asynchronous Blind Spot boundary is tied to this identity. A
    /// Settings OFF, snooze, Stop, or new call advances the generation so a
    /// provider that ignores cancellation cannot mutate the current call.
    private var blindSpotGeneration = 0
    private var blindSpotActiveAttemptGeneration: Int?
    private var blindSpotActiveAttemptSessionID: UUID?
    private var syntheticBlindSpotTraceGoal: String?
    private var lastSyntheticBlindSpotTrace: BlindSpotDevTrace?
    private var blindSpotCycleEvaluations = 0

    func blindSpotActivity() -> BlindSpotActivity {
        BlindSpotActivity(
            attempts: blindSpotAttempts,
            successes: blindSpotSuccesses,
            emptyResults: blindSpotEmptyResults,
            failures: blindSpotFailures,
            lastSuccessAt: blindSpotLastSuccessAt,
            lastFailureAt: blindSpotLastFailureAt,
            paidProbeTick: backgroundSpendState.paidProbeTick,
            lastAttemptID: blindSpotLastAttemptID,
            lastBackendCorrelationID: blindSpotLastBackendCorrelationID,
            lastProbeIDs: blindSpotLastProbeIDs,
            lastStartedAt: blindSpotLastStartedAt,
            lastCompletedAt: blindSpotLastCompletedAt,
            lastResultCount: blindSpotLastResultCount,
            lastOutcome: blindSpotLastOutcome,
            lastGrounded: blindSpotLastGrounded,
            lastProvider: blindSpotLastProvider,
            lastModel: blindSpotLastModel,
            lastProviderLatencyMs: blindSpotLastProviderLatencyMs,
            lastChargedCredits: blindSpotLastChargedCredits,
            lastCacheHit: blindSpotLastCacheHit,
            lastProviderAttemptCount: blindSpotLastProviderAttemptCount,
            lastProviderAttempts: blindSpotLastProviderAttempts)
    }

    private func recordBlindSpotExecution(_ execution: BrainstormService.ExecutionTrace) {
        blindSpotLastBackendCorrelationID = execution.correlationId
        blindSpotLastProvider = execution.provider
        blindSpotLastModel = execution.model
        blindSpotLastProviderLatencyMs = execution.latencyMs
        blindSpotLastChargedCredits = execution.chargedCredits
        blindSpotLastCacheHit = execution.cacheHit
        blindSpotLastProviderAttemptCount = execution.attemptCount
        blindSpotLastProviderAttempts = Array((execution.attempts ?? []).prefix(8))
    }

    /// Called only by the authorized live-test hook (or the unit-test process)
    /// after it has installed the compiled synthetic goal. Merely running a dev
    /// build never arms content capture.
    func beginSyntheticBlindSpotTraceCapture(goal: String) {
        guard (Config.isDevBuild || Self.isUnderTest),
              goal == LiveTestHooks.syntheticBlindSpotGoal else { return }
        syntheticBlindSpotTraceGoal = goal
        lastSyntheticBlindSpotTrace = nil
    }

    func syntheticBlindSpotTrace() -> BlindSpotDevTrace? {
        lastSyntheticBlindSpotTrace
    }

    /// Narrow diagnostic seam for deterministic scheduler tests.
    func blindSpotGenerationForTesting() -> Int? {
        Self.isUnderTest ? blindSpotGeneration : nil
    }

    /// The connector query the last scan asked for (item 10, design #2), test-only:
    /// the consume-once contract — captured from one outcome, spent or dropped by
    /// the next scan, never carried further — is otherwise unobservable.
    func blindSpotPendingProbeQueryForTesting() -> String? {
        Self.isUnderTest ? blindSpotPendingProbeQuery : nil
    }

    func forceBlindSpotRefreshForTesting() {
        guard Self.isUnderTest else { return }
        blindSpotRefreshDebounce?.cancel()
        blindSpotRefreshRequested = true
    }

    func blindSpotSchedulerStateForTesting() -> (
        evaluations: Int, charactersAtLastRun: Int?
    )? {
        guard Self.isUnderTest else { return nil }
        return (
            blindSpotCycleEvaluations,
            backgroundSpendState.charactersAtLastRun["brainstorm"])
    }

    /// Mirror of Config.brainstormEnabled (the blind-spot probe gate). Mutate
    /// only through setBlindSpotsEnabled so a mid-call flip starts/stops the
    /// probe loop. The permanent switch lives in Settings; the sidebar offers
    /// only a per-call snooze (suggestionsSnoozedThisCall).
    @Published private(set) var blindSpotsEnabled: Bool = Config.brainstormEnabled
    @Published private(set) var agendaCheckingEnabled: Bool = Config.agendaCheckerEnabled
    @Published private(set) var liveFactCheckingEnabled: Bool = Config.factCheckDuringCallsEnabled
    @Published private(set) var rhetoricWatchEnabled: Bool = Config.rhetoricDuringCallsEnabled
    @Published private(set) var facilitationWatchEnabled: Bool = Config.facilitationDuringCallsEnabled

    /// Permanent blind-spot switch (Settings). Flipping during a recording
    /// takes effect immediately: ON starts the probe loop, OFF cancels it
    /// (existing suggestions stay visible).
    func setBlindSpotsEnabled(_ enabled: Bool) {
        // SwiftUI can write the selected value more than once while Settings is
        // reconciling. Restarting here cancels an in-flight paid request and
        // creates a second generation even though the user changed nothing.
        guard enabled != blindSpotsEnabled || enabled != Config.brainstormEnabled else {
            return
        }
        let wasAutomatic = automaticCopilotEnabled
        Config.brainstormEnabled = enabled
        blindSpotsEnabled = enabled
        reconcileCopilotAccounting(previouslyEnabled: wasAutomatic)
        guard isRecording else { return }
        if enabled {
            startBrainstorming()
        } else {
            stopBrainstorming()
        }
    }

    func setAgendaCheckingEnabled(_ enabled: Bool) {
        let wasAutomatic = automaticCopilotEnabled
        Config.agendaCheckerEnabled = enabled
        agendaCheckingEnabled = enabled
        reconcileCopilotAccounting(previouslyEnabled: wasAutomatic)
        guard isRecording else { return }
        enabled ? startAgendaChecking() : stopAgendaChecking()
        if blindSpotsEnabled { blindSpotScheduleRefreshRequested = true }
    }

    func setFactCheckDuringCallsEnabled(_ enabled: Bool) {
        let wasAutomatic = automaticCopilotEnabled
        Config.factCheckDuringCallsEnabled = enabled
        liveFactCheckingEnabled = enabled
        reconcileCopilotAccounting(previouslyEnabled: wasAutomatic)
        guard isRecording else { return }
        enabled ? startFactCheckLoop() : stopFactCheckLoop()
        if blindSpotsEnabled { blindSpotScheduleRefreshRequested = true }
    }

    func setRhetoricDuringCallsEnabled(_ enabled: Bool) {
        let wasAutomatic = automaticCopilotEnabled
        Config.rhetoricDuringCallsEnabled = enabled
        rhetoricWatchEnabled = enabled
        reconcileCopilotAccounting(previouslyEnabled: wasAutomatic)
        guard isRecording else { return }
        enabled ? startRhetoricLoop() : stopRhetoricLoop()
        if blindSpotsEnabled { blindSpotScheduleRefreshRequested = true }
    }

    func setFacilitationDuringCallsEnabled(_ enabled: Bool) {
        let wasAutomatic = automaticCopilotEnabled
        Config.facilitationDuringCallsEnabled = enabled
        facilitationWatchEnabled = enabled
        reconcileCopilotAccounting(previouslyEnabled: wasAutomatic)
        guard isRecording else { return }
        enabled ? startFacilitationLoop() : stopFacilitationLoop()
        if blindSpotsEnabled { blindSpotScheduleRefreshRequested = true }
    }

    /// Per-call quiet mode ("Pause for this call") — deliberately NOT the
    /// permanent Config switch, so there is nothing to remember to re-enable:
    /// resetForNewRecording clears it and the next call starts suggesting
    /// again. Snoozing cancels the running probe loop; existing cards stay.
    @Published private(set) var suggestionsSnoozedThisCall = false

    func snoozeSuggestionsForCall() {
        guard !suggestionsSnoozedThisCall else { return }
        suggestionsSnoozedThisCall = true
        stopBrainstorming()
    }

    func resumeSuggestionsThisCall() {
        guard suggestionsSnoozedThisCall else { return }
        suggestionsSnoozedThisCall = false
        if isRecording { startBrainstorming() }
    }

    /// Upcoming calendar meetings (soonest first) for the Focus panel. Populated
    /// by the reminder poll; empty when reminders are off or Google isn't connected.
    @Published var upcomingMeetings: [UpcomingMeeting] = []

    /// Briefs keyed by Google event id. Empty until a meeting comes inside the
    /// lead window; a meeting the user never gets to simply never gets one.
    @Published var meetingBriefs: [String: MeetingBrief] = [:]
    /// Event ids already requested this session, so a panel refresh does not
    /// re-ask. The server would answer from its cache for free, but the round
    /// trip is still latency on a panel that is already showing the answer.
    private var briefsRequested: Set<String> = []

    /// Provisional (interim) transcript text per source — shown dimmed and
    /// replaced when the finalized line arrives.
    @Published var provisional: [TranscriptSource: String] = [:]

    /// Provisional lines to render (system first, then mic), non-empty only.
    /// The mic copy of a sentence the system track is already carrying is an
    /// echo (speakers → mic), not a second speaker — shown once.
    var provisionalLines: [ProvisionalLine] {
        TranscriptDeduplicator.withoutEchoedProvisionals(
            [TranscriptSource.system, .mic].compactMap { source in
                guard let text = provisional[source], !text.isEmpty else { return nil }
                return ProvisionalLine(source: source, text: text)
            })
    }

    /// Editable meeting title (Granola-style). Empty shows a placeholder.
    @Published var meetingTitle: String = ""

    /// Internal AI/research context. Prefer the typed Co-pilot goal, else the
    /// meeting name, else a transcript/calendar-inferred suggestion so blind
    /// spots can run before the user taps "Use".
    var effectiveCallGoal: String {
        GoalSuggestion.resolveEffective(
            callGoal: callGoal,
            meetingTitle: meetingTitle,
            suggestedGoal: suggestedGoal)
    }
    /// Seconds since recording started. The observable clock is deliberately a
    /// child object so its ticks refresh only the four small timer labels.
    let recordingClock = RecordingClockState()
    var elapsed: TimeInterval { recordingClock.elapsed }
    /// High-frequency decorative state is isolated from this monolithic model.
    let audioMeter = AudioMeterState()
    private let micLevelUpdateGate = AudioLevelUpdateGate()
    /// When this session window was opened, shown under the title.
    let sessionDate = Date()

    /// Fireflies and Notion connect through the keyless MCP path
    /// (Settings → Connected apps); this flag drives the import spinner.
    @Published var firefliesImporting = false

    /// Google Desktop OAuth credentials come from build-time `Secrets` (mac/.env).
    @Published var googleConnected = false
    @Published var googleConnecting = false
    @Published var googleConnectionError: String?
    @Published var calendarImporting = false

    /// Wheespr account session (email OTP). Enables managed backend features.
    @Published var wheesprConnected = false {
        didSet {
            if wheesprConnected != oldValue { rebuildPromptWorkflows() }
        }
    }
    @Published var wheesprEmail: String?

    /// Why the account session went away, when the user did not ask it to.
    ///
    /// A silent sign-out is the worst kind: the connectors stay attached, so
    /// the app still looks signed in, and the only symptom is a feature quietly
    /// declining to work. Reported as "credits unavailable in the account where
    /// apps are connected" — a missing session diagnosed as a billing bug.
    enum SignedOutReason: Equatable {
        /// Found signed out at launch while a previous account was on record.
        case sessionMissingAtLaunch
        /// A token refresh came back 401.
        case expired

        var message: String {
            switch self {
            case .sessionMissingAtLaunch:
                return "Вход в аккаунт слетел. Подключённые приложения это не затронуло. Войдите снова, если нужна синхронизация; запись и поиск по звонкам работают и без входа."
            case .expired:
                return "Вход в аккаунт истёк. Войдите снова, если нужна синхронизация; запись и поиск по звонкам работают и без входа."
            }
        }
    }

    struct SignedOutNotice: Equatable {
        let reason: SignedOutReason
        /// The account we were last signed in as, so the notice can name it.
        let email: String?

        var message: String {
            guard let email, !email.isEmpty else { return reason.message }
            return "\(reason.message) Последний вход — \(email)."
        }
    }

    /// Set when the session disappeared unexpectedly; nil once acknowledged or
    /// signed back in. Never set by a deliberate sign-out.
    @Published var signedOutNotice: SignedOutNotice?

    func dismissSignedOutNotice() { signedOutNotice = nil }

    /// Test seams. Both paths that raise the notice are private — one runs on a
    /// 401 refresh, the other during launch restore — and neither is reachable
    /// from a unit test without a live backend or a real Keychain.
    func noteSignedOutForTesting(_ reason: SignedOutReason) {
        guard Self.isUnderTest else { return }
        noteSignedOut(reason)
    }

    /// Test seam: place the stop instant directly. `stopRecording` is private
    /// and tears down real audio hardware, so the boundary it establishes
    /// cannot otherwise be exercised in a unit test.
    func applyTestStopInstant(_ date: Date?) {
        guard Self.isUnderTest else { return }
        recordingStoppedAt = date
    }

    /// Hardware-free seam for post-call retention/lifecycle regressions.
    func applyTestLocalFinalPassRetention(
        samples: [Int16],
        startedAt: Date,
        preparedModel: String? = "base",
        optedIn: Bool = true,
        serverDiarizationEligible: Bool = false,
        localDiarization: Bool = false
    ) {
        guard Self.isUnderTest else { return }
        sessionRecorder.reset()
        sessionRecorder.append(samples)
        sessionRecorder.seal()
        sessionRetainedAudioStart = startedAt
        sessionAudioStart = (optedIn || localDiarization) ? startedAt : nil
        sessionAudioStartSample = 0
        sessionRetainedAudioTimelineValid = true
        localFinalPassOptedInForSession = optedIn
        localDiarizationOptedInForSession = localDiarization
        localDiarizationContinuityValid = localDiarization
        serverDiarizationEligibleForSession = serverDiarizationEligible
        localFinalPassContinuityValid = optedIn
        activeSessionPreparedLocalWhisperModel = preparedModel
        activeRecordingSettings = RecordingSettingsSnapshot(
            engine: .local,
            language: "en",
            localModel: preparedModel ?? "base",
            microphoneNoiseSuppression: false,
            glossary: "",
            assemblyDiarization: false,
            localDiarization: localDiarization)
    }

    var retainedAudioSampleCountForTesting: Int {
        Self.isUnderTest ? sessionRecorder.retainedSampleCount : 0
    }

    var retainedAudioOriginsForTesting: (full: Date?, local: Date?) {
        guard Self.isUnderTest else { return (nil, nil) }
        return (sessionRetainedAudioStart, sessionAudioStart)
    }

    var retainedAudioTimelineValidForTesting: Bool {
        Self.isUnderTest && sessionRetainedAudioTimelineValid
    }

    func truncateRetainedAudioForTesting(maxSamples: Int) {
        guard Self.isUnderTest else { return }
        sessionRecorder.setMaximumSamplesForTesting(maxSamples)
    }

    func handleSessionExpiredForTesting() {
        guard Self.isUnderTest else { return }
        handleSessionExpired()
    }

    /// Record an unexpected sign-out, once. Later reasons do not overwrite an
    /// unacknowledged notice — the first one already told the whole story.
    private func noteSignedOut(_ reason: SignedOutReason) {
        guard signedOutNotice == nil else { return }
        let email = Config.lastSignedInEmail
        guard email != nil else { return }   // never signed in here: not a sign-OUT
        signedOutNotice = SignedOutNotice(reason: reason, email: email)
        Log.general.notice("signed out unexpectedly — \(String(describing: reason), privacy: .public)")
    }

    @Published var authWorking = false
    /// Email awaiting its code — drives the sign-in sheet's second step.
    @Published var pendingAuthEmail: String?

    /// Sign-in is only offered when a backend is configured to talk to.
    var wheesprAvailable: Bool {
        !Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var effectiveGoogleClientID: String {
        Config.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var effectiveGoogleClientSecret: String {
        Config.googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var hasGoogleClientID: Bool { !effectiveGoogleClientID.isEmpty }
    var hasGoogleClientSecret: Bool { !effectiveGoogleClientSecret.isEmpty }
    var hasGoogleClient: Bool { hasGoogleClientID && hasGoogleClientSecret }
    /// What the "Continue with Google" button needs — the sign-in client, which
    /// falls back to the connector one when no dedicated client is configured.
    var hasGoogleSignInClient: Bool {
        !Config.googleSignInClientID.isEmpty && !Config.googleSignInClientSecret.isEmpty
    }

    // One prompt-grounding switch for every connected app. It never revokes
    // authorization; it only controls whether app context enters prompt runs.
    /// Connected apps the user has muted for now — still connected, still
    /// authorised, deliberately not consulted.
    ///
    /// Separate from `useConnectedAppsInPrompts`, which pauses ALL of them.
    /// The two answer different questions: "not right now" versus "not this
    /// app on this call", and collapsing them would force a user who wants
    /// Notion but not Linear to disconnect Linear and redo its OAuth.
    /// What the free plan grants every month, from the live plan catalogue.
    ///
    /// Nil until the catalogue loads, and the UI degrades to "sign up for more
    /// every month" rather than printing a number this app guessed. The number
    /// is an entitlement the server enforces; a stale constant compiled into
    /// the client would eventually promise something it cannot deliver.
    @Published private(set) var freeTierMonthlyCredits: Int?

    /// Best-effort, silent. Only worth asking while the user is on a trial —
    /// that is the only place the number is shown.
    func loadFreeTierAllowanceIfNeeded() async {
        guard freeTierMonthlyCredits == nil,
              Config.wheesprSession?.isDeviceTrial == true else { return }
        guard let plans = try? await PaywallAPI.plans() else { return }
        freeTierMonthlyCredits = plans
            .first { $0.id == "free" }?.allowances.computeCredits
    }

    /// The first-launch device-trial claim is still in flight.
    ///
    /// A brand-new user has no session, so every signed-out surface renders its
    /// "sign in" state for the second the claim takes — then retracts it when
    /// credits arrive. Nothing is wrong during that second; an answer is on its
    /// way, and the UI should say so rather than guess the pessimistic one.
    @Published var trialClaimInFlight = false

    @Published private(set) var mutedAppIDs: Set<String> = Config.mutedConnectedApps

    func isAppMuted(_ id: String) -> Bool { mutedAppIDs.contains(id) }

    /// Mute or unmute one app. Rebuilds prompt workflows, because which apps a
    /// workflow can reach is part of how it is assembled — without this the
    /// chips keep offering a source the run will now skip.
    func setApp(_ id: String, muted: Bool) {
        var next = mutedAppIDs
        if muted { next.insert(id) } else { next.remove(id) }
        guard next != mutedAppIDs else { return }
        mutedAppIDs = next
        Config.mutedConnectedApps = next
        rebuildPromptWorkflows()
    }

    @Published var useConnectedAppsInPrompts: Bool = Config.connectedAppsGroundingEnabled {
        didSet {
            Config.connectedAppsGroundingEnabled = useConnectedAppsInPrompts
            if useConnectedAppsInPrompts != oldValue { rebuildPromptWorkflows() }
        }
    }
    var groundApps: Bool {
        get { useConnectedAppsInPrompts }
        set { useConnectedAppsInPrompts = newValue }
    }
    var groundTeam: Bool {
        get { useConnectedAppsInPrompts }
        set { useConnectedAppsInPrompts = newValue }
    }
    @Published var groundLedger: Bool = Config.groundLedgerEnabled {
        didSet {
            Config.groundLedgerEnabled = groundLedger
            if groundLedger != oldValue { rebuildPromptWorkflows() }
        }
    }

    /// Follow-up actions distilled from the live run. When a new prompt begins,
    /// `archiveLiveExchange` moves these onto that completed exchange before the
    /// live slot is cleared, so previously offered buttons remain usable.
    @Published var followUpPrompts: [QuickPrompt] = []

    /// The last non-empty follow-up chips, kept so a new answer that produces
    /// none does not leave the row permanently empty.
    ///
    /// Pressing a chip starts a new run, which archives the current chips with
    /// their exchange and clears the live row. If that run's follow-up
    /// generation then returns nothing — it is a best-effort model call that
    /// can fail or come back blank — the row stayed empty for the rest of the
    /// session, so USING a suggestion was what removed the other suggestions.
    /// Chips resolve to prompts run against the current conversation, not
    /// actions bound to one answer, so carrying them forward is safe.
    var carriedFollowUpPrompts: [QuickPrompt] = []
    /// Monotonic signal that a silent, potentially billable follow-up request
    /// finished. Credit UI observes this because the primary streaming flag
    /// turns off before the follow-up request begins.
    @Published private(set) var computeUsageRevision = 0
    private var followUpTask: Task<Void, Never>?
    /// Tier 2 clarification assessment. Cancelled by a newer request so a stale
    /// verdict can never raise a card over the prompt that superseded it.
    private var clarifyingTask: Task<Void, Never>?
    /// Model pass proposing answer actions. Cancelled by the next run so a
    /// stale proposal cannot attach itself to a newer answer.
    private var answerProposalTask: Task<Void, Never>?

    /// Publish after any automatic model request returns. The server may reserve
    /// credits even when the response fails or the local task is canceled, so
    /// the signal belongs in `defer`, around the request attempt itself.
    private func trackingComputeUsage<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        defer { computeUsageRevision &+= 1 }
        do {
            return try await operation()
        } catch {
            // Every background watch spend funnels through here, so one place
            // latches the server's "pool exhausted" 429 — the loops used to
            // `try?` it away and re-dial every cadence for the rest of the
            // call, which read as "credits are over but blind spots still run".
            noteQuotaExhaustion(error)
            throw error
        }
    }

    /// The server's quota rejection for this period, once seen. Latched rather
    /// than re-derived: an empty pool does not refill mid-call, so the watches
    /// stop instead of paying the backend to keep saying no.
    @Published private(set) var copilotQuotaMessage: String?

    /// Identified, dev-build-only modal used by the live playback suite. It is
    /// deliberately separate from billing/error state: a synthetic mandatory
    /// information prompt must never overwrite or clear a genuine 429.
    struct LiveTestMandatoryNotice: Identifiable, Equatable {
        let id: String
        let message: String
    }
    @Published private(set) var liveTestMandatoryNotice: LiveTestMandatoryNotice?

    @discardableResult
    func debugPresentMandatoryNotice(id: String, message: String) -> Bool {
        guard Config.isDevBuild, liveTestMandatoryNotice == nil, !id.isEmpty else {
            return false
        }
        liveTestMandatoryNotice = LiveTestMandatoryNotice(id: id, message: message)
        return true
    }

    @discardableResult
    func debugClearMandatoryNotice(id: String) -> Bool {
        guard Config.isDevBuild, liveTestMandatoryNotice?.id == id else { return false }
        liveTestMandatoryNotice = nil
        return true
    }

    private func noteQuotaExhaustion(_ error: Error) {
        guard copilotQuotaMessage == nil,
              let message = CreditExhaustion.quotaMessage(from: error) else { return }
        copilotQuotaMessage = message
        lastError = message
        Log.general.info("copilot quota latched — background watches stop for this session")
    }

    /// User-defined prompts shown alongside the built-in Quick Prompts.
    @Published var customPrompts: [QuickPrompt] = Config.customPrompts {
        didSet { if customPrompts != oldValue { Config.customPrompts = customPrompts } }
    }

    /// Saved context sets — reusable file+notes bundles for repeating calls.
    @Published var contextSets: [ContextSet] = Config.contextSets {
        didSet { if contextSets != oldValue { Config.contextSets = contextSets } }
    }

    /// Subscription tier (read-only in the UI — set by plan/behaviour, not chosen)
    /// and the selected model within it.
    @Published var currentTier: Tier = Config.currentTier
    @Published var selectedModelID: String = Config.selectedModelID {
        didSet { if selectedModelID != oldValue { Config.selectedModelID = selectedModelID } }
    }

    /// Why the plan is what it is / what unlocks next (behaviour-driven).
    /// What the button bar is allowed to offer right now.
    ///
    /// Assembled here rather than in the view so the resolver sees one
    /// consistent snapshot — tier, connected apps and the credit pool read at
    /// the same moment — and so the rules are testable without a view.
    var quickPromptConfiguration: QuickPromptResolver.Configuration {
        QuickPromptResolver.Configuration(
            tier: currentTier,
            connectorKeywords: connectedConnectorKeywords,
            // A quota message is the app already knowing the pool is spent.
            hasComputeCredits: copilotQuotaMessage == nil)
    }

    /// Keywords of every connected app that is actually IN USE — muted apps
    /// count as absent, so a prompt is never offered on the strength of an app
    /// the user just silenced. The rule lives in the resolver, beside the
    /// prompt requirements it feeds.
    var connectedConnectorKeywords: Set<String> {
        guard let mcp else { return [] }
        let connected = (MCPCatalog.builtIn + MCPCatalog.preRegistered)
            .filter { mcp.isConnected($0.id) }
        return QuickPromptResolver.connectorKeywords(connected: connected, muted: mutedAppIDs)
    }

    var tierStatus: String { TierPolicy.status(stats: UsageTracker.stats, tier: currentTier) }

    var tariffAllowance: TariffAllowance { TariffAllowance.forTier(currentTier) }

    var copilotSecondsRemaining: Int {
        tariffAllowance.remainingCopilotSeconds(
            usedSeconds: UsageTracker.copilotSecondsThisMonth,
            activeSeconds: isRecording ? copilotActiveTimeMeter.seconds(at: Date()) : 0
        )
    }

    var groundedCyclesRemaining: Int {
        max(0, tariffAllowance.groundedCycles - UsageTracker.groundedCyclesThisMonth)
    }

    private var automaticCopilotEnabled: Bool {
        Config.brainstormEnabled
            || Config.factCheckDuringCallsEnabled
            || Config.rhetoricDuringCallsEnabled
            || (effectiveRecordingContextKind == .meeting
                && (Config.agendaCheckerEnabled || Config.facilitationDuringCallsEnabled))
    }

    /// Called after one Settings write. Multiple watches count as one union of
    /// active time, so changing a second switch while another remains on does
    /// not open or close an accounting interval.
    private func reconcileCopilotAccounting(previouslyEnabled: Bool,
                                            at date: Date = Date()) {
        guard isRecording, previouslyEnabled != automaticCopilotEnabled else { return }
        copilotActiveTimeMeter.transition(to: automaticCopilotEnabled, at: date)
    }

    private var canRunAutomaticCopilot: Bool {
        // The local seconds estimate AND the server's own verdict: the server
        // is authoritative, and once it says the pool is empty the watches
        // stay quiet for the rest of the session. A user-requested answer owns
        // foreground priority: starting another ambient provider request while
        // it is streaming increases tail latency and spends context on the one
        // moment where the user is explicitly waiting. Existing background
        // work is allowed to finish; subsequent wakes yield until the visible
        // exchange terminalizes.
        automaticCopilotEnabled
            && !aiStreaming
            && copilotSecondsRemaining > 0
            && copilotQuotaMessage == nil
    }

    /// Recompute the plan after a behaviour change; clamp the model if it dropped.
    private func refreshTier() {
        let tier = Config.currentTier
        guard tier != currentTier else { return }
        currentTier = tier
        // A plan change comes with its own allowances — the old rejection no
        // longer describes them.
        copilotQuotaMessage = nil
        if !Config.selectedModel.isAvailable(for: tier) {
            selectedModelID = LLMCatalog.defaultModel(for: tier).id
        }
    }

    /// Bumped to ask the main window to present the setup guide again.
    ///
    /// A token rather than a Bool because the request must survive the sheet
    /// being dismissed and then asked for a second time: a flag set to `true`
    /// twice publishes nothing the second time, and the guide would silently
    /// refuse to reopen.
    @Published var onboardingReplayToken = 0

    /// Raised once, when the first real meeting ends, to ask how it went.
    /// ``FirstMeetingPrompt`` owns whether it may be raised at all; this is only
    /// the signal to the view, so lowering it does not reopen the question.
    @Published var showFirstMeetingFeedback = false

    /// Replay the first-run setup guide from Settings.
    ///
    /// Onboarding is gated on `Config.onboardingStep`, which records the last
    /// step FINISHED — so once it is set the sheet never returns. Right for a
    /// first run, wrong afterwards: a user who skipped the capture check had no
    /// route back to it short of deleting a preference by hand.
    ///
    /// The setup card is un-dismissed alongside it (its own `@AppStorage` key in
    /// SetupCard.swift), because the two are one piece of onboarding split
    /// across two surfaces — restoring the sheet while leaving the sidebar
    /// checklist hidden would replay half the flow.
    func replayOnboarding() {
        Config.onboardingStep = nil
        UserDefaults.standard.set(false, forKey: "onboarding.setupCardDismissed")
        onboardingReplayToken &+= 1
    }

    /// Adopt a freshly redeemed entitlement: re-read the plan and drop any
    /// quota rejection the previous (unentitled) plan produced. Used by the
    /// dev-build live-test hooks after `PaywallAPI.deviceRedeem`, so a suite
    /// runs against a real plan instead of asserting against 401 bodies.
    func refreshEntitlementAfterRedeem() {
        copilotQuotaMessage = nil
        wheesprConnected = Config.wheesprSession != nil
        wheesprEmail = Config.wheesprSession?.email
        refreshTier()
        computeUsageRevision &+= 1
    }

    /// Place the workspace at an arbitrary point in its state space.
    ///
    /// The combinatorial suite walks every combination of the flags the UI
    /// gates on, which needs to write `aiResponsePrompt` and `aiHistory` —
    /// both `private(set)` because nothing in the app may set them directly.
    /// One guarded seam is a smaller compromise than widening those to
    /// internal: it does nothing outside a test process, so no production path
    /// can reach it even by mistake.
    func applyTestWorkspace(prompt: String? = nil,
                            answer: String? = nil,
                            history: [AIExchange]? = nil,
                            contextFiles: [ImportedContextFile]? = nil,
                            recording: Bool? = nil) {
        guard Self.isUnderTest else { return }
        if let answer { aiResponse = answer }
        if let prompt { aiResponsePrompt = prompt }
        if let history { aiHistory = history }
        if let contextFiles { self.contextFiles = contextFiles }
        if let recording {
            if !recording, isRecording { stopBrainstorming() }
            status = recording ? .recording : .idle
        }
    }

    /// Narrow test seam for the connector-economy boundary. Production cannot
    /// reach it: outside a test process it returns before connector or model
    /// work. Keeping this wrapper beside the other guarded workspace seam lets
    /// regression tests prove automatic Blind Spot retrieval does not invoke
    /// query-derivation LLM work while interactive workflows still may.
    func groundingSnippetsForTesting(workflow: PromptWorkflow,
                                     promptID: String,
                                     query: String,
                                     maxSources: Int,
                                     deriveQuery: Bool) async -> [GroundingSnippet] {
        guard Self.isUnderTest else { return [] }
        return await groundingSnippets(
            for: workflow,
            promptID: promptID,
            query: query,
            runGeneration: -1,
            maxSources: maxSources,
            deriveQuery: deriveQuery)
    }

    /// Dev builds only (Settings ▸ Account & Privacy ▸ Developer): preview any
    /// plan without paying. `nil` returns to the real entitlement. No-op in
    /// distribution builds.
    func setDevTierOverride(_ tier: Tier?) {
        guard Config.isDevBuild else { return }
        Config.devTierOverride = tier
        refreshTier()
    }

    /// Keys for transcription providers now come from build-time `Secrets`.
    @Published var diarizing = false
    @Published private(set) var localDiarizationRunning = false
    @Published private(set) var localDiarizationProgress: Double = 0
    @Published private(set) var localDiarizationNote: String?
    /// Fireflies + Whisper LLM merge in progress (post-call or manual).
    @Published var enhancingTranscript = false
    /// The pending post-call Fireflies merge, waiting out Fireflies' own
    /// processing time. Held so a new recording can cancel it.
    private var firefliesEnhanceTask: Task<Void, Never>?
    /// Explicit enhancement is tracked too: cancellation is cooperative, but
    /// the session/revision guards below also stop a non-cooperative fetch from
    /// committing into a later call.
    private var manualFirefliesEnhanceTask: Task<Void, Never>?
    /// Context-menu import is a third Fireflies mutation path. Keep its inner
    /// task so Clear/restore/new-call can cancel it even though the SwiftUI
    /// button's outer Task is not retained anywhere.
    private var firefliesImportTask: Task<Void, Never>?
    /// Cancellation is not enough for an MCP/provider that is already inside
    /// an await. Advancing this revision makes every captured mutation identity
    /// stale synchronously on clear, restore, or new-call start.
    private var firefliesMutationRevision = 0

    /// A free Fireflies merge is already scheduled for this call.
    ///
    /// Matters because the cloud pass costs transcription credits and uploads
    /// the audio again, while Fireflies recorded the same meeting itself and
    /// the merge is automatic and already paid for. Offering the paid action as
    /// prominently as the free one that is about to run anyway is a way of
    /// charging someone for work in progress.
    var firefliesEnhancePending: Bool {
        firefliesEnhanceTask != nil && !enhancingTranscript
    }
    /// Short status from the last successful enhancement (shown near the transcript).
    @Published var transcriptEnhanceNote: String?

    /// Text of the previous transcription window, per track, so ChunkStitcher
    /// can cut the overlap seam. Not published: it is plumbing, and rendering
    /// never reads it.
    var lastChunkText: [TranscriptSource: String] = [:]

    var hasAssemblyAI: Bool {
        !Config.assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True once a finished recording is available to (re)diarize.
    /// Server-side speaker labels need only an account — the backend holds the
    /// key (D34's BYO requirement was lifted by gpt-4o-transcribe-diarize).
    var canDiarizeOnServer: Bool {
        Config.llmViaBackend && wheesprConnected
    }

    /// Where the audio actually goes, for the button that sends it.
    ///
    /// The two paths use different vendors and the UI previously named only
    /// AssemblyAI, which is the BYO-key FALLBACK. A signed-in user's audio goes
    /// to the backend and on to OpenAI. Telling someone their meeting is going
    /// to one company when it is going to another is wrong however it is
    /// worded, so this is derived from the branch that will actually run.
    var diarizeDestination: String {
        Self.diarizeDestination(onServer: canDiarizeOnServer)
    }

    /// Pure, so the claim can be tested without standing up an app state or
    /// touching the globals that decide which path runs. `nonisolated` because
    /// it reads nothing — requiring the main actor for a string lookup would be
    /// isolation for its own sake.
    nonisolated static func diarizeDestination(onServer: Bool) -> String {
        onServer ? "Cruxwing's backend (OpenAI)" : "AssemblyAI with your own key"
    }

    var canDiarize: Bool {
        (canDiarizeOnServer || (hasAssemblyAI && Config.assemblyAIDiarizationEnabled))
            && sessionRetainedAudioTimelineValid
            && !sessionRecorder.isEmpty
            && status != .recording
            && !diarizing
    }

    /// Fireflies is connected and there is a local transcript worth merging.
    var canEnhanceWithFireflies: Bool {
        (firefliesTranscriptProvider != nil || (mcp?.prefersMCP("fireflies") ?? false))
            && !transcript.isEmpty
            && status == .idle
            && !enhancingTranscript
            && !diarizing
            && !localRetranscribing
            && !firefliesImporting
    }

    /// Deepgram is usable with a baked/BYO key or — keyless — through the
    /// backend's credit-metered token grant (signed-in only).
    var hasDeepgram: Bool { Config.engineAvailable(.deepgram) }

    /// Full indexed context for inspection and context-set bookkeeping. Model
    /// requests must use `promptContext(query:)`, which retrieves a bounded
    /// relevant slice from folders.
    var composedContext: String {
        var parts: [String] = []
        for file in contextFiles {
            parts.append("=== \(file.name) ===\n\(file.text)")
        }
        // Folder files carry their folder in the header. Without it the model
        // sees "README.md" twice from two attached folders and cannot tell which
        // project either belongs to.
        for folder in contextFolders {
            for file in folder.files {
                parts.append("=== \(folder.name)/\(file.name) ===\n\(file.text)")
            }
        }
        let notes = contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("=== Notes ===\n\(notes)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Context actually attached to one model request. Individually selected
    /// files and notes preserve their existing behavior; recursive folders use
    /// query-time retrieval so a project index does not become a 240k-character
    /// tax on every chat message.
    func promptContext(query: String) -> String {
        var parts = contextFiles.map { "=== \($0.name) ===\n\($0.text)" }
        let folderContext = ContextFolderRetriever.render(
            folders: contextFolders, query: query)
        if !folderContext.isEmpty { parts.append(folderContext) }
        let notes = contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("=== Notes ===\n\(notes)") }
        return parts.joined(separator: "\n\n")
    }

    /// Glossary candidates from an imported past-call transcript.
    ///
    /// Held to a stricter bar than a document, because a Fireflies transcript is
    /// itself ASR output. A written agenda can name a term once and mean it; a
    /// machine transcript saying something once may have misheard it, and a
    /// corruption promoted into the glossary teaches the NEXT recording to
    /// repeat it — the failure mode measured when priming on the engine's own
    /// first pass. Requiring the term to recur is the cheapest evidence that it
    /// is real.
    ///
    /// Unlike that first pass, this is a DIFFERENT engine, so its mistakes do
    /// not correlate with the local one's. That is what makes it usable at all.
    /// Fireflies transcript quality has not been measured against this corpus,
    /// so the repetition bar is doing real work rather than being belt-and-braces.
    func proposeGlossaryFromPastTranscript(_ session: SavedSession,
                                           existingGlossary: String? = nil) {
        let text = session.entries.map(\.text).joined(separator: "\n")
        guard text.count > 200 else { return }

        let existing = Set(Glossary.terms(from: existingGlossary ?? Config.transcriptionGlossary)
            .map(ConnectedGlossarySuggestionService.canonicalKey))
        let candidates = ConnectedGlossarySuggestionService.extractCandidates(
            from: [(name: session.title, text: text)],
            excluding: existing.union(connectedGlossaryRejectedKeys),
            minimumOccurrences: Self.pastTranscriptMinimumOccurrences)
        guard !candidates.isEmpty else { return }

        var known = Set(connectedGlossarySuggestions.map(\.id))
        let additions = candidates.prefix(Self.unrankedGlossaryProposalLimit)
            .filter { known.insert($0.id).inserted }
        guard !additions.isEmpty else { return }

        connectedGlossarySuggestions.append(contentsOf: additions)
        if connectedGlossarySuggestionStatus == .idle {
            connectedGlossarySuggestionStatus = .ready
        }
    }

    /// Twice, in one transcript, before a machine-transcribed term is offered.
    static let pastTranscriptMinimumOccurrences = 2

    /// Glossary candidates from connected-app data the app already fetched.
    ///
    /// The Settings button spends a grounded research cycle and a fast-model
    /// call to fetch and RANK candidates, which is why it is manual — and why
    /// in practice it is never pressed. The local extractor behind it is free;
    /// the model only reorders what it finds. So whenever grounding snippets
    /// are fetched for some other purpose, mine them here at zero marginal
    /// cost and propose the result.
    ///
    /// Connected-app data is the best source available by the rule the
    /// measurements set: rich, written by people, and from outside the audio.
    func proposeGlossaryFromConnectedSnippets(_ snippets: [GroundingSnippet],
                                              existingGlossary: String? = nil) {
        guard !snippets.isEmpty else { return }
        let existing = Set(Glossary.terms(from: existingGlossary ?? Config.transcriptionGlossary)
            .map(ConnectedGlossarySuggestionService.canonicalKey))
        // boundedSources, not a hand-rolled map: it strips credentials,
        // identities and links BEFORE clipping, and applies the same source and
        // character caps the ranked path uses. A connector payload can contain
        // message bodies, and none of that should reach a suggestion list.
        let candidates = ConnectedGlossarySuggestionService.extractCandidates(
            from: ConnectedGlossarySuggestionService.boundedSources(snippets),
            excluding: existing.union(connectedGlossaryRejectedKeys))
        guard !candidates.isEmpty else { return }

        // Unranked, so cap harder than the ranked path: without the model to
        // order them, a long list is a long list of maybes.
        var known = Set(connectedGlossarySuggestions.map(\.id))
        let additions = candidates.prefix(Self.unrankedGlossaryProposalLimit)
            .filter { known.insert($0.id).inserted }
        guard !additions.isEmpty else { return }

        connectedGlossarySuggestions.append(contentsOf: additions)
        if connectedGlossarySuggestionStatus == .idle {
            connectedGlossarySuggestionStatus = .ready
        }
    }

    /// How many unranked candidates to propose from already-fetched data.
    /// The Settings path ranks with a model and can afford more; this one
    /// cannot, and a wall of unsorted suggestions gets dismissed wholesale.
    static let unrankedGlossaryProposalLimit = 12

    /// Company names of the people on the calendar, proposed as glossary
    /// terms before the call starts.
    ///
    /// An attendee's employer is the counterparty name most likely to be
    /// spoken in the first minute, and the calendar knows it before any
    /// document is attached: the domain of the invitee's email names it.
    /// Same derivation as the sign-in seeding (`EmailDomainGlossary`), but
    /// where the user's OWN company auto-applies, other people's companies
    /// are proposals — review-gated like every context suggestion, deduped
    /// against the glossary, and never re-proposed after a rejection. A
    /// freemail invitee contributes nothing, by construction.
    func proposeAttendeeDomainGlossarySuggestions() {
        guard !upcomingMeetings.isEmpty else { return }
        let existing = Set(Glossary.terms(from: Config.transcriptionGlossary)
            .map(ConnectedGlossarySuggestionService.canonicalKey))
        var known = Set(connectedGlossarySuggestions.map(\.id))
        var additions: [ConnectedGlossarySuggestion] = []
        for meeting in upcomingMeetings {
            for email in meeting.attendees {
                for company in EmailDomainGlossary.candidates(fromEmail: email) {
                    let key = ConnectedGlossarySuggestionService.canonicalKey(company)
                    guard !existing.contains(key),
                          !connectedGlossaryRejectedKeys.contains(key),
                          known.insert(key).inserted else { continue }
                    additions.append(ConnectedGlossarySuggestion(
                        term: company,
                        reason: "Attendee company on \(meeting.title)",
                        sources: [meeting.title]))
                }
            }
        }
        guard !additions.isEmpty else { return }
        connectedGlossarySuggestions.append(
            contentsOf: additions.prefix(Self.unrankedGlossaryProposalLimit))
        if connectedGlossarySuggestionStatus == .idle {
            connectedGlossarySuggestionStatus = .ready
        }
    }

    /// Glossary candidates mined from the documents the user attached.
    ///
    /// Measured: the decoder glossary is the largest accuracy lever on accented
    /// work calls — the right terms moved term recall from 0.53 to 0.93 — but
    /// only when the terms are CORRECT and come from outside the audio. A
    /// meeting title yields two or three and made WER worse; priming on the
    /// transcript reinforces the engine's own corruptions. Attached documents
    /// are the source that satisfies both conditions, and they cost nothing to
    /// read: the text is already extracted and in memory.
    ///
    /// Deterministic, so unlike the connected-app path this spends no model
    /// call. Suggestions only — the glossary biases every future recording, so
    /// it is never written without the user accepting it.
    /// `existingGlossary` is injectable so a test can exercise this without
    /// writing the one global every other suite also reads.
    func refreshContextGlossarySuggestions(existingGlossary: String? = nil) {
        let documents = allContextFiles
        guard !documents.isEmpty else { return }

        let existing = Glossary.terms(from: existingGlossary ?? Config.transcriptionGlossary)
        let mined = GlossaryMiner.candidates(inSources: documents.map(\.text),
                                             existing: existing)
        guard !mined.isEmpty else { return }

        // Which document each term came from, so a surprising suggestion is
        // explainable rather than mysterious.
        func sources(for term: String) -> [String] {
            documents.filter { $0.text.localizedCaseInsensitiveContains(term) }
                .prefix(3).map(\.name)
        }

        var known = Set(connectedGlossarySuggestions.map(\.id))
        let additions = mined.compactMap { candidate -> ConnectedGlossarySuggestion? in
            let key = ConnectedGlossarySuggestionService.canonicalKey(candidate.term)
            // Never re-propose what the user already dismissed.
            guard !connectedGlossaryRejectedKeys.contains(key),
                  known.insert(key).inserted else { return nil }
            return ConnectedGlossarySuggestion(
                term: candidate.term,
                reason: "\(candidate.reason) in attached context",
                sources: sources(for: candidate.term))
        }
        guard !additions.isEmpty else { return }

        connectedGlossarySuggestions.append(contentsOf: additions)
        if connectedGlossarySuggestionStatus == .idle {
            connectedGlossarySuggestionStatus = .ready
        }
    }

    /// Every indexed context file, loose ones and folder contents alike. Used by
    /// source pickers and clarification; prompt attachment is separately bounded.
    var allContextFiles: [ImportedContextFile] {
        contextFiles + contextFolders.flatMap(\.files)
    }

    var totalContextChars: Int {
        allContextFiles.reduce(0) { $0 + $1.charCount } + contextNotes.count
    }

    /// Number of indexed context sources available to the AI — files plus notes,
    /// but only when notes hold non-whitespace content. Folder retrieval chooses
    /// a smaller request-time subset.
    var totalContextSources: Int {
        let notes = contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return allContextFiles.count + (notes.isEmpty ? 0 : 1)
    }

    /// Counts of connected sources behind each grounding toggle — the chips
    /// show them, and a toggle with nothing behind it renders disabled.
    var connectedAppSourceCount: Int {
        let validGoogleServices = Set(GoogleService.allCases.map(\.rawValue))
        let google = googleConnected && Config.googleScopeVersion >= GoogleAuth.scopeVersion
            ? Config.googleGrantedServices.intersection(validGoogleServices).count : 0
        return (mcp?.researchableServers.count ?? 0) + google
    }
    var connectedTeamSourceCount: Int { TeamConnectors.configured.count }
    var ledgerSourceAvailable: Bool { ledgerConfigured && wheesprConnected }

    var connectedGlossarySourceCount: Int {
        if connectedGlossarySourceProvider != nil { return 1 }
        return connectedAppSourceCount + connectedTeamSourceCount
    }

    var canGenerateConnectedGlossarySuggestions: Bool {
        useConnectedAppsInPrompts && connectedGlossarySourceCount > 0
            && connectedGlossarySuggestionStatus != .loading
    }

    /// One explicit, reviewable connected-app lookup. It is independent of the
    /// capture/transcriber lifecycle, so opening Settings and running it during
    /// a call cannot stop, rebuild, or retarget either audio stream.
    func generateConnectedGlossarySuggestions(useFastModel: Bool = true) async {
        guard connectedGlossarySuggestionStatus != .loading else { return }
        guard useConnectedAppsInPrompts else {
            connectedGlossarySuggestionStatus = .unavailable(
                "Connected-app context is off. Enable it before finding terms.")
            connectedGlossarySuggestionMessage = nil
            return
        }
        guard connectedGlossarySourceCount > 0 else {
            connectedGlossarySuggestionStatus = .unavailable(
                "Connect at least one readable app before finding terms.")
            connectedGlossarySuggestionMessage = nil
            return
        }

        let query = connectedGlossaryQuery
        let cacheKey = connectedGlossaryCacheKey(query: query, useFastModel: useFastModel)
        if let cached = connectedGlossaryCache,
           cached.key == cacheKey,
           Date().timeIntervalSince(cached.at) < Self.connectedGlossaryCacheTTL {
            let suggestions = cached.generation.suggestions.filter {
                !connectedGlossaryRejectedKeys.contains($0.id)
            }
            connectedGlossarySuggestions = suggestions
            connectedGlossarySuggestionMetrics = cachedMetrics(cached.generation.metrics)
            connectedGlossarySuggestionMessage = "Показаны подсказки из последних пяти минут."
            connectedGlossarySuggestionStatus = suggestions.isEmpty ? .empty : .ready
            return
        }

        // Grounded cycles cover the connector fan-out. The managed backend is
        // authoritative for the separate fast-model compute charge.
        guard connectedGlossaryGroundedCycleConsumer(currentTier) else {
            connectedGlossarySuggestionStatus = .unavailable(
                "No connected-app research cycles remain in this billing period.")
            connectedGlossarySuggestionMessage = nil
            return
        }

        connectedGlossaryGeneration &+= 1
        let generationID = connectedGlossaryGeneration
        let connectionScope = mcp?.groundingCacheScope
        connectedGlossarySuggestionStatus = .loading
        connectedGlossarySuggestionMessage = nil
        connectedGlossarySuggestions = []
        connectedGlossarySuggestionMetrics = nil

        do {
            let provider = connectedGlossarySourceProvider
            let snippets = try await ConnectedGlossarySuggestionService.loadSources {
                if let provider { return try await provider() }
                return await self.liveConnectedGlossarySources(query: query)
            }
            guard generationID == connectedGlossaryGeneration, !Task.isCancelled,
                  connectionScope == mcp?.groundingCacheScope else { return }
            guard !snippets.isEmpty else {
                connectedGlossarySuggestionStatus = .empty
                connectedGlossarySuggestionMessage =
                    "Connected apps returned no names or technical terms to review."
                return
            }

            let model = LLMCatalog.background(for: Config.selectedModel)
            let result = await ConnectedGlossarySuggestionService.generate(
                snippets: snippets,
                existingGlossary: Config.transcriptionGlossary,
                rejectedKeys: connectedGlossaryRejectedKeys,
                model: model,
                useFastModel: useFastModel,
                ranker: { [weak self] system, user, outputTokens in
                    guard let self else { throw CancellationError() }
                    return try await self.trackingComputeUsage {
                        try await self.llm.streamChat(
                            system: system, user: user, images: [], model: model,
                            maxOutputTokens: outputTokens) { _ in }
                    }
                },
                onPrepared: { [weak self] prepared in
                    Task { @MainActor in
                        guard let self else { return }
                        self.devCallDiagnostics.record(
                            event: "connected_glossary_request",
                            fields: [
                                "model": model.id,
                                "system": prepared.system,
                                "user": prepared.user,
                                "sourceCount": prepared.sourceCount,
                                "groundingChars": prepared.groundingChars,
                                "promptChars": prepared.promptChars,
                                "estimatedInputTokens": prepared.estimatedInputTokens,
                                "transcriptCharsSent": 0,
                            ])
                    }
                })
            guard generationID == connectedGlossaryGeneration, !Task.isCancelled,
                  connectionScope == mcp?.groundingCacheScope else { return }
            guard let result, !result.suggestions.isEmpty else {
                connectedGlossarySuggestionStatus = .empty
                connectedGlossarySuggestionMessage =
                    "No new terms were found beyond your current dictionary."
                return
            }
            connectedGlossarySuggestions = result.suggestions
            // Somebody has now looked; the badge has done its job.
            glossaryReviewPending = false
            connectedGlossarySuggestionMetrics = result.metrics
            connectedGlossarySuggestionMessage = result.fallbackMessage
            connectedGlossarySuggestionStatus = .ready
            connectedGlossaryCache = ConnectedGlossaryCache(
                key: cacheKey, at: Date(), generation: result)
            Log.general.info(
                "event=connected_glossary_ready sources=\(result.metrics.sourceCount, privacy: .public) grounding_chars=\(result.metrics.groundingChars, privacy: .public) prompt_tokens=\(result.metrics.estimatedInputTokens, privacy: .public) model=\(result.metrics.modelID, privacy: .public) estimated_credits=\(result.metrics.estimatedComputeCredits, privacy: .public) ranking=\(result.metrics.ranking.rawValue, privacy: .public)")
            devCallDiagnostics.record(
                event: "connected_glossary_terminal",
                fields: [
                    "outcome": "ready",
                    "suggestions": result.suggestions.map {
                        ["term": $0.term, "reason": $0.reason, "sources": $0.sources]
                    },
                    "ranking": result.metrics.ranking.rawValue,
                    "estimatedComputeCredits": result.metrics.estimatedComputeCredits,
                ])
        } catch {
            guard generationID == connectedGlossaryGeneration, !Task.isCancelled else { return }
            connectedGlossarySuggestionStatus = .failed(error.localizedDescription)
            connectedGlossarySuggestionMessage = nil
            Log.general.info(
                "event=connected_glossary_failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    @discardableResult
    func acceptConnectedGlossarySuggestion(id: String) -> Bool {
        guard let suggestion = connectedGlossarySuggestions.first(where: { $0.id == id }) else {
            return false
        }
        let before = Glossary.terms(from: Config.transcriptionGlossary)
        guard before.count < Glossary.maxTerms,
              !before.contains(where: {
                  ConnectedGlossarySuggestionService.canonicalKey($0) == suggestion.id
              }) else {
            connectedGlossarySuggestions.removeAll { $0.id == id }
            return false
        }
        let separator = Config.transcriptionGlossary
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        Config.transcriptionGlossary += separator + suggestion.term
        connectedGlossarySuggestions.removeAll { $0.id == id }
        connectedGlossaryAcceptedCount += 1
        connectedGlossarySuggestionMessage = isRecording
            ? "Added for the next recording; this call keeps its original engine dictionary."
            : "Added to every transcription engine for the next recording."
        devCallDiagnostics.record(
            event: "connected_glossary_review",
            fields: ["action": "accepted", "term": suggestion.term,
                     "appliesToActiveRecording": false])
        return true
    }

    @discardableResult
    func rejectConnectedGlossarySuggestion(id: String) -> Bool {
        guard let suggestion = connectedGlossarySuggestions.first(where: { $0.id == id }) else {
            return false
        }
        connectedGlossaryRejectedKeys.insert(suggestion.id)
        connectedGlossarySuggestions.removeAll { $0.id == id }
        connectedGlossaryRejectedCount += 1
        devCallDiagnostics.record(
            event: "connected_glossary_review",
            fields: ["action": "rejected", "term": suggestion.term])
        return true
    }

    func rejectAllConnectedGlossarySuggestions() {
        for suggestion in connectedGlossarySuggestions {
            connectedGlossaryRejectedKeys.insert(suggestion.id)
        }
        connectedGlossaryRejectedCount += connectedGlossarySuggestions.count
        connectedGlossarySuggestions = []
    }

    func resetConnectedGlossarySuggestionReview() {
        connectedGlossaryGeneration &+= 1
        connectedGlossarySuggestions = []
        connectedGlossarySuggestionMetrics = nil
        connectedGlossarySuggestionMessage = nil
        connectedGlossarySuggestionStatus = .idle
        connectedGlossaryRejectedKeys = []
        connectedGlossaryAcceptedCount = 0
        connectedGlossaryRejectedCount = 0
        connectedGlossaryCache = nil
    }

    /// Manual glossary edits immediately remove duplicates from the review
    /// queue, but never rewrite or reorder the user's text.
    func noteConnectedGlossaryManualEdit(_ raw: String) {
        let existing = Set(Glossary.terms(from: raw).map(
            ConnectedGlossarySuggestionService.canonicalKey))
        connectedGlossarySuggestions.removeAll { existing.contains($0.id) }
        connectedGlossaryCache = nil
    }

    /// Fixed, content-bounded fixture for the nonce/root-authorized live suite.
    /// It exercises production parsing and review state without a connector or
    /// provider request and without consuming tariff balances.
    @discardableResult
    func debugLoadConnectedGlossaryFixture() async -> Bool {
        guard Config.isDevBuild else { return false }
        let snippets = [
            GroundingSnippet(
                serverName: "Synthetic Notion", toolName: "fixture",
                text: "Project Falcon runs on Kubernetes with OpenTelemetry and SLO-99.95."),
            GroundingSnippet(
                serverName: "Synthetic Linear", toolName: "fixture",
                text: "Ada Lovelace owns Project Falcon; the RAG API is called VectorBridge."),
        ]
        let model = LLMCatalog.background(for: Config.selectedModel)
        guard let result = await ConnectedGlossarySuggestionService.generate(
            snippets: snippets,
            existingGlossary: Config.transcriptionGlossary,
            rejectedKeys: connectedGlossaryRejectedKeys,
            model: model,
            useFastModel: false) else { return false }
        connectedGlossarySuggestions = result.suggestions
        connectedGlossarySuggestionMetrics = result.metrics
        connectedGlossarySuggestionMessage = "Готов образец из подключённых приложений — посмотрите."
        connectedGlossarySuggestionStatus = result.suggestions.isEmpty ? .empty : .ready
        return !result.suggestions.isEmpty
    }

    private var connectedGlossaryQuery: String {
        let goal = effectiveCallGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { return String(goal.prefix(200)) }
        return "canonical project product people acronym API technical terminology"
    }

    private func connectedGlossaryCacheKey(query: String, useFastModel: Bool) -> String {
        let scope = mcp?.groundingCacheScope ?? 0
        let revision = mcp?.capabilityRevision ?? 0
        let glossary = Glossary.terms(from: Config.transcriptionGlossary)
            .map(ConnectedGlossarySuggestionService.canonicalKey).joined(separator: "|")
        return "\(scope)|\(revision)|\(query)|\(glossary)|\(useFastModel)"
    }

    private func cachedMetrics(_ metrics: ConnectedGlossarySuggestionMetrics)
        -> ConnectedGlossarySuggestionMetrics {
        ConnectedGlossarySuggestionMetrics(
            sourceCount: metrics.sourceCount,
            groundingChars: metrics.groundingChars,
            promptChars: metrics.promptChars,
            estimatedInputTokens: metrics.estimatedInputTokens,
            transcriptCharsSent: metrics.transcriptCharsSent,
            modelID: metrics.modelID,
            estimatedComputeCredits: metrics.estimatedComputeCredits,
            ranking: metrics.ranking,
            cached: true)
    }

    private func liveConnectedGlossarySources(query: String) async -> [GroundingSnippet] {
        var snippets: [GroundingSnippet] = []
        if let mcp {
            snippets = await mcp.groundingSnippets(
                goal: query, includeTeam: true,
                maxCharsPerSource: ConnectedGlossarySuggestionService.maxCharsPerSource,
                maxSources: ConnectedGlossarySuggestionService.maxSources)
        }
        let remaining = ConnectedGlossarySuggestionService.maxSources - snippets.count
        guard remaining > 0, googleConnected,
              Config.googleScopeVersion >= GoogleAuth.scopeVersion else {
            return Array(snippets.prefix(ConnectedGlossarySuggestionService.maxSources))
        }
        let granted = Config.googleGrantedServices
        let google = GoogleService.allCases.filter { granted.contains($0.rawValue) }
        let selected = Set(google.prefix(remaining))
        if !selected.isEmpty {
            snippets += await googleGroundingSnippets(
                services: selected, query: query,
                cap: ConnectedGlossarySuggestionService.maxCharsPerSource)
        }
        return Array(snippets.prefix(ConnectedGlossarySuggestionService.maxSources))
    }

    /// Upper-bound input that the reversible connected-app switch controls.
    /// The actual workflow uses only sources relevant to the pressed button.
    var connectedAppsTokenPotential: Int {
        TokenEstimate.tokens(
            (connectedAppSourceCount + connectedTeamSourceCount)
                * TokenEstimate.connectedSourceCharacterBudget
        )
    }

    /// Attach the verified MCP capability stream. A successful handshake (or a
    /// disconnect/auth invalidation) rebuilds every prompt recipe and clears the
    /// 120-second source cache so a newly connected app is usable immediately.
    private func bindWorkflowDesigner(to manager: MCPConnectionManager?) {
        mcpCapabilityObservation?.cancel()
        mcpCapabilityObservation = nil
        rebuildPromptWorkflows()
        guard let manager else { return }
        mcpCapabilityObservation = manager.$capabilityRevision
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.rebuildPromptWorkflows() }
            }
    }

    /// Re-design all persistent buttons. This is intentionally local and
    /// deterministic: connection success never spends an LLM request, and the
    /// resulting recipe can reference only currently reachable read sources.
    private func rebuildPromptWorkflows() {
        groundingCache.removeAll()
        connectedGlossaryGeneration &+= 1
        connectedGlossaryCache = nil
        connectedGlossarySuggestions = []
        connectedGlossarySuggestionMetrics = nil
        connectedGlossarySuggestionMessage = nil
        connectedGlossarySuggestionStatus = .idle
        // A newly connected app knows the names this call is about to use. The
        // candidates cost a background model call, and connection success does
        // not spend one, so this only records that there is something worth
        // mining — the call happens when the user opens the review.
        glossaryReviewPending = GlossaryReview.marksPending(
            authorizedApps: mcp?.authorizedServerIDs.count ?? 0,
            isRecording: isRecording)
        var workflows: [String: PromptWorkflow] = [:]
        var sources: [String: [WorkflowApp]] = [:]
        for prompt in QuickPrompts.all + customPrompts {
            let design = designWorkflow(for: prompt)
            workflows[prompt.id] = design.workflow
            sources[prompt.id] = design.sources
        }
        designedPromptWorkflows = workflows
        promptWorkflowSources = sources
    }

    /// Resolve a saved, built-in, generated follow-up, or not-yet-saved custom
    /// prompt through the same capability matcher.
    private func designWorkflow(for prompt: QuickPrompt) -> (workflow: PromptWorkflow, sources: [WorkflowApp]) {
        let base = PromptWorkflows.spec(for: prompt)
        var matchedServerIDs: Set<String> = []

        if let mcp {
            for server in mcp.researchableServers {
                let capabilityText = mcp.researchCapabilityText(for: server.id)
                // An arbitrary custom endpoint participates only after a real
                // connection discovered a read/search tool. Catalog apps retain
                // their curated lazy-reconnect behavior across launches.
                if server.isCustom && mcp.researchTool(for: server.id) == nil { continue }
                if PromptWorkflows.isRelevant(
                    serverID: server.id,
                    serverName: server.name,
                    toolTexts: capabilityText,
                    for: base
                ) {
                    matchedServerIDs.insert(server.id)
                }
            }
        }

        let workflow = base.addingServers(matchedServerIDs)
        return (workflow, workflowApps(for: workflow))
    }

    private func workflowApps(for workflow: PromptWorkflow) -> [WorkflowApp] {
        var apps: [WorkflowApp] = []

        // Own decision history is checked first in the execution path.
        if workflow.includeLedger, groundLedger, ledgerSourceAvailable {
            apps.append(WorkflowApp(
                id: "api:decision-ledger", name: "Decision Ledger",
                symbol: "checkmark.seal", kind: .api))
        }

        // Google is a direct read-only API, with each service gated by the scope
        // that was actually granted during the successful OAuth connection.
        if groundApps, googleConnected, Config.googleScopeVersion >= GoogleAuth.scopeVersion {
            let granted = Config.googleGrantedServices
            for service in GoogleService.allCases
            where workflow.googleServices.contains(service) && granted.contains(service.rawValue) {
                apps.append(WorkflowApp(
                    id: "google:\(service.rawValue)",
                    name: "Google \(service.label)",
                    symbol: googleWorkflowSymbol(service), kind: .api))
            }
        }

        if groundApps, let mcp {
            for server in mcp.researchableServers where workflow.servers.contains(server.id) {
                // A verified live connection with no safe read/search tool is
                // not a usable grounding step. Authorized cold sessions remain
                // eligible because reconnect will refresh their tool catalog.
                if mcp.isConnected(server.id), mcp.researchTool(for: server.id) == nil { continue }
                apps.append(WorkflowApp(
                    id: "mcp:\(server.id)", name: server.name,
                    symbol: server.symbol, kind: .mcp))
            }
        }

        if workflow.includeTeam, groundTeam {
            for service in TeamConnectors.configured {
                apps.append(WorkflowApp(
                    id: "team:\(service.rawValue)", name: service.label,
                    symbol: service.symbol, kind: .api))
            }
        }
        return apps
    }

    private func googleWorkflowSymbol(_ service: GoogleService) -> String {
        switch service {
        case .calendar: return "calendar"
        case .docs: return "doc.richtext"
        case .sheets: return "tablecells"
        case .drive: return "externaldrive"
        }
    }

    private func designedWorkflow(for prompt: QuickPrompt) -> PromptWorkflow {
        designedPromptWorkflows[prompt.id] ?? designWorkflow(for: prompt).workflow
    }

    private func designedWorkflow(for promptID: String) -> PromptWorkflow? {
        if let cached = designedPromptWorkflows[promptID] { return cached }
        guard let prompt = (QuickPrompts.all + customPrompts + followUpPrompts)
            .first(where: { $0.id == promptID }) else {
            return PromptWorkflows.spec(for: promptID)
        }
        return designWorkflow(for: prompt).workflow
    }

    /// Item 19: a call-specific one-liner for why a prompt is offered, or nil.
    /// Disappears once the prompt has been run on THIS call — a justification
    /// for something you already chose is noise — which is a pure read of the
    /// history, so no run-tracking state is added.
    func promptReason(for prompt: QuickPrompt) -> String? {
        guard !aiHistory.contains(where: { $0.promptID == prompt.id }) else { return nil }
        return PromptReason.reason(promptID: prompt.id,
                                   recentTranscript: transcriptText,
                                   goal: effectiveCallGoal)
    }

    func workflowSummary(for prompt: QuickPrompt) -> String {
        let sources = promptWorkflowSources[prompt.id] ?? designWorkflow(for: prompt).sources
        let names = sources.map(\.name)
        if names.isEmpty { return "Источники: расшифровка → \(workflowAIApp.name)" }
        return "Источники: \(names.joined(separator: " · ")) → \(workflowAIApp.name)"
    }

    func promptWorkflowCount(using sourceID: String) -> Int {
        promptWorkflowSources.values.reduce(into: 0) { count, apps in
            if apps.contains(where: { $0.id == sourceID }) { count += 1 }
        }
    }

    func promptWorkflowCount(usingSourcePrefix prefix: String) -> Int {
        promptWorkflowSources.values.reduce(into: 0) { count, apps in
            if apps.contains(where: { $0.id.hasPrefix(prefix) }) { count += 1 }
        }
    }

    private var workflowAIApp: WorkflowApp {
        let selection = Config.selectedModelID
        let name: String
        if selection == LLMCatalog.autoID || selection.hasPrefix("orchestrate:") {
            name = "Cruxwing AI"
        } else if selection.hasPrefix("council:") {
            name = "AI Council"
        } else if selection.hasPrefix("auto:"),
                  let provider = LLMProvider(rawValue: String(selection.dropFirst("auto:".count))) {
            name = provider.label
        } else {
            name = Config.selectedModel.provider.label
        }
        return WorkflowApp(id: "ai:\(selection)", name: name, symbol: "sparkles", kind: .ai)
    }

    private var workflowLocalApp: WorkflowApp {
        WorkflowApp(id: "local:cruxwing", name: "Cruxwing", symbol: "macbook", kind: .local)
    }

    private func workflowAIApp(for model: LLMModel) -> WorkflowApp {
        WorkflowApp(
            id: "ai:\(model.id)", name: model.provider.label,
            symbol: "sparkles", kind: .ai)
    }

    private var workflowLedgerApp: WorkflowApp {
        WorkflowApp(id: "api:decision-ledger", name: "Decision Ledger",
                    symbol: "checkmark.seal", kind: .api)
    }

    /// Pre-create the complete visible recipe for one run. Source rows remain in
    /// catalog order and are updated by stable app id even though reads fan out
    /// concurrently.
    private func installPromptWorkflowPlan(workflow: PromptWorkflow?,
                                           composition: String,
                                           validation: String? = nil,
                                           aiReview: (label: String, app: WorkflowApp, tool: String)? = nil,
                                           writeback: (label: String, app: WorkflowApp)? = nil) {
        let sources = workflow.map(workflowApps(for:)) ?? []
        var steps: [WorkflowStep] = []
        var nextID = 0
        func append(_ label: String, app: WorkflowApp, tool: String? = nil) {
            nextID += 1
            steps.append(WorkflowStep(
                id: nextID, label: label, status: .pending,
                app: app, tool: tool))
        }

        if let workflow, !sources.isEmpty,
           PromptWorkflows.derivationSystemPrompt(for: workflow.queryStrategy) != nil {
            append("Prepare search terms", app: workflowAIApp,
                   tool: LLMCatalog.fastAudit(for: Config.selectedModel).id)
        }
        for app in sources {
            append(sourceWorkflowLabel(app), app: app, tool: workflowToolName(app))
        }
        append(composition, app: workflowAIApp, tool: Config.selectedModelID)
        if let validation { append(validation, app: workflowLocalApp) }
        if let aiReview { append(aiReview.label, app: aiReview.app, tool: aiReview.tool) }
        if let writeback { append(writeback.label, app: writeback.app) }
        installWorkflowPlan(steps)
    }

    private func sourceWorkflowLabel(_ app: WorkflowApp) -> String {
        switch app.id {
        case "api:decision-ledger": return "Read recent decisions"
        case "google:calendar": return "Read current calendar event"
        case "google:docs": return "Search related documents"
        case "google:sheets": return "Search related spreadsheets"
        default: return "Search relevant context"
        }
    }

    private func workflowToolName(_ app: WorkflowApp) -> String? {
        if app.id.hasPrefix("mcp:"), let mcp {
            return mcp.researchTool(for: String(app.id.dropFirst("mcp:".count)))?.name ?? "search"
        }
        if app.id.hasPrefix("team:") { return "search" }
        switch app.id {
        case "api:decision-ledger": return "recent-decisions"
        case "google:calendar": return "events.list"
        case "google:docs", "google:sheets": return "files.list"
        default: return nil
        }
    }

    /// Shared preflight before a prompt button is selected (chars → tokens), by
    /// ingredient. Grounding is an upper bound (active sources × the typical
    /// per-source budget). The pressed button adds its own request and skill
    /// instructions, so the gauge is directional rather than a billing quote.
    var promptTokenEstimate: TokenEstimate {
        var sources = 0
        if groundApps { sources += connectedAppSourceCount }
        if groundTeam { sources += connectedTeamSourceCount }
        if groundLedger, ledgerSourceAvailable { sources += 1 }
        let instructions = SystemInstructions.system(skills: [
            activeCallTheme.guidance,
            RoleSkillMatrix.guidance(roleID: userRoleID, promptID: nil),
            ModelPromptStyle.guidance(for: Config.selectedModel),
        ])
        return TokenEstimate(
            transcriptChars: promptTranscript(cap: SystemInstructions.digestActivationChars).count,
            contextChars: promptContext(
                query: effectiveCallGoal + "\n" + String(transcriptText.suffix(2_000))).count,
            sourcesChars: sources * TokenEstimate.connectedSourceCharacterBudget,
            instructionsChars: instructions.count
        )
    }

    /// True when the AI response holds something worth showing/copying.
    var hasContent: Bool {
        !aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The whole dialog as clipboard text: every archived turn, then the live
    /// one. The share menu's copy used to cover only the visible answer, which
    /// was reported as "not saving whole dialog".
    var dialogClipboardText: String {
        var turns = aiHistory.filter(\.isArchivable).map { exchange -> String in
            let prompt = exchange.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? exchange.answer : "\(prompt)\n\n\(exchange.answer)"
        }
        let livePrompt = aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveAnswer = aiResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveAnswer.isEmpty {
            turns.append(livePrompt.isEmpty ? liveAnswer : "\(livePrompt)\n\n\(liveAnswer)")
        }
        return turns.joined(separator: "\n\n---\n\n")
    }

    /// Error text is useful on screen and on the clipboard, but it is not an
    /// assistant answer worth packaging as a Word document.
    var canExportAssistantAnswer: Bool {
        let answer = aiResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        return !aiStreaming && !answer.isEmpty && !AnswerFailure.looksLikeFailure(answer)
    }

    /// Show the "Google Docs" export affordance when there's an answer and a
    /// Google account is connected. The action re-checks the write grant and
    /// guides the user to reconnect if the Docs scope is missing.
    var canExportToGoogleDocs: Bool { canExportAssistantAnswer && googleConnected }

    /// Show "Notion" only when Notion is integrated AND exposes a create-page
    /// tool right now (per the operator's "if notion is integrated").
    var canExportToNotion: Bool {
        canExportAssistantAnswer && (mcp?.canExportToNotion ?? false)
    }

    /// Spreadsheets this answer could become — one per markdown table in it.
    ///
    /// Empty for almost every answer, which is the point: the offer appears only
    /// when the answer actually contains tabular data, so it reads as a specific
    /// suggestion rather than a permanent button.
    var answerSpreadsheetProposals: [GoogleFileExport.Proposal] {
        guard canExportAssistantAnswer, googleConnected else { return [] }
        // A grant that predates the write scope, or that excluded Sheets, would
        // take the click and then fail at Google. Hiding the offer is better
        // than an error after the user committed to it.
        guard Config.googleScopeVersion >= GoogleAuth.scopeVersion,
              Config.googleGrantedServices.contains(GoogleService.sheets.rawValue) else {
            return []
        }
        return GoogleFileExport.proposals(
            forAnswer: aiResponse,
            title: AssistantAnswerTitle.forDialog(meetingTitle: meetingTitle, date: sessionDate))
    }

    /// Snapshot the visible answer, create its title with the provider's cheap
    /// fast model, and cache that title. The generation + content checks keep a
    /// slow title request from exporting a newer answer under an older prompt.
    func prepareCurrentAnswerExport(exportedAt: Date = Date()) async throws -> AssistantAnswerDocument {
        guard !aiStreaming else { throw AssistantAnswerExportError.answerStillStreaming }
        let answer = aiResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !AnswerFailure.looksLikeFailure(answer) else {
            throw AssistantAnswerExportError.noAnswer
        }

        let generation = aiRunGeneration
        let promptSnapshot = aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = promptSnapshot.isEmpty
            ? "Prompt unavailable for this older saved answer."
            : promptSnapshot

        let blindSpots = suggestions.map(\.exportLine)
        // The file says "Assistant chat", so it carries the chat: every
        // archived turn, then the live one. Exporting only the last answer was
        // reported from the first real call.
        let dialog = aiHistory.filter(\.isArchivable)

        if let cached = aiResponseExportTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return AssistantAnswerDocument(
                title: cached, prompt: prompt, answer: answer,
                exportedAt: exportedAt, blindSpots: blindSpots,
                earlierExchanges: dialog)
        }

        guard aiRunGeneration == generation,
              aiResponse.trimmingCharacters(in: .whitespacesAndNewlines) == answer,
              aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines) == promptSnapshot else {
            throw AssistantAnswerExportError.answerChanged
        }

        // Named after the call, not the topic. The previous LLM-generated title
        // spent credits and a round trip per export and produced a different
        // name each time for the same dialog.
        let title = AssistantAnswerTitle.forDialog(
            meetingTitle: meetingTitle, date: sessionDate)
        aiResponseExportTitle = title
        persistCurrentSession()
        return AssistantAnswerDocument(
            title: title, prompt: prompt, answer: answer,
            exportedAt: exportedAt, blindSpots: blindSpots,
            earlierExchanges: dialog)
    }

    private func beginAssistantAnswer(prompt: String,
                                      promptID: String? = nil,
                                      id: UUID = UUID(),
                                      promptedAt: Date = Date(),
                                      modelSelectionID: String? = nil) {
        // Quick prompts and structured buttons do not pass through `ask(_:)`.
        // They still start a new composer turn and must invalidate an older
        // clarification card before that card can launch stale work over them.
        supersedePendingClarification()
        // Every run path calls this BEFORE clearing aiResponse, so the previous
        // turn is still intact here — this is the one place that can archive it.
        archiveLiveExchange()
        aiResponsePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedPromptPreview = nil
        aiResponseID = id
        aiResponsePromptID = promptID
        aiResponseStartedAt = promptedAt
        aiResponseCompletedAt = nil
        aiResponseStatus = .inProgress
        aiResponseModelID = modelSelectionID ?? Config.selectedModelID
        aiResponseExportTitle = nil
        devCallDiagnostics.record(event: "assistant_prompt", fields: [
            "exchangeID": id.uuidString,
            "promptID": promptID ?? "freeform",
            "prompt": aiResponsePrompt,
            "model": aiResponseModelID ?? "unknown",
            "promptedAt": promptedAt.timeIntervalSince1970,
        ])
    }

    /// Close the current lifecycle exactly once and retain an immutable record
    /// for the live evaluator. A terminal status is evidence, not an inference
    /// from whether a cancelled stream happened to emit a few convincing words.
    private func terminalizeAssistantAnswer(
        as explicitStatus: AIExchangeStatus? = nil,
        at completedAt: Date = Date()
    ) {
        guard aiResponseStatus == .inProgress,
              let id = aiResponseID,
              let promptedAt = aiResponseStartedAt else { return }
        let answer = aiResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: AIExchangeStatus
        if let explicitStatus {
            status = explicitStatus
        } else if answer.isEmpty || AnswerFailure.looksLikeFailure(answer) {
            status = .failed
        } else {
            status = .succeeded
        }
        precondition(status.isTerminal)
        aiResponseCompletedAt = completedAt
        aiResponseStatus = status

        let exchange = AIExchange(
            id: id,
            prompt: aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            answer: answer,
            at: completedAt,
            promptedAt: promptedAt,
            promptID: aiResponsePromptID,
            completedAt: completedAt,
            status: status)
        if let index = aiExchangeEvidence.firstIndex(where: { $0.id == id }) {
            aiExchangeEvidence[index] = exchange
        } else {
            aiExchangeEvidence.append(exchange)
        }
        if aiExchangeEvidence.count > Self.maxArchivedExchanges {
            aiExchangeEvidence.removeFirst(
                aiExchangeEvidence.count - Self.maxArchivedExchanges)
        }
        let modelID = aiResponseModelID ?? "unknown"
        devCallDiagnostics.record(event: "assistant_terminal", fields: [
            "exchangeID": id.uuidString,
            "promptID": aiResponsePromptID ?? "freeform",
            "prompt": exchange.prompt,
            "response": exchange.answer,
            "status": exchange.status.rawValue,
            "model": modelID,
            "provider": LLMCatalog.model(id: modelID)?.provider.rawValue ?? "orchestrated",
            "startedAt": promptedAt.timeIntervalSince1970,
            "completedAt": completedAt.timeIntervalSince1970,
            "latencyMs": max(0, Int(completedAt.timeIntervalSince(promptedAt) * 1_000)),
            "estimatedOutputTokens": TokenEstimate.tokens(exchange.answer.count),
        ])
    }

    /// Move the live turn into the archive. No-op when there is nothing to keep
    /// (first prompt of a session, or a run superseded before it answered).
    private func archiveLiveExchange() {
        let exchange = AIExchange(
            id: aiResponseID ?? UUID(),
            prompt: aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            answer: aiResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            promptedAt: aiResponseStartedAt,
            promptID: aiResponsePromptID,
            completedAt: aiResponseCompletedAt,
            status: aiResponseStatus ?? .succeeded,
            followUpPrompts: followUpPrompts,
            answerActions: answerActions
        )
        guard exchange.isArchivable else { return }
        aiHistory.append(exchange)
        if aiHistory.count > Self.maxArchivedExchanges {
            aiHistory.removeFirst(aiHistory.count - Self.maxArchivedExchanges)
        }
    }

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()
    private let systemCaptureDiagnostics = AudioTrackDiagnostics()
    private let micCaptureDiagnostics = AudioTrackDiagnostics()
    private let llm: LLMGateway
    typealias ConnectedGlossarySourceProvider = @MainActor () async throws -> [GroundingSnippet]
    private let connectedGlossarySourceProvider: ConnectedGlossarySourceProvider?
    private let connectedGlossaryGroundedCycleConsumer: (Tier) -> Bool
    private let credentialStore: KeychainStore
    private let shouldInstallProcessCredentialCache: Bool
    private let callDetector = CallDetector()
    private let callNotifier = CallNotifier()
    private let reminderScheduler = MeetingReminderScheduler()
    private var transcriber: TranscriptionService
    /// Push-to-talk dictation for the ask composer. Shares the configured
    /// transcription engine but owns its own capture — see PromptDictation for
    /// why it must not tap the meeting recorder's input node.
    let dictation: PromptDictation
    private let managesTranscriberLifecycle: Bool
    private var transcriberEngine: TranscriptionEngine?
    private var transcriberLocalModel: String?
    private var transcriberLanguage: String?
    private var transcriberGlossary: String?
    private var activeSessionEngine: TranscriptionEngine?
    /// Retained after Stop because optional post-call diarization must use the
    /// language mode selected when this recording began.
    private var activeSessionLanguage: String?
    private var activeRecordingSettings: RecordingSettingsSnapshot?
    /// Non-nil only when this Local call actually prepared Whisper. A Parakeet
    /// live session must not trigger a surprise Whisper download after Stop.
    private var activeSessionPreparedLocalWhisperModel: String?
    private let googleAuth = GoogleAuth()
    private let sessionRecorder = SessionAudioRecorder()
    /// Wall-clock origin of sample zero in `sessionRecorder`. Diarization uses
    /// the whole retained track even when Local refinement starts at a later
    /// cloud-to-private suffix boundary.
    private var sessionRetainedAudioStart: Date?
    /// Wall-clock origin of the Local-only interval eligible for refinement.
    private var sessionAudioStart: Date?
    /// Sample offset where the current Local refinement interval begins. The
    /// recorder may also hold an earlier cloud prefix for opted-in diarization;
    /// final-pass coverage must never count or decode that prefix.
    private var sessionAudioStartSample = 0
    /// A paused call has disjoint wall-clock spans but the recorder is a dense
    /// PCM array. Until retained audio carries an interval map, no post-call
    /// rewrite may use that array after any pause.
    private var sessionRetainedAudioTimelineValid = true
    /// A single linear start+sampleOffset timeline is valid only until the
    /// first pause. Without piecewise wall-clock anchors, resuming would shift
    /// refined rows earlier by the pause duration and target the wrong speech.
    private var localFinalPassContinuityValid = false
    /// Immutable per-route authorization for this post-call consumer. Assembly
    /// may retain the same PCM for diarization, but that does not opt the call
    /// into Local transcript replacement.
    private var localFinalPassOptedInForSession = false
    /// Separate start-of-route consent for private speaker labels. It may share
    /// PCM with local refinement, but neither feature authorizes the other.
    private var localDiarizationOptedInForSession = false
    /// True only while `sessionAudioStart` and its sample offset describe one
    /// continuous Local route. Cloud prefixes retained for another consumer
    /// must never be relabeled from this later suffix.
    private var localDiarizationContinuityValid = false
    /// Captured at the recording boundary. Signed-in users already have a
    /// manual server Improve/diarization consumer; a Local refinement must not
    /// discard its PCM merely because no AssemblyAI key is configured.
    private var serverDiarizationEligibleForSession = false
    private var systemStreamer: DeepgramStreamer?
    private var micStreamer: DeepgramStreamer?
    private struct PendingStartupLocalFallback {
        let message: String
        let generationToken: RecordingGenerationToken
        let state: LiveStreamDegradeState
        let routeLease: TranscriptionRouteLease
    }
    /// Deepgram can reject a grant while capture is still in `.starting`.
    /// Applying Local immediately is unsafe because the capture-success reset
    /// would overwrite its recorder origin and model provenance moments later.
    private var pendingStartupLocalFallback: PendingStartupLocalFallback?
    /// A streamer retired during a mid-call handoff can still deliver its
    /// bounded CloseStream final after the active route is already Local.
    private var latestStreamingRouteRetiredAt: Date?

    private var systemChunker: AudioChunkBuffer?
    private var micChunker: AudioChunkBuffer?
    /// The chunk route currently receiving newly emitted PCM. Retired routes
    /// remain in `retiringTranscribers` only until all pre-handoff work drains.
    private var activeChunkRouteLease: TranscriptionRouteLease?
    private var retiringTranscribers: [ObjectIdentifier: TranscriptionService] = [:]
    /// Previous chunk route held warm only while a Local→Instant socket
    /// handoff can still roll back. A rapid user switch away from Instant
    /// retires it explicitly instead of leaving the model parked all call.
    private var pendingDeepgramPreviousTranscriber: TranscriptionService?
    private var pendingDeepgramPreviousRouteLease: TranscriptionRouteLease?
    // Internal (not private) so tests can await the AI pipeline to completion.
    var aiTask: Task<Void, Never>?
    /// Identifies the latest answer-producing run. A provider that ignores task
    /// cancellation cannot append stale deltas into the next prompt's answer.
    private var aiRunGeneration = 0

    /// Cancel the answer-producing run before Clear, History restore, or a new
    /// prompt starts. Reset the manual Fact Check gate synchronously because a
    /// superseded task deliberately exits at its generation guard and therefore
    /// cannot be relied on to run its own epilogue.
    private func supersedeActiveAI(
        status: AIExchangeStatus = .cancelled,
        at terminalAt: Date = Date()
    ) {
        terminalizeAssistantAnswer(as: status, at: terminalAt)
        aiTask?.cancel()
        aiTask = nil
        aiRunGeneration &+= 1
        factChecking = false
        showFactCheck = false
        aiStreaming = false
        aiStage = nil
    }

    /// Nonce-gated live-test companion to `runPrompt`. The harness uses this to
    /// finish an isolated model-snapshot transaction before arming unrelated
    /// prompt workers. Requiring the exact exchange id means a late automation
    /// message can never cancel a newer user request.
    @discardableResult
    func debugCancelAssistantPrompt(exchangeID: String) -> Bool {
        guard (Config.isDevBuild || Self.isUnderTest),
              aiResponseStatus == .inProgress,
              aiResponseID?.uuidString == exchangeID else { return false }
        supersedeActiveAI(status: .cancelled)
        return true
    }

    private(set) var recordingStartedAt: Date?
    /// Active-time accounting, so a paused span is excluded from both the
    /// visible clock and the co-pilot hour meter. Kept beside
    /// `recordingStartedAt`, which remains the wall-clock start the saved
    /// session is filed under.
    var recordingElapsed = RecordingElapsed()
    /// Bumped by clearAll() — in-flight chunk transcriptions from an older
    /// generation are dropped instead of resurrecting cleared lines.
    private var chunkGeneration = 0
    private var recordingGenerationToken: RecordingGenerationToken?
    private var automaticLocalFinalPassTask: Task<Void, Never>?
    private var manualLocalFinalPassTask: Task<Void, Never>?
    private var localFinalPassRevision = 0
    /// Local speaker work has its own revision lease. CoreML inference may not
    /// stop immediately, so stale results are blocked from mutating a new call.
    private var localDiarizationTask: Task<Void, Never>?
    private var localDiarizationRunID: UUID?
    private var localDiarizationRevision = 0
    /// Deterministic model seam for lifecycle tests. Production leaves nil.
    var localDiarizationRunnerOverride: (
        ([Float], Int, LocalDiarization.Progress?) async throws -> [SpeakerSegment]
    )?
    private var tickTask: Task<Void, Never>?
    private var brainstormTask: Task<Void, Never>?
    private var blindSpotRefreshDebounce: Task<Void, Never>?
    private var agendaTask: Task<Void, Never>?
    // Background checks (fact-check + rhetoric): coalesced on the transcript's
    // entry count so an unchanged transcript never re-spends a call.
    private var factCheckLoopTask: Task<Void, Never>?
    private var rhetoricLoopTask: Task<Void, Never>?
    private var facilitationLoopTask: Task<Void, Never>?
    private var copilotActiveTimeMeter = CopilotActiveTimeMeter()

    struct LiveWatchActivity: Equatable {
        let brainstormConfigured: Bool
        let brainstormTaskActive: Bool
        let agendaConfigured: Bool
        let agendaTaskActive: Bool
        let factCheckConfigured: Bool
        let factCheckTaskActive: Bool
        let rhetoricConfigured: Bool
        let rhetoricTaskActive: Bool
        let facilitationConfigured: Bool
        let facilitationTaskActive: Bool
        let accruedUnionSeconds: Int
    }

    func liveWatchActivity(at date: Date = Date()) -> LiveWatchActivity {
        LiveWatchActivity(
            brainstormConfigured: blindSpotsEnabled,
            brainstormTaskActive: brainstormTask != nil,
            agendaConfigured: agendaCheckingEnabled,
            agendaTaskActive: agendaTask != nil,
            factCheckConfigured: liveFactCheckingEnabled,
            factCheckTaskActive: factCheckLoopTask != nil,
            rhetoricConfigured: rhetoricWatchEnabled,
            rhetoricTaskActive: rhetoricLoopTask != nil,
            facilitationConfigured: facilitationWatchEnabled,
            facilitationTaskActive: facilitationLoopTask != nil,
            accruedUnionSeconds: copilotActiveTimeMeter.seconds(at: date)
        )
    }

    /// Whether this ambient watch should spend a call on this tick.
    ///
    /// Two gates, both measured. The three 300-second watches ROTATE — one per
    /// tick instead of all three — which turns 72 credits an hour into 24 for
    /// ambient notes nobody is waiting on. And each still needs enough NEW
    /// recognised speech to be worth re-reading; the old signature was
    /// `transcript.count`, so one new line bought a full-price call.
    private func shouldSpendOnWatch(_ key: String) -> Bool {
        guard BackgroundSpendPolicy.rotatedWatches.contains(key) else { return true }

        // The rotation index comes from ELAPSED TIME, not a shared counter.
        // Incrementing a counter here advanced it once per WATCH rather than once
        // per period — all three fire on the same tick, so each bumped it before
        // testing its own name and all three matched. The rotation saved nothing.
        // Elapsed time gives every watch the same index within a period, so
        // exactly one of them matches.
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let period = Int(elapsed / Double(CopilotCadence.facilitationSeconds))
        guard BackgroundSpendPolicy.watch(forTick: period + 1) == key else { return false }

        let total = transcriptText.count
        guard BackgroundSpendPolicy.shouldRun(
            totalCharacters: total,
            charactersAtLastRun: backgroundSpendState.charactersAtLastRun[key]) else { return false }
        backgroundSpendState.charactersAtLastRun[key] = total
        return true
    }

    /// Shared cost gate for every background watch loop: coalesces unchanged
    /// transcripts, single-flights per key, and caps concurrent background LLM
    /// calls so aligned timers can't stack a burst. See BackgroundLLMQueue.
    private let bgQueue: BackgroundLLMQueue
    private let blindSpotSuggestionProvider: (
        BlindSpotProviderRequest
    ) async throws -> BrainstormService.SuggestionResult
    /// One fact-check call, injectable like the blind-spot provider so tests can
    /// assert the searchWeb plumbing (the never-silent rule's enforcement point)
    /// without a live backend. Production default is the real service.
    struct FactCheckProviderRequest: Equatable {
        let transcript: String
        let context: String
        let accessToken: String?
        let extraGuidance: String?
        let searchWeb: Bool
    }
    private let factCheckProvider: (
        FactCheckProviderRequest, LLMModel
    ) async throws -> (claims: [FactClaim], search: FactCheckService.WebSearchOutcome?)
    private let blindSpotAccessTokenProvider: (() async -> String?)?
    private let blindSpotSkillGuidanceProvider: ((String, [String]) -> String?)?
    /// Transcript length when each background watch last spent a call, and the
    /// rotation tick. Both feed BackgroundSpendPolicy — see that file for the
    /// measured burn this exists to cut (204 credits/hour on Pro against a
    /// 250/month allowance).
    private var backgroundSpendState = BackgroundSpendSessionState()
    private var remindersTask: Task<Void, Never>?
    /// Coalesces concurrent token refreshes — legacy field retained so sign-out
    /// can cancel any stray task; the live refresh path is
    /// `WheesprAuth.validAccessToken()`.
    private var refreshTask: Task<String?, Never>?
    private var sessionObservers: [NSObjectProtocol] = []
    private var persistedConnectionLoadTask: Task<PersistedConnectionSnapshot, Never>?
    private var persistedConnectionStateLoaded = false
    private var googleConnectionMutatedSinceLaunch = false
    private var wheesprConnectionMutatedSinceLaunch = false
    /// Session lifecycle notifications ride this center. Injectable so tests
    /// can use a private center — with the global default, every AppState in a
    /// parallel test process reacted to every other test's session posts
    /// (flipping wheesprConnectionMutatedSinceLaunch and starving the badge
    /// restore). Production uses .default throughout.
    private let notificationCenter: NotificationCenter
    /// Content-bearing diagnostics are inert unless a dev binary was launched
    /// with the explicit nonce/root/CRUXWING_DEV_CALL_LOGS authorization.
    private let devCallDiagnostics: DevCallDiagnostics

    /// Deterministic connected-tool seam. nil in production, where commits use
    /// the live MCP manager attached by the app scene.
    private let answerActionDispatcher: (any AnswerActionDispatching)?
    /// Deterministic, hardware-free seam for the live transcription handoff.
    /// Production leaves this nil and reconfigures the running audio buffers.
    private let transcriptionEngineSwitchOverride: ((TranscriptionEngine) -> Bool)?
    /// Factories keep live handoff tests on the production state machine while
    /// substituting only hardware/network edges. Shipped initializers use the
    /// same concrete factories and availability checks as before.
    private let transcriptionServiceFactory: (
        TranscriptionEngine, String, String, String, String?
    ) -> TranscriptionService
    /// One bounded post-call pipeline, injectable so tests never load Core ML.
    private let localFinalPassServiceFactory: (String, String) -> TranscriptionService
    private let deepgramStreamerFactory: (
        DeepgramAuth, Bool, String, [String]
    ) -> DeepgramStreamer
    private let transcriptionEngineAvailability: (TranscriptionEngine) -> Bool
    private let deepgramAuthOverride: DeepgramAuth?
    typealias FirefliesTranscriptProvider = @MainActor (
        _ near: Date?, _ within: TimeInterval?
    ) async throws -> FirefliesTranscript
    /// Nil in production. It keeps the fetch/session race deterministic in
    /// tests while both shipped paths still use MCP.
    private let firefliesTranscriptProvider: FirefliesTranscriptProvider?

    /// True when running inside `swift test` / XCTest / swift-testing — used to
    /// skip app-only OS integrations (notification authorization, workspace
    /// watchers, calendar polling) that need a real app bundle and would
    /// otherwise abort a test process. The XCTest runtime is linked into the
    /// package test bundle even for swift-testing, so its presence is the
    /// reliable signal across both harnesses.
    /// nonisolated: it reads the runtime class list and the environment, both
    /// process-global. It was MainActor-isolated only by inheriting AppState's
    /// isolation, which made SessionStore's nonisolated static initializer
    /// unable to consult it — the very check that keeps tests out of the user's
    /// real meeting history.
    nonisolated static let isUnderTest: Bool =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // The swift-testing runner has no app bundle — the very condition that
        // makes UNUserNotificationCenter et al. abort ("bundleProxyForCurrentProcess
        // is nil"). A shipped .app always has a bundle identifier.
        || Bundle.main.bundleIdentifier == nil

    init(transcriber: TranscriptionService? = nil,
         llm: LLMGateway = LLMGatewayFactory.make(),
         analytics: @escaping (AnalyticsEvent) -> Void = { FunnelTracker.track($0) },
         credentialStore: KeychainStore = SystemKeychain.shared,
         sessionStore: SessionStore = .shared,
         notificationCenter: NotificationCenter = .default,
         answerActionDispatcher: (any AnswerActionDispatching)? = nil,
         transcriptionEngineSwitchOverride: ((TranscriptionEngine) -> Bool)? = nil,
         transcriptionServiceFactory: @escaping (
             TranscriptionEngine, String, String, String, String?
         ) -> TranscriptionService = { engine, language, glossary, localModel, autoLanguageHint in
             TranscriptionFactory.make(
                 engine: engine, language: language, glossary: glossary,
                 localModel: localModel, autoLanguageHint: autoLanguageHint)
         },
         localFinalPassServiceFactory: @escaping (
             String, String
         ) -> TranscriptionService = { model, language in
             LocalWhisperTranscription(model: model, language: language, glossary: "")
         },
         deepgramStreamerFactory: @escaping (
             DeepgramAuth, Bool, String, [String]
         ) -> DeepgramStreamer = { auth, diarize, language, keyterms in
             DeepgramStreamer(
                 auth: auth, diarize: diarize, language: language,
                 keyterms: keyterms)
         },
         transcriptionEngineAvailability: @escaping (TranscriptionEngine) -> Bool = {
             Config.engineAvailable($0)
         },
         deepgramAuthOverride: DeepgramAuth? = nil,
         firefliesTranscriptProvider: FirefliesTranscriptProvider? = nil,
         backgroundLLMQueue: BackgroundLLMQueue = BackgroundLLMQueue(),
         blindSpotSuggestionProvider: @escaping (
             BlindSpotProviderRequest
         ) async throws -> BrainstormService.SuggestionResult = { request in
             try await BrainstormService.suggestionsWithExecution(
                 goal: request.goal,
                 transcript: request.transcript,
                 priorTitles: request.priorTitles,
                 accessToken: request.accessToken,
                 extraGuidance: request.guidance,
                 context: request.context,
                 probe: request.probe,
                 theme: request.theme,
                 grounded: request.grounded,
                 canProbe: request.canProbe)
         },
         factCheckProvider: @escaping (
             FactCheckProviderRequest, LLMModel
         ) async throws -> (claims: [FactClaim], search: FactCheckService.WebSearchOutcome?) = { request, model in
             try await FactCheckService.checkWithSearch(
                 transcript: request.transcript,
                 context: request.context,
                 accessToken: request.accessToken,
                 extraGuidance: request.extraGuidance,
                 model: model,
                 searchWeb: request.searchWeb)
         },
         blindSpotAccessTokenProvider: (() async -> String?)? = nil,
         blindSpotSkillGuidanceProvider: ((String, [String]) -> String?)? = nil,
         connectedGlossarySourceProvider: ConnectedGlossarySourceProvider? = nil,
         connectedGlossaryGroundedCycleConsumer: @escaping (Tier) -> Bool = {
             UsageTracker.consumeGroundedCycle(for: $0)
         },
         devCallDiagnostics: DevCallDiagnostics = .shared) {
        self.notificationCenter = notificationCenter
        self.devCallDiagnostics = devCallDiagnostics
        self.answerActionDispatcher = answerActionDispatcher
        self.transcriptionEngineSwitchOverride = transcriptionEngineSwitchOverride
        self.transcriptionServiceFactory = transcriptionServiceFactory
        self.localFinalPassServiceFactory = localFinalPassServiceFactory
        self.deepgramStreamerFactory = deepgramStreamerFactory
        self.transcriptionEngineAvailability = transcriptionEngineAvailability
        self.deepgramAuthOverride = deepgramAuthOverride
        self.firefliesTranscriptProvider = firefliesTranscriptProvider
        self.bgQueue = backgroundLLMQueue
        self.blindSpotSuggestionProvider = blindSpotSuggestionProvider
        self.factCheckProvider = factCheckProvider
        self.blindSpotAccessTokenProvider = blindSpotAccessTokenProvider
        self.blindSpotSkillGuidanceProvider = blindSpotSkillGuidanceProvider
        self.connectedGlossarySourceProvider = connectedGlossarySourceProvider
        self.connectedGlossaryGroundedCycleConsumer = connectedGlossaryGroundedCycleConsumer
        let configuredEngine = Config.transcriptionEngineValue
        let configuredLanguage = Config.transcriptionLanguage
        let configuredGlossary = Config.transcriptionGlossary
        let resolvedTranscriber = transcriber ?? transcriptionServiceFactory(
            configuredEngine, configuredLanguage, configuredGlossary,
            Config.localWhisperModel, nil)
        self.transcriber = resolvedTranscriber
        self.dictation = PromptDictation(transcriber: resolvedTranscriber)
        self.managesTranscriberLifecycle = transcriber == nil
        self.transcriberEngine = transcriber == nil ? configuredEngine : nil
        self.transcriberLocalModel = transcriber == nil && configuredEngine == .local
            ? Config.localWhisperModel : nil
        self.transcriberLanguage = transcriber == nil ? configuredLanguage : nil
        self.transcriberGlossary = transcriber == nil ? configuredGlossary : nil
        self.llm = llm
        self.sessionStore = sessionStore
        self.savedSessions = sessionStore.list()
        self.analytics = analytics
        self.credentialStore = credentialStore
        self.shouldInstallProcessCredentialCache = credentialStore is SystemKeychain
        // Normalize the saved model to what the current plan allows.
        if !Config.selectedModel.isAvailable(for: currentTier) {
            selectedModelID = LLMCatalog.defaultModel(for: currentTier).id
        }
        installSessionLifecycleObservers()
        // Managed-Whisper safety net: when the session degrades to on-device
        // (plan cap, outage, sign-out), tell the user once — the transcript
        // keeps flowing either way.
        (self.transcriber as? ServerFallbackTranscription)?.onFallback = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.transcriptionPerformanceNotice = TranscriptionPerformanceNotice(
                    message: reason, action: .none)
            }
        }
        guard !AppState.isUnderTest else { return }
        setUpCallDetection()
        applyReminderSettings()
        LiveTestHooks.install(for: self)   // dev builds only (no-op otherwise)
    }

    /// Restore account badges only after SwiftUI has presented the first
    /// window. SecItemCopyMatching performs Security-server XPC and can wait on
    /// a stale per-signature ACL; running it in scene construction previously
    /// prevented both the window and its accessibility tree from appearing.
    /// The stored task makes repeated ContentView appearances idempotent.
    func loadPersistedConnectionState() async {
        guard !persistedConnectionStateLoaded else { return }

        let task: Task<PersistedConnectionSnapshot, Never>
        if let existing = persistedConnectionLoadTask {
            task = existing
        } else {
            let store = credentialStore
            let revisions = Config.credentialCacheRevisions
            task = Task.detached(priority: .userInitiated) {
                let googleTokens = Config.loadGoogleTokens(from: store)
                let wheesprSession = Config.loadWheesprSession(from: store)
                return PersistedConnectionSnapshot(
                    googleTokens: googleTokens,
                    wheesprSession: wheesprSession,
                    googleCacheRevision: revisions.google,
                    wheesprCacheRevision: revisions.wheespr)
            }
            persistedConnectionLoadTask = task
        }

        let snapshot = await task.value
        guard !persistedConnectionStateLoaded else { return }
        persistedConnectionStateLoaded = true
        persistedConnectionLoadTask = nil

        // Never overwrite an explicit connect/disconnect that raced the
        // background startup read.
        if !googleConnectionMutatedSinceLaunch {
            if shouldInstallProcessCredentialCache {
                _ = Config.installLoadedGoogleTokens(
                    snapshot.googleTokens,
                    ifRevisionIs: snapshot.googleCacheRevision)
                googleConnected = Config.googleTokens != nil
            } else {
                googleConnected = snapshot.googleTokens != nil
            }
        }
        if !wheesprConnectionMutatedSinceLaunch {
            if shouldInstallProcessCredentialCache {
                _ = Config.installLoadedWheesprSession(
                    snapshot.wheesprSession,
                    ifRevisionIs: snapshot.wheesprCacheRevision)
                wheesprEmail = Config.wheesprSession?.email
                wheesprConnected = Config.wheesprSession != nil
            } else {
                wheesprEmail = snapshot.wheesprSession?.email
                wheesprConnected = snapshot.wheesprSession != nil
            }
            // The silent case: the Keychain row is gone (expired, revoked, or
            // unreadable after a signing-identity change) while UserDefaults
            // still records an account. Without this the app just comes up
            // looking like a fresh install with the connectors still attached.
            if !wheesprConnected { noteSignedOut(.sessionMissingAtLaunch) }
        }
        // Account hydration can make a saved managed engine runnable. Publish
        // that only while idle/error; a call already started keeps the engine
        // the user saw at its recording boundary. The raw preference remains
        // saved and is reconciled after Stop.
        if shouldInstallProcessCredentialCache {
            reconcileDisplayedTranscriptionEngineIfIdle()
        }
        rebuildPromptWorkflows()
        guard !AppState.isUnderTest else { return }
        applyReminderSettings()
        if wheesprConnected {
            Task { [weak self] in
                // Proactive refresh before the first API call when the access
                // token is already expired (avoids a silent anonymous downgrade).
                _ = await self?.wheesprAccessToken()
                await PaywallAPI.refreshEntitlement()
                self?.refreshTier()
            }
        }
    }

    deinit {
        aiTask?.cancel()
        tickTask?.cancel()
        brainstormTask?.cancel()
        agendaTask?.cancel()
        remindersTask?.cancel()
        firefliesEnhanceTask?.cancel()
        manualFirefliesEnhanceTask?.cancel()
        firefliesImportTask?.cancel()
        systemStreamer?.finish()
        micStreamer?.finish()
        // Block-based observers are NOT auto-removed on dealloc — without this,
        // every AppState (tests create hundreds per run) leaves dead observers
        // that NotificationCenter keeps dispatching onto the main queue forever.
        for token in sessionObservers {
            notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Call detection

    private func setUpCallDetection() {
        callNotifier.configure()
        callNotifier.onStartRecording = { [weak self] in self?.startFromNotification() }
        callNotifier.onNotificationsDenied = { [weak self] in
            self?.lastError = "Уведомления для orakul выключены. Включите их в «Системные настройки → Уведомления», чтобы получать напоминания о звонках."
        }
        callDetector.onCallDetected = { [weak self] appName in
            guard let self, !self.isRecording, !self.isBusy else { return }
            self.callNotifier.promptForCall(appName: appName)
        }
        applyCallDetectionSettings()
    }

    /// Start/stop the meeting-app watcher to match the user's setting.
    func applyCallDetectionSettings() {
        if Config.callDetectionEnabled { callDetector.start() } else { callDetector.stop() }
    }

    // MARK: - Appearance (light / dark / auto)

    /// Apply the saved theme to the whole app. Call once the UI is up.
    func applyAppearance() { AppearanceController.apply(appAppearance) }

    /// Change, persist, and apply the app theme from Settings.
    func setAppearance(_ preference: AppAppearance) {
        appAppearance = preference
        Config.appAppearance = preference
        AppearanceController.apply(preference)
    }

    // MARK: - Meeting reminders (scheduled from Google Calendar)

    /// Meetings polled at least this often; also re-synced on connect and when
    /// the reminder settings change. Kept below common lead times so a meeting
    /// added shortly before it starts still gets picked up.
    private static let reminderPollSeconds: UInt64 = 5 * 60

    /// Start or stop reminder polling to match the current settings + Google
    /// connection. Clears any scheduled reminders when it can't run.
    func applyReminderSettings() {
        guard Config.meetingRemindersEnabled, googleConnected else {
            stopReminderPolling()
            upcomingMeetings = []
            meetingBriefs = [:]
            briefsRequested = []
            Task { await reminderScheduler.clear() }
            return
        }
        startReminderPolling()
    }

    private func startReminderPolling() {
        remindersTask?.cancel()
        remindersTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncReminders()
                try? await Task.sleep(nanoseconds: AppState.reminderPollSeconds * 1_000_000_000)
            }
        }
    }

    private func stopReminderPolling() {
        remindersTask?.cancel()
        remindersTask = nil
    }

    /// Fetch upcoming events and reconcile scheduled reminders. Best-effort:
    /// transient calendar/auth failures are ignored so a flaky poll never
    /// disrupts the app (mirrors the brainstormer loop).
    private func syncReminders() async {
        guard Config.meetingRemindersEnabled, googleConnected,
              let current = Config.googleTokens else { return }
        do {
            let tokens = try await GoogleAuth.validTokens(
                clientID: effectiveGoogleClientID,
                clientSecret: effectiveGoogleClientSecret,
                current: current)
            if tokens.accessToken != current.accessToken { Config.googleTokens = tokens }
            let meetings = try await CalendarService.upcomingEvents(accessToken: tokens.accessToken)
            // Re-check after the awaits: the user may have disabled reminders or
            // disconnected Google mid-fetch, in which case applyReminderSettings
            // has already cleared the schedule and cancelled this task — don't
            // let a stale in-flight sync re-add reminders with no loop to undo it.
            guard !Task.isCancelled, Config.meetingRemindersEnabled, googleConnected else { return }
            upcomingMeetings = meetings
            proposeAttendeeDomainGlossarySuggestions()
            await reminderScheduler.sync(meetings: meetings, minutesBefore: Config.meetingReminderMinutes)
            await refreshMeetingBrief()
        } catch {
            Log.general.error("reminder sync skipped — \(error.localizedDescription)")
        }
    }

    /// Begin recording in response to the call-detection notification — but only
    /// from an idle/error state, never interrupting an in-flight session.
    private func startFromNotification() {
        switch status {
        case .idle, .error: Task { await startRecording() }
        default: break
        }
    }

    // MARK: - Brainstormer

    /// Live transcript flattened to text for the brainstormer.
    private var transcriptText: String {
        transcript.map { "[\($0.source.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    /// Poll the brainstormer while recording once an effective goal exists
    /// (typed, meeting name, or inferred). Best-effort —
    /// transient failures are ignored so it never disrupts the session.
    // MARK: - Goal auto-suggest (A3)

    /// Name the meeting from Calendar, then propose a distinct objective from
    /// the opening transcript when no explicit objective is set.
    private func startGoalSuggestion() {
        goalSuggestTask?.cancel()
        suggestedGoal = nil
        guard callGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        goalSuggestTask = Task { [weak self] in
            guard let self else { return }
            // 1) Calendar: the event happening now usually names the goal.
            if self.googleConnected, let current = Config.googleTokens {
                if let tokens = try? await GoogleAuth.validTokens(
                    clientID: self.effectiveGoogleClientID,
                    clientSecret: self.effectiveGoogleClientSecret,
                    current: current) {
                    if tokens.accessToken != current.accessToken { Config.googleTokens = tokens }
                    if let agenda = try? await CalendarService.currentAgenda(
                        accessToken: tokens.accessToken,
                        excluding: self.dismissedMeetingIDs) {
                        self.applyCalendarAgenda(agenda)
                    }
                }
            }
            // 2) Usable meeting name → working suggestion immediately so blind
            // spots can start without waiting on transcript.
            let title = self.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if GoalSuggestion.isUsableCalendarTitle(title) {
                self.suggestedGoal = title
            }

            // 3) Transcript (+ title): wait for opening minutes, then refine once.
            for _ in 0..<24 {   // poll ~6 minutes, then give up quietly
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, self.isRecording else { return }
                guard self.callGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let opening = self.transcriptText
                let named = self.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let minChars = GoalSuggestion.isUsableCalendarTitle(named) ? 250 : 400
                guard opening.count >= minChars else { continue }
                let system = """
                Infer the most useful outcome of this recording for the person capturing it.

                Follow the supplied recording type. For a meeting, write the OUTCOME the \
                call should produce. For a tutorial, lecture, video, podcast, interview, or \
                presentation, write the learning or application outcome (for example, \
                "Implement the demonstrated retry policy in our gateway"). Use an imperative \
                of at most 12 words, not a topic description.

                When the material names something measurable this recording is trying to move, \
                put it in the goal: a marketing call becomes "Raise qualified leads and \
                landing conversion", a hiring call "Fill the staff engineer role this \
                month". Use ONLY metrics, targets, accounts or projects that actually \
                appear in the material below — never invent a number, a percentage, or a \
                KPI that nobody mentioned.

                Weigh the sources: earlier calls from this team show what a recurring \
                meeting is FOR and which numbers it keeps returning to — a marketing sync \
                that has chased pipeline for three calls is still chasing it; for non-meeting \
                recordings, do not invent participants, decisions, owners, or commitments. The attached \
                context and connected-app material say what the team is actually working \
                on; the meeting name says what this session is; the transcript opening says \
                what is being discussed right now, and wins when it clearly diverges. \
                If the goal is genuinely unclear, return NONE.
                Return ONLY the goal text.
                """
                var user = "Recording context:\n\(self.effectiveRecordingContextGuidance)\n\n"
                if !named.isEmpty { user += "Meeting name: \(named)\n\n" }
                if self.callAttendeeCount > 0 {
                    user += "Attendees: \(self.callAttendeeCount)\n\n"
                }
                // Everything already attached to this call — imported documents,
                // notes, calendar agenda, and connector pulls (Fireflies, Notion,
                // "Research · <App>" chips) all land in contextFiles, so this is
                // where integration material reaches the inference. Budgeted: the
                // goal is a one-line answer, not a research task.
                let attached = self.promptContext(
                    query: named + "\n" + String(opening.prefix(1_500)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !attached.isEmpty {
                    user += "Attached context and connected apps:\n\(String(attached.prefix(4_000)))\n\n"
                }
                // Prior calls from the meetings connector (Fireflies) and the
                // team's logged decisions. A recurring sync only reads as "raise
                // qualified leads" once you have seen what the last few were
                // about, so this is the strongest available signal.
                //
                // runGeneration: -1 can never equal aiRunGeneration (which counts
                // up from 0), so every workflow-trace and stage update inside
                // groundingSnippets is skipped — this is background inference and
                // must not draw itself on the visible run.
                if let priorWorkflow = PromptWorkflows.spec(for: "goal") {
                    let priorQuery = named.isEmpty ? String(opening.prefix(400)) : named
                    let priorCalls = await self.groundingSnippets(
                        for: priorWorkflow, promptID: "goal",
                        query: priorQuery, runGeneration: -1)
                    if !priorCalls.isEmpty {
                        let block = PromptWorkflows.renderGrounding(priorCalls)
                        user += "Earlier calls and logged decisions from this team:\n"
                            + String(block.prefix(4_000)) + "\n\n"
                    }
                }
                user += "Transcript opening:\n\(String(opening.prefix(2_500)))"
                let raw = try? await self.trackingComputeUsage {
                    try await self.llm.streamChat(
                        system: system, user: user,
                        model: LLMCatalog.fastAudit(for: Config.selectedModel)) { _ in }
                }
                if let goal = GoalSuggestion.sanitizeModelGoal(raw ?? ""),
                   self.callGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Placed straight into the empty field rather than offered as a
                    // chip to accept. It already drove blind spots through
                    // effectiveCallGoal, so the chip asked for a click that changed
                    // nothing except whether the user could SEE what was steering
                    // their call. Marked as proposed so it stays obviously editable.
                    self.applyProposedGoal(goal)
                }
                return
            }
        }
    }

    /// Apply the event only after the async fetch returns. The policy re-checks
    /// the current title so a user edit made during the request always wins.
    func applyCalendarAgenda(_ agenda: CalendarAgenda) {
        // A fetch in flight when the user hides the meeting must not land. The
        // request started before the dismissal; the answer arrives after it.
        guard agenda.id.isEmpty || !dismissedMeetingIDs.contains(agenda.id) else { return }
        callAttendeeCount = agenda.attendeeCount
        let calendarTitle = agenda.title.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingTitle = MeetingTitlePolicy.applyingCalendarTitle(
            agenda.title,
            to: meetingTitle
        )
        if suggestedGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(calendarTitle) == .orderedSame {
            suggestedGoal = nil
        }
        // Calendar names belong in the header — never duplicate them in Co-pilot.
        if callGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(calendarTitle) == .orderedSame {
            callGoal = ""
        }
        if !agenda.id.isEmpty {
            syncedCalendarEvent = SyncedCalendarEvent(id: agenda.id, title: calendarTitle)
        }
        noteCalendarSync(agenda)
    }

    /// The calendar event whose agenda is currently folded into the workspace.
    struct SyncedCalendarEvent: Equatable {
        let id: String
        let title: String
    }

    /// Which meeting named this call, so hiding that meeting can take its name,
    /// its agenda file and its attendee count back out with it.
    @Published private(set) var syncedCalendarEvent: SyncedCalendarEvent?

    /// What the calendar sync loaded, as a STATUS LINE — not a blind spot.
    ///
    /// This used to insert a synthetic `.advice` Suggestion at index 0 of the
    /// blind-spot list. Three things were wrong with that. It carried no
    /// transcript evidence, unlike every real suggestion, so it was the one card
    /// that could not be grounded. It pushed actual blind spots down. And on a
    /// call reopened from History it told the user to "set a goal for live
    /// blind-spot checks" about a meeting that had already finished.
    ///
    /// The fact is worth showing — it just is not a finding. The panel renders it
    /// as a quiet line, and the agenda still feeds goal inference, which is where
    /// an assumption about the call's purpose belongs.
    @Published var calendarSyncNote: String = ""

    private func noteCalendarSync(_ agenda: CalendarAgenda) {
        let title = agenda.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !MeetingTitlePolicy.isUnusableCalendarTitle(title) else {
            calendarSyncNote = ""
            return
        }
        var loaded: [String] = []
        if agenda.summary.contains("Agenda:") { loaded.append("agenda") }
        if agenda.attendeeCount > 0 { loaded.append("\(agenda.attendeeCount) attendees") }
        calendarSyncNote = loaded.isEmpty
            ? "Synced “\(title)”"
            : "Synced “\(title)” — \(loaded.joined(separator: ", ")) in context"
    }


    private func stopGoalSuggestion() {
        goalSuggestTask?.cancel()
        goalSuggestTask = nil
        stopTitleSuggestion()
    }

    /// Fill the empty Co-pilot field with the inferred goal, flagged so the UI
    /// can show it as a proposal and the user can clear it in one click.
    /// Internal rather than private so the proposal/ownership transitions are
    /// directly testable without driving a live inference pass.
    func applyProposedGoal(_ goal: String) {
        isApplyingProposedGoal = true
        callGoal = goal
        isApplyingProposedGoal = false
        goalWasProposed = true
        suggestedGoal = nil
    }

    /// Drop a proposed goal and let inference offer another one later.
    func clearProposedGoal() {
        guard goalWasProposed else { return }
        isApplyingProposedGoal = true
        callGoal = ""
        isApplyingProposedGoal = false
        goalWasProposed = false
        suggestedGoal = nil
    }

    func acceptSuggestedGoal() {
        if let suggestion = suggestedGoal { callGoal = suggestion }
        suggestedGoal = nil
    }

    func dismissSuggestedGoal() {
        suggestedGoal = nil
    }

    // MARK: - Meeting title proposal (5 minutes in, still untitled)

    /// Proposed name for an untitled meeting, offered as a chip next to the
    /// title field — accepted or dismissed, never silently applied.
    @Published var suggestedMeetingTitle: String?
    private var titleSuggestTask: Task<Void, Never>?

    func startTitleSuggestion() {
        titleSuggestTask?.cancel()
        suggestedMeetingTitle = nil
        titleSuggestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MeetingTitleProposal.delaySeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // Plain text only — the [system]/[mic] speaker tags are noise for
            // naming a meeting.
            let plainTranscript = self.transcript.map(\.text).joined(separator: "\n")
            guard MeetingTitleProposal.shouldPropose(
                title: self.meetingTitle,
                transcriptCharacters: plainTranscript.count,
                isRecording: self.isRecording) else { return }
            let raw = try? await self.llm.streamChat(
                system: MeetingTitleProposal.systemPrompt,
                user: String(plainTranscript.suffix(4_000)),
                model: LLMCatalog.fastAudit(for: Config.selectedModel)) { _ in }
            guard let raw, !Task.isCancelled else { return }
            let title = AssistantAnswerTitle.cleaned(raw, prompt: "")
            // Re-check after the await: the user may have typed a title while
            // the model was thinking — their text always wins.
            guard !title.isEmpty,
                  !MeetingTitlePolicy.isUnusableCalendarTitle(title),
                  self.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            self.suggestedMeetingTitle = title
        }
    }

    func stopTitleSuggestion() {
        titleSuggestTask?.cancel()
        titleSuggestTask = nil
    }

    func acceptSuggestedMeetingTitle() {
        if let title = suggestedMeetingTitle { meetingTitle = title }
        suggestedMeetingTitle = nil
    }

    func dismissSuggestedMeetingTitle() {
        suggestedMeetingTitle = nil
    }

    // MARK: - Rolling call digest (A2)

    private static let digestFoldIntervalNs: UInt64 = 120_000_000_000  // 2 min
    private static let digestMinNewChars = 4_000

    private func startDigestLoop() {
        digestTask?.cancel()
        callDigest = ""
        digestedEntryCount = 0
        digestTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.digestFoldIntervalNs)
                guard let self, self.isRecording else { break }
                await self.foldDigest()
            }
        }
    }

    /// Cancel the folder but KEEP the digest — post-call button presses still
    /// need early-call content. A new recording resets it.
    private func stopDigestLoop() {
        digestTask?.cancel()
        digestTask = nil
    }

    /// Fold transcript that arrived since the last fold into the digest, on the
    /// fast-audit model. Skips small increments; on failure leaves state
    /// untouched so the next tick retries the same span.
    private func foldDigest() async {
        let entries = transcript
        guard entries.count > digestedEntryCount else { return }
        let newText = SystemInstructions.formatEntries(Array(entries[digestedEntryCount...]))
        guard newText.count >= Self.digestMinNewChars else { return }

        let system = """
        You maintain the rolling digest of a live meeting so that later analysis retains early \
        content. Fold the NEW transcript segment into the CURRENT digest. Preserve: decisions \
        (keep a short verbatim quote + speaker), action items with stated owner/due, open \
        questions, key numbers and claims, and topic shifts. Update items that were superseded; \
        drop chit-chat. At most 300 words, grouped bullets, oldest first. Return ONLY the updated \
        digest.
        """
        let user = "CURRENT digest:\n\(callDigest.isEmpty ? "(empty)" : callDigest)\n\nNEW transcript segment:\n\(newText)"
        guard let folded = try? await trackingComputeUsage({
            try await llm.streamChat(
                system: system, user: user,
                model: LLMCatalog.fastAudit(for: Config.selectedModel), onDelta: { _ in })
        }),
            !folded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        callDigest = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        digestedEntryCount = entries.count
    }

    // MARK: - Answer refine (item 20)

    /// The last refine: the original text, and the refined text it produced.
    /// Revert is offered only while that refined text is still what is on screen,
    /// so a new prompt (which replaces `aiResponse`) auto-invalidates the revert
    /// without every run site having to clear it.
    @Published private(set) var lastRefine: (original: String, refined: String)?
    /// True while a refine pass is in flight — the controls disable, like a run.
    @Published private(set) var isRefining = false

    /// Whether the visible answer may be refined: it is prose (not a structured
    /// contract like a DACI or a fact check), it is present, and nothing else is
    /// running. Refusing a structured answer is deliberate — a free rewrite would
    /// break its contract, and the acceptance says refusing is fine.
    var canRefineCurrentAnswer: Bool {
        !aiStreaming && !isRefining
            && !aiResponse.trimmingCharacters(in: .whitespaces).isEmpty
            && AnswerRefine.canRefine(promptID: aiResponsePromptID)
    }

    /// Reshape the visible answer in place, keeping the original recoverable.
    /// User-invoked ONLY — never part of producing an answer — so the second
    /// call is one the user asked for and pays for knowingly (item 20).
    func refineCurrentAnswer(_ kind: AnswerRefine.Kind) {
        guard canRefineCurrentAnswer else { return }
        let original = aiResponse
        isRefining = true
        Task { @MainActor in
            defer { isRefining = false }
            guard let refined = try? await trackingComputeUsage({
                try await llm.streamChat(
                    system: AnswerRefine.systemPrompt(for: kind),
                    user: AnswerRefine.userPrompt(answer: original),
                    model: Config.selectedModel, onDelta: { _ in })
            }), !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastError = "Не удалось уточнить ответ — исходный остался как был."
                return
            }
            // Recorded only on SUCCESS, and paired with the produced text so a
            // failed refine leaves no phantom revert.
            let clean = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            aiResponse = clean
            lastRefine = (original: original, refined: clean)
        }
    }

    /// Whether a revert is available: a refine happened AND its result is still
    /// the visible answer (a later prompt would have replaced it).
    var canRevertRefine: Bool {
        guard let last = lastRefine else { return false }
        return aiResponse == last.refined
    }

    #if DEBUG
    /// Test seam: `aiResponsePromptID` is private(set), and the refine guard
    /// keys on it. Lets a test stand up a structured-vs-prose answer without
    /// driving a full prompt run.
    func setAIResponsePromptIDForTesting(_ id: String?) { aiResponsePromptID = id }
    #endif

    /// Restore the answer as it was before the last refine.
    func revertRefine() {
        guard let last = lastRefine, aiResponse == last.refined else { return }
        aiResponse = last.original
        lastRefine = nil
    }

    // MARK: - Session persistence (M3)

    /// Persist the current meeting under the recording's stable session id.
    /// Called on stop and after post-call AI runs; a failed write surfaces as
    /// lastError (silent loss is the bug this exists to fix).
    func persistCurrentSession() {
        // The onboarding sample is fiction replayed into this workspace. It
        // satisfies every condition below — a transcript, a title, a start time
        // — so this guard is the only thing keeping a written call out of the
        // user's History.
        guard !sampleRunActive else { return }
        // Only persist a real meeting — one that was actually recorded or
        // restored (both set recordingStartedAt). This stops AI-only scratch
        // interactions on a fresh workspace from spawning a History track.
        guard !transcript.isEmpty, recordingStartedAt != nil else { return }
        let recordedEngines = Set(transcript.compactMap(\.transcriptionEngine))
        let uniformEngine = recordedEngines.count == 1 ? recordedEngines.first : nil
        let session = SavedSession(
            id: currentSessionID,
            title: meetingTitle,
            startedAt: recordingStartedAt ?? Date(),
            savedAt: Date(),
            goal: callGoal,
            recordingContext: recordingContextSelection,
            entries: transcript,
            transcriptionEngine: uniformEngine,
            aiResponse: aiResponse,
            aiResponsePrompt: aiResponsePrompt.isEmpty ? nil : aiResponsePrompt,
            aiResponseExportTitle: aiResponseExportTitle,
            aiHistory: aiHistory.isEmpty ? nil : aiHistory,
            contextFiles: contextFiles.isEmpty ? nil : contextFiles,
            contextNotes: contextNotes.isEmpty ? nil : contextNotes,
            suggestions: suggestions.isEmpty ? nil : suggestions,
            digest: callDigest,
            factClaims: factClaims.isEmpty ? nil : factClaims,
            rhetoricNote: rhetoricNote.isEmpty ? nil : rhetoricNote,
            facilitationNote: facilitationNote.isEmpty ? nil : facilitationNote,
            followUp: efficiencyFollowUp
        )
        do {
            try sessionStore.save(session)
            savedSessions = sessionStore.list()
        } catch {
            lastError = "Не удалось сохранить звонок: \(error.localizedDescription)"
        }
    }

    /// Load a saved session back into the workspace (blocked while recording).
    func restoreSession(_ session: SavedSession) {
        guard !isRecording, status == .idle else { return }
        cancelFirefliesEnhance()
        invalidateLocalFinalPassTasks(discardRetainedAudio: true)
        // Save the call being navigated AWAY from before its workspace is
        // overwritten. Without this, anything changed since the last automatic
        // write — assistant answers, imported documents, notes — was discarded
        // the moment another call was opened, and switching back showed a stale
        // meeting. No-op when there is nothing worth saving.
        if session.id != currentSessionID { persistCurrentSession() }
        supersedeActiveAI()
        workflowSteps = []
        stepSeq = 0
        followUpPrompts = []
        factClaims = []
        factCheckError = nil
        // A final partial chunk may still be decoding just after Stop. Loading
        // History must invalidate that work before replacing the workspace, or
        // the old meeting can append into (and overwrite) the restored session.
        chunkGeneration &+= 1
        recordingGenerationToken = nil
        // Saved sessions contain text, not retained audio. Never let the prior
        // live meeting's recorder remain attached to a restored History item —
        // doing so could upload old audio from the new workspace's Diarize UI.
        sessionRecorder.reset()
        sessionRetainedAudioStart = nil
        sessionAudioStart = nil
        sessionAudioStartSample = 0
        sessionRetainedAudioTimelineValid = true
        localFinalPassContinuityValid = false
        activeSessionPreparedLocalWhisperModel = nil
        serverDiarizationEligibleForSession = false
        currentSessionID = session.id      // further saves update the same file
        // The workspace is now showing a PAST meeting rather than the one being
        // worked on. This is what puts the "New call" affordance on screen: it
        // is the way back out of History, and showing it permanently made it
        // clutter on the one screen where there is nothing to go back from.
        isViewingRestoredSession = true
        // Session-level provenance upgrades entries written by an early build
        // that knew the recording engine but did not yet stamp each line. This
        // makes a restored Local call obey the same no-false-speaker contract.
        transcript = session.entries.map {
            $0.recordingEngineIfMissing(session.transcriptionEngine)
        }
        meetingTitle = session.title
        callGoal = session.goal
        recordingContextSelection = session.recordingContext ?? .automatic
        detectedRecordingContext = RecordingContextDetector.infer(
            windowTitles: session.title.isEmpty ? [] : [session.title])
        // An untitled session gives the detector nothing to read, so restoring
        // it is not a detection — only a titled one is.
        hasDetectedRecordingContext = !session.title.isEmpty
        aiResponse = session.aiResponse
        aiResponsePrompt = session.aiResponsePrompt ?? ""
        submittedPromptPreview = nil
        aiResponseID = nil
        aiResponsePromptID = nil
        aiResponseStartedAt = nil
        aiResponseCompletedAt = nil
        aiResponseStatus = session.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : AnswerFailure.looksLikeFailure(session.aiResponse) ? .failed : .succeeded
        aiResponseModelID = nil
        aiResponseExportTitle = session.aiResponseExportTitle
        aiHistory = session.aiHistory ?? []
        aiExchangeEvidence = aiHistory
        // Absent on every session saved before context was persisted, which
        // must CLEAR the panel rather than leave the previous call's documents
        // grounding this one.
        contextFiles = session.contextFiles ?? []
        contextNotes = session.contextNotes ?? ""
        // Blind spots belong to the meeting that produced them — restored with
        // it, rather than cleared (which showed none) or left in place (which
        // showed the PREVIOUS call's).
        suggestions = session.suggestions ?? []
        // Everything the co-pilot concluded about THIS meeting comes back with
        // it. Absent on sessions saved before these were persisted, which must
        // clear rather than leave the previous call's verdicts standing.
        factClaims = session.factClaims ?? []
        rhetoricNote = session.rhetoricNote ?? ""
        facilitationNote = session.facilitationNote ?? ""
        efficiencyFollowUp = session.followUp
        // A per-call pause does not carry into the call being opened.
        suggestionsSnoozedThisCall = false
        transcriptEnhanceNote = nil
        lastChunkText.removeAll()
        callDigest = session.digest
        recordingStartedAt = session.startedAt
        provisional.removeAll()
        lastError = nil
    }

    /// Leave whatever meeting is open and start a clean one, without recording.
    ///
    /// Opening a call from History used to be a one-way door: the workspace was
    /// that meeting until a new RECORDING replaced it, so reading an old call
    /// and then wanting a blank one meant starting a recording you did not want.
    ///
    /// Persists the outgoing call first, exactly as `restoreSession` does —
    /// anything changed since the last automatic write (assistant answers,
    /// imported documents, notes) would otherwise be discarded.
    // MARK: - Importing a past Fireflies call

    /// Meetings offered by the Fireflies picker, newest first.
    @Published var firefliesMeetings: [FirefliesPastCalls.MeetingSummary] = []
    /// True while either listing or importing, so the picker can show progress
    /// and refuse a second tap.
    @Published var firefliesImportBusy = false
    @Published var firefliesImportError: String?

    /// Whether the import affordance should appear at all.
    ///
    /// Fireflies must be a connected app; otherwise the button is an invitation
    /// to an error dialog.
    var canImportFromFireflies: Bool {
        guard !isRecording, status == .idle else { return false }
        return mcp?.isConnected("fireflies") == true
    }

    /// Load the list the picker shows. Safe to call again — it replaces.
    func loadFirefliesMeetings() {
        guard let manager = mcp, !firefliesImportBusy else { return }
        firefliesImportBusy = true
        firefliesImportError = nil
        Task { @MainActor in
            defer { firefliesImportBusy = false }
            do {
                firefliesMeetings = try await manager.firefliesRecentMeetings()
                if firefliesMeetings.isEmpty {
                    firefliesImportError = "Fireflies не отдал ни одной встречи для этого аккаунта."
                }
            } catch {
                firefliesMeetings = []
                firefliesImportError = "Не достучались до Fireflies. \(Self.systemSaid(error))"
            }
        }
    }

    /// Import one meeting, save it, and open it — so the user lands in the call
    /// they just chose rather than having to find it in the list they came from.
    func importFirefliesMeeting(_ meeting: FirefliesPastCalls.MeetingSummary,
                                onFinished: @escaping (Bool) -> Void = { _ in }) {
        guard let manager = mcp, !firefliesImportBusy else { return onFinished(false) }
        firefliesImportBusy = true
        firefliesImportError = nil
        Task { @MainActor in
            defer { firefliesImportBusy = false }
            do {
                let session = try await manager.firefliesImportMeeting(meeting, goal: callGoal)
                // Второй раз тот же звонок не заводим: нажать «импортировать»
                // повторно, не поняв, сработало ли, — обычное дело, а копии
                // вытесняют из ответа разные звонки, мест в нём три. Решение —
                // в хранилище, где его можно проверить тестом.
                let stored = try sessionStore.saveImported(session)
                savedSessions = sessionStore.list()
                restoreSession(stored)
                // A past call from the same team is the cheapest rich glossary
                // source there is: no upload, no credits, and its vocabulary is
                // the vocabulary of the calls still to come.
                proposeGlossaryFromPastTranscript(session)
                onFinished(true)
            } catch {
                firefliesImportError = "Не смог перенести эту встречу. \(Self.systemSaid(error))"
                onFinished(false)
            }
        }
    }

    func startNewCall() {
        guard !isRecording, status == .idle else { return }
        persistCurrentSession()
        supersedeActiveAI()
        resetForNewRecording()
        recordingContextSelection = .automatic
        detectedRecordingContext = .meeting
        hasDetectedRecordingContext = false
        // resetForNewRecording keeps the context panel (a new recording usually
        // wants the same documents). An explicitly-requested blank call does
        // not: the previous meeting's documents would silently ground it.
        contextFiles.removeAll()
        contextNotes = ""
        clearTranscriptSelection()
        pendingClarification = nil
        answerActions = []
        answerActionResult = nil
        transcriptEnhanceNote = nil
        lastChunkText.removeAll()
        lastError = nil
        savedSessions = sessionStore.list()
    }

    /// Что сказала система — по-русски настолько, насколько она умеет.
    ///
    /// `localizedDescription` берёт язык системы: у русской macOS он русский,
    /// у английской — английский. Наше дело — не выдавать его за наш текст и
    /// не оставлять человека один на один со строкой без подлежащего.
    static func systemSaid(_ error: Error) -> String {
        "Система ответила: \(error.localizedDescription)"
    }

    /// Turn a failed request into something the user can act on.
    ///
    /// URLSession's own text for a refused connection is "Could not connect to
    /// the server." — which server, and what to do about it, are exactly the two
    /// things missing. When the app routes LLM traffic through the backend
    /// (LLM_GATEWAY=backend) and that backend is not running, every prompt fails
    /// with that sentence and nothing in the UI says the backend is the reason.
    func explain(_ error: Error) -> String {
        let urlError = error as? URLError
        let connectionFailed: Set<URLError.Code> = [
            .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
            .notConnectedToInternet, .timedOut, .dnsLookupFailed
        ]
        guard let urlError, connectionFailed.contains(urlError.code) else {
            return "Ошибка: \(Self.systemSaid(error))"
        }

        let host = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Config.llmViaBackend, !host.isEmpty else {
            return "Ошибка: \(Self.systemSaid(error))"
        }
        if urlError.code == .notConnectedToInternet {
            return "Ошибка: нет сети, а ответы модели идут через сервер — без сети он недоступен."
        }
        return """
        Ошибка: не достучались до сервера `\(host)`.

        Ответы модели настроены идти через него (`LLM_GATEWAY=backend`), и пока он молчит, \
        ни один вопрос не выполнится. Либо запустите сервер, либо укажите в `BACKEND_URL` \
        работающий и пересоберите. Ключ провайдера прямо в настройках сервера не требует.
        """
    }

    /// Whether "New call" would do anything — false on an already-blank
    /// workspace, so the control can disable rather than no-op silently.
    /// True while the workspace is showing a meeting opened from History rather
    /// than the current one. Set by `restoreSession`, cleared the moment the
    /// workspace stops being a view onto the past — a new call, or a new
    /// recording.
    @Published private(set) var isViewingRestoredSession = false

    var canStartNewCall: Bool {
        guard !isRecording, status == .idle else { return false }
        return !transcript.isEmpty
            || !aiResponse.isEmpty
            || !aiHistory.isEmpty
            || !meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !allContextFiles.isEmpty
    }

    /// Whether to OFFER the new-call affordance at the top of the sidebar.
    ///
    /// Narrower than `canStartNewCall` on purpose. Opening a call from History
    /// is a one-way door without it — the only other way back to a blank
    /// workspace is starting a recording nobody wanted — but on the live call
    /// that door leads nowhere, so a permanent button there is a destructive
    /// action sitting next to the work it would clear.
    var shouldOfferNewCall: Bool {
        isViewingRestoredSession && canStartNewCall
    }

    func deleteSession(id: UUID) {
        sessionStore.delete(id: id)
        savedSessions = sessionStore.list()
    }

    /// Remove all saved meetings (History → Clear all). Destructive + irreversible;
    /// the caller confirms first.
    func clearAllHistory() {
        sessionStore.deleteAll()
        savedSessions = []
    }

    // MARK: - Ledger read view (M3e — the ledger was write-only from the app)

    /// True while recognition is rejecting a high share of segments — the audio,
    /// not the model, is the problem. Blind-spot cards hide their transcript quote
    /// while this holds, because a garbled quote discredits a correct finding.
    ///
    /// Published rather than computed on the fly so the cards re-render when it
    /// flips; refreshed on the same tick that appends transcript.
    @Published var speechQualityIsPoor = false

    /// Non-nil only while a recording is starting and its captured audio routes
    /// are not ready for a live handoff yet. During `.recording`, engine changes
    /// synchronously reconfigure those routes and clear this value.
    @Published private(set) var pendingEngineChange: TranscriptionEngine?
    /// Settings' selected row. Unlike a view-local `@State`, this follows an
    /// asynchronous pre-ready Deepgram rollback immediately.
    @Published private(set) var selectedTranscriptionEngine = Config.transcriptionEngineValue

    /// Pure startup-race policy. Hydration may republish a newly available
    /// saved engine only when no recording boundary is active.
    static func transcriptionEngineAfterCredentialHydration(
        displayed: TranscriptionEngine,
        resolvedAfterHydration: TranscriptionEngine,
        callInFlight: Bool
    ) -> TranscriptionEngine {
        callInFlight ? displayed : resolvedAfterHydration
    }

    /// The engine used at Record must be the published Settings row, not a
    /// freshly re-resolved preference that could change during Keychain load.
    static func recordingBoundaryEngine(
        displayed: TranscriptionEngine,
        displayedIsAvailable: Bool
    ) -> TranscriptionEngine {
        displayedIsAvailable ? displayed : .local
    }

    /// Resolve and publish the exact route before any slow model/network work.
    /// The raw saved preference is intentionally untouched: account hydration
    /// may make it available again for a later call, but this call's Settings
    /// row must always describe the route that can actually start now.
    func publishRecordingBoundaryEngine() -> TranscriptionEngine {
        let engine = Self.recordingBoundaryEngine(
            displayed: selectedTranscriptionEngine,
            displayedIsAvailable: transcriptionEngineAvailability(
                selectedTranscriptionEngine))
        selectedTranscriptionEngine = engine
        return engine
    }

    private func reconcileDisplayedTranscriptionEngineIfIdle() {
        let canRepublish: Bool
        switch status {
        case .idle, .error: canRepublish = true
        default: canRepublish = false
        }
        selectedTranscriptionEngine = Self.transcriptionEngineAfterCredentialHydration(
            displayed: selectedTranscriptionEngine,
            resolvedAfterHydration: Config.transcriptionEngineValue,
            callInFlight: !canRepublish)
    }

    /// Persist an engine choice and, when audio is already flowing, move the
    /// active call to it immediately. A failed handoff restores both the saved
    /// choice and the active snapshot, so Settings never claims Instant while
    /// the call is still using its previous chunk engine.
    @discardableResult
    func selectTranscriptionEngine(_ engine: TranscriptionEngine) -> Bool {
        let previousConfigured = Config.transcriptionEngineValue
        let previousSettings = activeRecordingSettings ?? RecordingSettingsSnapshot.configured()
        let previousEngine = activeSessionEngine ?? previousSettings.engine
        let available = transcriptionEngineSwitchOverride != nil
            || transcriptionEngineAvailability(engine)
        guard available else {
            pendingEngineChange = nil
            lastError = "«\(engine.advantageTitle)» недоступно для этой учётной записи. Звонок продолжается на «\(previousEngine.advantageTitle)»."
            return false
        }

        // Paused capture has no active audio callbacks to reroute. Persisting a
        // different row here would make Settings claim one engine while Resume
        // silently continues on the old route.
        if status == .paused {
            pendingEngineChange = nil
            guard engine == previousEngine else {
                lastError = "Возобновите звонок перед сменой движка. Пауза продолжается на «\(previousEngine.advantageTitle)»."
                return false
            }
            return true
        }

        // Capture startup owns a fixed, already-published engine snapshot. A
        // different selection here used to publish Private immediately while
        // startup could still open the old Instant route and send audio before
        // applying the pending switch. Keep both the saved and visible choice
        // unchanged until capture reaches a routable state.
        if status == .starting {
            pendingEngineChange = nil
            let startupEngine = selectedTranscriptionEngine
            guard engine == startupEngine else {
                lastError = "Дождитесь начала записи перед сменой движка. Запуск продолжается на «\(startupEngine.advantageTitle)»."
                return false
            }
            return true
        }

        Config.transcriptionEngineValue = engine
        selectedTranscriptionEngine = engine
        guard status == .recording else {
            pendingEngineChange = nil
            return true
        }
        guard engine != previousEngine else {
            pendingEngineChange = nil
            return true
        }

        pendingEngineChange = engine

        guard switchActiveTranscriptionEngine(
            to: engine, replacing: previousSettings, previousEngine: previousEngine
        ) else {
            Config.transcriptionEngineValue = previousConfigured
            selectedTranscriptionEngine = previousConfigured
            pendingEngineChange = nil
            lastError = "Не удалось переключить звонок на «\(engine.advantageTitle)». Он продолжается на «\(previousEngine.advantageTitle)»."
            return false
        }

        activeSessionEngine = engine
        activeRecordingSettings = previousSettings.replacingEngine(with: engine)
        noteSuccessfulEngineTransition(from: previousEngine, to: engine)
        pendingEngineChange = nil
        return true
    }

    private func noteSuccessfulEngineTransition(
        from previousEngine: TranscriptionEngine,
        to engine: TranscriptionEngine
    ) {
        if previousEngine == .local, engine != .local {
            // Retained PCM now includes a non-Local route. A later transition
            // may establish a fresh suffix boundary, but this old continuous
            // interval must never remain eligible across cloud audio.
            localFinalPassContinuityValid = false
            localFinalPassOptedInForSession = false
            localDiarizationContinuityValid = false
            localDiarizationOptedInForSession = false
            sessionAudioStart = nil
            sessionAudioStartSample = 0
            activeSessionPreparedLocalWhisperModel = nil
            if !hasSessionDiarizationAudioConsumer {
                // The route callbacks have already been redirected without a
                // retention observer. Release the now-ineligible Local prefix
                // instead of carrying ~115 MB until an unrelated workspace
                // action happens to clear it.
                sessionRecorder.discard()
                sessionRetainedAudioStart = nil
            }
        }
    }

    /// Legacy state-only seam used by the deterministic dev fixture while it
    /// stages Settings mutations. Production Settings uses
    /// `selectTranscriptionEngine(_:)` so the runtime and the row move together.
    func notePendingEngineChange(_ engine: TranscriptionEngine) {
        let callInFlight = status == .starting || status == .recording || status == .stopping
        guard callInFlight else {
            pendingEngineChange = nil
            return
        }
        // Selecting the engine already used by this recording is a revert, not
        // a pending change. This also clears switch-away-then-back UI.
        pendingEngineChange = engine == activeSessionEngine ? nil : engine
    }

    struct LiveTranscriptionConfiguration: Equatable {
        let configured: RecordingSettingsSnapshot
        let active: RecordingSettingsSnapshot?
        let pendingEngine: TranscriptionEngine?
    }

    func liveTranscriptionConfiguration() -> LiveTranscriptionConfiguration {
        LiveTranscriptionConfiguration(
            configured: .configured(),
            active: activeRecordingSettings,
            pendingEngine: pendingEngineChange)
    }

    func applyTestActiveRecordingSettings(_ settings: RecordingSettingsSnapshot?) {
        guard Self.isUnderTest else { return }
        activeRecordingSettings = settings
        activeSessionEngine = settings?.engine
        activeSessionLanguage = settings?.language
    }

    func applyTestDisplayedTranscriptionEngine(_ engine: TranscriptionEngine) {
        guard Self.isUnderTest else { return }
        selectedTranscriptionEngine = engine
    }

    /// Install the two already-retained capture routes and generation identity
    /// that exist during a real call. This deliberately does not replace the
    /// switch implementation: `selectTranscriptionEngine` still traverses the
    /// production reroute, Deepgram startup, and rollback methods.
    func installTestLiveTranscriptionRuntime(
        settings: RecordingSettingsSnapshot,
        systemChunker: AudioChunkBuffer,
        micChunker: AudioChunkBuffer,
        generation: Int = 1
    ) {
        guard Self.isUnderTest else { return }
        // Флаг с прошлого звонка не должен встречать следующий.
        systemAudioLostDuringRecording = false
        microphoneLostDuringRecording = false
        status = .recording
        activeRecordingSettings = settings
        activeSessionEngine = settings.engine
        activeSessionLanguage = settings.language
        selectedTranscriptionEngine = settings.engine
        self.systemChunker = systemChunker
        self.micChunker = micChunker
        chunkGeneration = generation
        let generationToken = RecordingGenerationToken(generation)
        recordingGenerationToken = generationToken
        transcriberEngine = settings.engine
        transcriberLocalModel = settings.engine == .local ? settings.localModel : nil
        transcriberLanguage = settings.language
        transcriberGlossary = settings.glossary
        if settings.engine != .deepgram {
            let routeLease = TranscriptionRouteLease()
            activeChunkRouteLease = routeLease
            systemChunker.reconfigure(
                onChunk: liveChunkHandler(
                    source: .system, transcriber: transcriber, engine: settings.engine,
                    generationToken: generationToken, routeLease: routeLease),
                onSamples: nil, discardBufferedSamples: false)
            micChunker.reconfigure(
                onChunk: liveChunkHandler(
                    source: .mic, transcriber: transcriber, engine: settings.engine,
                    generationToken: generationToken, routeLease: routeLease),
                onSamples: nil, discardBufferedSamples: false)
        } else {
            activeChunkRouteLease = nil
        }
    }

    /// Test seam for the MainActor completion of an asynchronous Deepgram
    /// setup failure; real audio/socket teardown is covered by the generation
    /// and buffer-routing units rather than opening hardware in a unit test.
    func applyTestTranscriptionEngineRollback(_ settings: RecordingSettingsSnapshot) {
        guard Self.isUnderTest else { return }
        publishTranscriptionEngineRollback(settings)
    }

    private func publishTranscriptionEngineRollback(_ settings: RecordingSettingsSnapshot) {
        Config.transcriptionEngineValue = settings.engine
        selectedTranscriptionEngine = settings.engine
        activeRecordingSettings = settings
        activeSessionEngine = settings.engine
        pendingEngineChange = nil
    }

    /// The team's recent ledger decisions, for the sidebar list.
    @Published var ledgerDecisions: [DecisionLogService.LedgerDecision] = []
    @Published var ledgerLoading = false

    /// Whether the ledger UI has any chance of working (backend configured).
    var ledgerConfigured: Bool {
        !Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// goalType -> the contract's field order, from `GET /api/goal-contracts`.
    /// Fetched rather than hardcoded so the server's contract table stays the one
    /// definition of a goal. Empty until loaded; the renderer then falls back to
    /// alphabetical, which is degraded (it puts `objections` above `next_step`)
    /// but never wrong.
    @Published var efficiencyFieldOrder: [String: [String]] = [:]

    /// Load the contract catalog once per launch. Silent on failure: this only
    /// improves field ORDER, and a follow-up that renders alphabetically is worth
    /// more than an error banner about one.
    /// Fetch the brief for the next meeting inside the lead window.
    ///
    /// Silent by design. A brief is a bonus on a panel that already works, so a
    /// failure shows nothing rather than an error — nobody is watching the screen
    /// ten minutes before a call, and an error line there would be pure noise.
    func refreshMeetingBrief() async {
        guard ledgerConfigured else { return }
        guard let meeting = BriefTarget.next(in: upcomingMeetings, now: Date(),
                                             briefed: briefsRequested) else { return }
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = await wheesprAccessToken() else { return }
        // Mark before awaiting: two refreshes overlapping must not both spend.
        briefsRequested.insert(meeting.id)
        do {
            // Prior-meeting record rides the existing sources contract (F8):
            // the brief opens with what THIS Mac already knows was decided and
            // promised the last time this meeting's topic came up.
            // Repeated promises lead: a commitment this thread has already made
            // twice is the one line that changes what happens in the next hour.
            let recallSources = BriefRecallSources.repeatedPromises(for: meeting, store: sessionStore)
                + BriefRecallSources.build(for: meeting, store: sessionStore)
                + BriefRecallSources.commitments(for: meeting, store: sessionStore)
            let response = try await BriefService.brief(for: meeting, sources: recallSources,
                                                        base: base, token: token)
            guard response.brief.hasContent else { return }
            meetingBriefs[meeting.id] = response.brief
        } catch {
            // Let it be retried on the next sync — a transient failure should not
            // cost the user the brief for the whole meeting.
            briefsRequested.remove(meeting.id)
            Log.general.error("brief skipped — \(error.localizedDescription)")
        }
    }

    func loadEfficiencyContracts() async {
        guard efficiencyFieldOrder.isEmpty, ledgerConfigured else { return }
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = await wheesprAccessToken() else { return }
        guard let contracts = try? await EfficiencyEngineService.contracts(base: base, token: token) else { return }
        efficiencyFieldOrder = Dictionary(
            uniqueKeysWithValues: contracts.map { ($0.goalType, $0.fields) })
    }

    /// - Parameter quiet: suppress the sign-in nudge (used by the automatic
    ///   on-appear load; the explicit refresh button stays loud).
    func refreshLedger(quiet: Bool = false) async {
        guard ledgerConfigured, !ledgerLoading else { return }
        ledgerLoading = true
        defer { ledgerLoading = false }
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = await wheesprAccessToken() else {
            if !quiet { lastError = "Войдите, чтобы увидеть журнал решений." }
            return
        }
        do {
            ledgerDecisions = try await DecisionLogService.recentDecisions(base: base, token: token)
            lastError = nil
        } catch {
            lastError = "Не удалось загрузить журнал: \(error.localizedDescription)"
        }
    }

    /// Digest-aware transcript for the string-based AI paths (fact check, log
    /// decision, brainstormer): within budget → the raw transcript; beyond it,
    /// with a digest available → digest + verbatim tail, sized to `cap` so the
    /// services' own suffix-clipping keeps the digest instead of eating it.
    func promptTranscript(cap: Int) -> String {
        let full = transcriptText
        // Full context replaces the digest entirely: the point of the mode is
        // that the model reads what was actually said, and a digest is the
        // summary this exists to avoid substituting for the transcript.
        if fullContextRequested, fullContextQuote.active {
            return String(full.suffix(fullContextQuote.limitChars))
        }
        let digest = callDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digest.isEmpty, full.count > cap else { return full }
        let head = "Call so far (rolling digest of earlier discussion):\n\(digest)\n\nRecent transcript (verbatim):\n"
        var tail = String(full.suffix(max(2_000, cap - head.count)))
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return head + tail
    }

    /// Free-text context for `BundledSkillRouter` relevance ranking: call goal,
    /// a capped transcript slice, and an optional user/prompt string.
    private func bundledSkillQuery(extra: String? = nil) -> String {
        var parts: [String] = []
        let goal = effectiveCallGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { parts.append(goal) }
        let slice = promptTranscript(cap: 2_500)
        if !slice.isEmpty { parts.append(slice) }
        if let extra {
            let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: "\n")
    }

    private enum BlindSpotWakeReason: Equatable {
        case cadence
        case goalRefresh
        case settingsChanged
        case cancelled
    }

    private struct BlindSpotRunIdentity: Equatable {
        let generation: Int
        let sessionID: UUID
    }

    private func blindSpotRunIsCurrent(_ identity: BlindSpotRunIdentity) -> Bool {
        blindSpotGeneration == identity.generation
            && currentSessionID == identity.sessionID
            && isRecording
            && blindSpotsEnabled
            && Config.brainstormEnabled
            && !suggestionsSnoozedThisCall
            && copilotQuotaMessage == nil
    }

    private func terminalizeActiveBlindSpotAttemptBeforeInvalidation(
        identity: BlindSpotRunIdentity
    ) {
        guard blindSpotActiveAttemptGeneration == identity.generation,
              blindSpotActiveAttemptSessionID == identity.sessionID,
              blindSpotLastOutcome == nil,
              let attemptID = blindSpotLastAttemptID else { return }
        let completedAt = Date().timeIntervalSince1970
        blindSpotLastCompletedAt = completedAt
        blindSpotLastResultCount = nil
        blindSpotLastOutcome = "cancelled"
        blindSpotActiveAttemptGeneration = nil
        blindSpotActiveAttemptSessionID = nil
        let latencyMS = max(
            0,
            Int((completedAt - (blindSpotLastStartedAt ?? completedAt)) * 1_000))
        Log.general.notice(
            "blind-spot cancelled id=\(attemptID, privacy: .public) latency_ms=\(latencyMS, privacy: .public)")
    }

    private func invalidateBlindSpotWork() {
        let identity = BlindSpotRunIdentity(
            generation: blindSpotGeneration, sessionID: currentSessionID)
        terminalizeActiveBlindSpotAttemptBeforeInvalidation(identity: identity)
        brainstormTask?.cancel()
        brainstormTask = nil
        blindSpotRefreshDebounce?.cancel()
        blindSpotRefreshDebounce = nil
        blindSpotRefreshRequested = false
        blindSpotScheduleRefreshRequested = false
        blindSpotGeneration &+= 1
    }

    private func beginBlindSpotDevTrace(
        identity: BlindSpotRunIdentity,
        goal: String,
        transcript: String,
        priorTitles: [String],
        guidance: String?,
        localContext: String?,
        probe: String,
        theme: String
    ) {
        guard syntheticBlindSpotTraceGoal == goal else { return }
        lastSyntheticBlindSpotTrace = BlindSpotDevTrace(
            generation: identity.generation,
            sessionID: identity.sessionID.uuidString,
            preparedAt: Date().timeIntervalSince1970,
            goal: goal,
            transcript: transcript,
            priorTitles: priorTitles,
            guidance: guidance,
            localContext: localContext,
            context: localContext,
            probe: probe,
            theme: theme,
            grounded: false,
            requestPayload: nil,
            tokenLookupStartedAt: nil,
            tokenLookupCompletedAt: nil,
            connectorStartedAt: nil,
            connectorCompletedAt: nil,
            connectorWorkflows: [],
            groundedCycleConsumedAt: nil,
            connectorPackStartedAt: nil,
            connectorPackCompletedAt: nil,
            providerStartedAt: nil,
            providerCompletedAt: nil)
    }

    private func mutateBlindSpotDevTrace(
        identity: BlindSpotRunIdentity,
        _ mutation: (inout BlindSpotDevTrace) -> Void
    ) {
        guard var trace = lastSyntheticBlindSpotTrace,
              trace.generation == identity.generation,
              trace.sessionID == identity.sessionID.uuidString else { return }
        mutation(&trace)
        lastSyntheticBlindSpotTrace = trace
    }

    private func blindSpotRequestPayload(_ request: BlindSpotProviderRequest) -> String? {
        var payload: [String: Any] = [
            "goal": request.goal,
            "transcript": request.transcript,
            "priorSuggestions": request.priorTitles,
            "grounded": request.grounded,
            "probe": request.probe,
            "theme": request.theme,
        ]
        if let guidance = request.guidance { payload["guidance"] = guidance }
        if let context = request.context { payload["context"] = context }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Set when the Co-pilot goal changes, so the blind-spot loop wakes early.
    private var blindSpotRefreshRequested = false
    /// Settings changes recalculate the budget-neutral cadence without forcing
    /// a charged scan or cancelling a provider request already in flight.
    private var blindSpotScheduleRefreshRequested = false

    /// Sleep until the next blind-spot cycle, returning early when the goal has
    /// been edited. Polled in short slices rather than one long sleep so a
    /// cancelled task still stops promptly.
    private func waitForNextBlindSpotCycle(seconds: UInt64) async -> BlindSpotWakeReason {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        while !Task.isCancelled {
            if blindSpotRefreshRequested {
                blindSpotRefreshRequested = false
                return .goalRefresh
            }
            if blindSpotScheduleRefreshRequested {
                blindSpotScheduleRefreshRequested = false
                return .settingsChanged
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { return .cadence }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .cancelled
    }

    /// The funded cadence can already be elapsed while the transcript is still
    /// too short, unchanged, out of quota, or the shared queue is full. Every
    /// such branch must suspend before reevaluating; otherwise this MainActor
    /// task spins at 100% CPU and starves Settings, state dumps, and the Stop
    /// Recording command.
    private func pauseBeforeBlindSpotReevaluation() async {
        await BackgroundSpendPolicy.pauseBeforeBlindSpotReevaluation()
    }

    /// The Co-pilot goal drives every blind spot, so a change to it has to
    /// reach the running loop. Debounced: typing a sentence is one refresh, not
    /// one per keystroke.
    func requestBlindSpotRefresh() {
        blindSpotRefreshDebounce?.cancel()
        blindSpotRefreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.blindSpotRefreshRequested = true
        }
    }

    private func startBrainstorming() {
        // A same-value Settings write is idempotent and leaves the current
        // provider request alone. Genuine restarts always get a fresh identity.
        guard brainstormTask == nil else { return }
        guard !suggestionsSnoozedThisCall else { return }   // per-call quiet mode
        guard blindSpotsEnabled, Config.brainstormEnabled, isRecording else { return }
        blindSpotGeneration &+= 1
        let identity = BlindSpotRunIdentity(
            generation: blindSpotGeneration, sessionID: currentSessionID)
        brainstormTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.blindSpotRunIsCurrent(identity) else { break }
                let tier = self.currentTier
                let paid = tier.rank >= Tier.pro.rank
                let fundedBaseCadence = CopilotCadence.blindSpotSeconds(
                    for: tier,
                    agendaEnabled: self.agendaCheckingEnabled,
                    factCheckEnabled: self.liveFactCheckingEnabled,
                    rhetoricEnabled: self.rhetoricWatchEnabled,
                    facilitationEnabled: self.facilitationWatchEnabled)
                // Paid cadence backs off over consecutive empty scans and snaps
                // back the moment one lands. Blind spots are the most expensive
                // loop; when optional watches are off their funded hourly share
                // is reassigned here, while the server-side judge still lets a
                // quiet stretch back off instead of paying to show noise.
                let cadence = paid
                    ? BackgroundSpendPolicy.blindSpotInterval(
                        consecutiveEmptyScans:
                            self.backgroundSpendState.consecutiveEmptyBlindSpotScans,
                        base: fundedBaseCadence,
                        cap: BackgroundSpendPolicy.blindSpotBackoffCap(for: tier))
                    : fundedBaseCadence
                // Cadence is start-to-start. Provider latency used to be added
                // after every sleep, turning a 90-second policy into ~110 seconds
                // in the failed live call. Persisting the last start also means
                // Settings OFF→ON cannot manufacture an extra paid wake.
                let now = ProcessInfo.processInfo.systemUptime
                let waitSeconds = BackgroundSpendPolicy.blindSpotWaitSeconds(
                    cadence: cadence,
                    lastAttemptUptime: self.backgroundSpendState.lastBlindSpotAttemptUptime,
                    nowUptime: now)
                let wake = await self.waitForNextBlindSpotCycle(seconds: waitSeconds)
                if wake == .cancelled { break }
                if wake == .settingsChanged { continue }
                guard self.blindSpotRunIsCurrent(identity) else { break }
                // Counted HERE, before the decline gates, because the question
                // this answers is "did the scheduler wake and evaluate?" — not
                // "did it decide to spend?". Sitting below the gates it counted
                // only the wakes that got as far as a spend decision, so a
                // correctly DEFERRED wake was indistinguishable from a loop
                // that had died: both reported zero. It also counted
                // inconsistently, since the queue-full decline further down
                // incremented while the streaming-answer decline above did not.
                // Spend is observable separately through charactersAtLastRun
                // and the provider's own request count.
                self.blindSpotCycleEvaluations += 1
                let goal = self.effectiveCallGoal
                guard !goal.isEmpty,
                      CopilotTranscriptEligibility.canGenerateSuggestions(self.transcript) else {
                    await self.pauseBeforeBlindSpotReevaluation()
                    continue
                }
                guard self.canRunAutomaticCopilot else {
                    await self.pauseBeforeBlindSpotReevaluation()
                    continue
                }
                // The signature used to be the transcript length alone, so
                // changing the goal produced an IDENTICAL signature and the run
                // was coalesced away — the Co-pilot field looked inert until
                // someone spoke. The goal is part of the request, so it belongs
                // in the key that decides whether this is the same request.
                // Enough NEW speech to be worth a scan. The signature below
                // coalesces identical input, but `transcript.count` let a single
                // new line buy a full-price call — the most expensive loop in the
                // app doing it 40 times an hour.
                let transcriptCharacterCount = self.transcriptText.count
                let transcriptSnapshot = String(
                    self.promptTranscript(cap: 8_000).suffix(8_000))
                let enoughNewMaterial = BackgroundSpendPolicy.shouldRunBlindSpot(
                    totalCharacters: transcriptCharacterCount,
                    charactersAtLastRun: self.backgroundSpendState.charactersAtLastRun["brainstorm"],
                    tier: self.currentTier,
                    goalChanged: wake == .goalRefresh)
                // A goal edit changes the request even when nobody spoke during
                // the edit. The old guard consumed the wake and then rejected it
                // for having no new transcript, making the field look inert.
                guard enoughNewMaterial else {
                    await self.pauseBeforeBlindSpotReevaluation()
                    continue
                }

                var signatureHasher = Hasher()
                signatureHasher.combine(transcriptSnapshot)
                signatureHasher.combine(goal)
                let queueKey = "brainstorm:\(identity.sessionID.uuidString):\(identity.generation)"
                guard await self.bgQueue.reserve(
                    key: queueKey, signature: signatureHasher.finalize()) else {
                    await self.pauseBeforeBlindSpotReevaluation()
                    continue
                }
                guard self.blindSpotRunIsCurrent(identity) else {
                    await self.bgQueue.finish(key: queueKey)
                    break
                }
                // Commit the material baseline only after the queue accepted
                // this exact immutable snapshot. A backpressure rejection must
                // leave it untouched so the same speech is retried next wake.
                self.backgroundSpendState.charactersAtLastRun["brainstorm"] =
                    transcriptCharacterCount
                self.backgroundSpendState.lastBlindSpotAttemptUptime =
                    ProcessInfo.processInfo.systemUptime

                // Free: brainstorm lens only. Pro+: rotate and fan out across
                // several workflow connector graphs in one wake.
                let probeIDs: [String]
                let probeID: String
                if self.currentTier.rank >= Tier.pro.rank {
                    self.backgroundSpendState.paidProbeTick += 1
                    probeIDs = BlindSpotProbeRotation.probeIDs(
                        at: self.backgroundSpendState.paidProbeTick,
                        count: BlindSpotProbeRotation.workflowCount(for: self.currentTier))
                    probeID = probeIDs[0]
                } else {
                    probeIDs = ["brainstorm"]
                    probeID = "brainstorm"
                }

                let skillQuery = self.bundledSkillQuery(
                    extra: "\(self.effectiveRecordingContextLabel)\n\(goal)\n\(probeIDs.joined(separator: ","))")
                let skillGuidance: String? = {
                    if let provider = self.blindSpotSkillGuidanceProvider {
                        return provider(skillQuery, probeIDs)
                    }
                    if self.currentTier.rank >= Tier.pro.rank {
                        var parts: [String] = []
                        for id in probeIDs {
                            let top = BundledSkillRouter.ranked(for: id, query: skillQuery)
                                .prefix(1)
                                .compactMap { BundledSkillRouter.format($0.skill) }
                                .filter { !$0.isEmpty }
                            parts.append(contentsOf: top)
                        }
                        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
                    }
                    return BundledSkillRouter.guidance(for: "brainstorm", query: skillQuery)
                }()

                var brainstormLayers = [self.effectiveRecordingContextGuidance,
                                        self.activeCallTheme.guidance,
                                        RoleSkillMatrix.guidance(roleID: self.userRoleID, promptID: probeID),
                                        skillGuidance]
                    .compactMap { $0 }
                if self.currentTier.rank >= Tier.pro.rank {
                    brainstormLayers.insert(BlindSpotProbeRotation.lensBriefs(for: probeIDs), at: 0)
                }

                let guidance = brainstormLayers.isEmpty
                    ? nil
                    : String(brainstormLayers.joined(separator: "\n\n").prefix(8_000))
                let priorTitles = Array((self.suggestions.map { $0.title }
                    + self.dismissedSuggestionTitles.sorted()).suffix(40))
                let theme = self.activeCallTheme.rawValue
                var contextBlob = self.blindSpotLocalContext(
                    query: goal + "\n" + String(transcriptSnapshot.suffix(3_000)))
                self.beginBlindSpotDevTrace(
                    identity: identity,
                    goal: goal,
                    transcript: transcriptSnapshot,
                    priorTitles: priorTitles,
                    guidance: guidance,
                    localContext: contextBlob.isEmpty ? nil : contextBlob,
                    probe: probeID,
                    theme: theme)
                self.mutateBlindSpotDevTrace(identity: identity) {
                    $0.tokenLookupStartedAt = Date().timeIntervalSince1970
                }
                let token: String?
                if let tokenProvider = self.blindSpotAccessTokenProvider {
                    token = await tokenProvider()
                } else {
                    token = await self.wheesprAccessToken()
                }
                self.mutateBlindSpotDevTrace(identity: identity) {
                    $0.tokenLookupCompletedAt = Date().timeIntervalSince1970
                }
                guard self.blindSpotRunIsCurrent(identity) else {
                    await self.bgQueue.finish(key: queueKey)
                    break
                }

                // Item 10, design #2. Consume the connector query the LAST scan
                // asked for — once. If this scan runs a grounded cycle it spends it
                // on that query; if not, the query is stale and dropped, never
                // carried across scans. `canProbe` tells THIS scan it may emit a new
                // query, set only when a cycle to run it could exist (connectors on,
                // budget left) so the server never asks for one the app cannot use.
                let pendingProbeQuery = self.blindSpotPendingProbeQuery
                self.blindSpotPendingProbeQuery = nil
                let canProbe = self.useConnectedAppsInPrompts && self.groundedCyclesRemaining > 0

                var grounded = false
                // Free and paid both probe connected apps when toggled on and
                // grounded-cycle budget remains. Pro+ hits several workflows'
                // apps per tick; Free stays on the brainstorm graph.
                if self.useConnectedAppsInPrompts,
                   self.groundedCyclesRemaining > 0 {
                    if let blob = await self.blindSpotGroundedContext(
                        goal: goal,
                        transcript: transcriptSnapshot,
                        probeIDs: probeIDs,
                        identity: identity,
                        explicitQuery: pendingProbeQuery
                    ) {
                        contextBlob = [contextBlob, blob]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n\n")
                        grounded = true
                    }
                }
                guard self.blindSpotRunIsCurrent(identity) else {
                    await self.bgQueue.finish(key: queueKey)
                    break
                }
                contextBlob = String(contextBlob.prefix(8_000))
                let request = BlindSpotProviderRequest(
                    goal: goal,
                    transcript: transcriptSnapshot,
                    priorTitles: priorTitles,
                    accessToken: token,
                    guidance: guidance,
                    context: contextBlob.isEmpty ? nil : contextBlob,
                    probe: probeID,
                    theme: theme,
                    grounded: grounded,
                    canProbe: canProbe)
                self.mutateBlindSpotDevTrace(identity: identity) {
                    $0.context = request.context
                    $0.grounded = request.grounded
                    $0.requestPayload = self.blindSpotRequestPayload(request)
                }

                let attemptID = UUID().uuidString
                let startedAt = Date().timeIntervalSince1970
                self.blindSpotAttempts += 1
                self.blindSpotLastAttemptID = attemptID
                self.blindSpotLastProbeIDs = probeIDs
                self.blindSpotLastStartedAt = startedAt
                self.blindSpotLastCompletedAt = nil
                self.blindSpotLastResultCount = nil
                self.blindSpotLastOutcome = nil
                self.blindSpotLastGrounded = grounded
                self.blindSpotLastBackendCorrelationID = nil
                self.blindSpotLastProvider = nil
                self.blindSpotLastModel = nil
                self.blindSpotLastProviderLatencyMs = nil
                self.blindSpotLastChargedCredits = nil
                self.blindSpotLastCacheHit = nil
                self.blindSpotLastProviderAttemptCount = nil
                self.blindSpotLastProviderAttempts.removeAll(keepingCapacity: true)
                self.blindSpotActiveAttemptGeneration = identity.generation
                self.blindSpotActiveAttemptSessionID = identity.sessionID
                self.devCallDiagnostics.record(event: "blind_spot_request", fields: [
                    "attemptID": attemptID,
                    "requestBody": self.blindSpotRequestPayload(request) ?? "{}",
                    "probeIDs": probeIDs,
                    "accessTokenPresent": token?.isEmpty == false,
                    "startedAt": startedAt,
                ])
                // Production logging is deliberately metadata-only. The
                // authorized dev hook snapshots the full synthetic prompt,
                // transcript fixture, workflow, and response in its owner-only
                // artifact directory.
                Log.general.notice("blind-spot attempt id=\(attemptID, privacy: .public) probes=\(probeIDs.joined(separator: ","), privacy: .public) grounded=\(grounded, privacy: .public)")
                do {
                    guard self.blindSpotRunIsCurrent(identity) else {
                        await self.bgQueue.finish(key: queueKey)
                        break
                    }
                    self.mutateBlindSpotDevTrace(identity: identity) {
                        $0.providerStartedAt = Date().timeIntervalSince1970
                    }
                    let outcome = try await self.blindSpotSuggestionProvider(request)
                    self.mutateBlindSpotDevTrace(identity: identity) {
                        $0.providerCompletedAt = Date().timeIntervalSince1970
                    }
                    // Providers and URLSession delegates are allowed to ignore
                    // cooperative cancellation. Nothing from an obsolete call
                    // reaches activity, cards, quota state, or production logs.
                    guard self.blindSpotRunIsCurrent(identity) else {
                        await self.bgQueue.finish(key: queueKey)
                        break
                    }
                    self.computeUsageRevision &+= 1
                    let fresh = outcome.suggestions
                    if let execution = outcome.execution {
                        self.recordBlindSpotExecution(execution)
                    }
                    // Item 10, design #2: remember what this scan asked to look up,
                    // for the next grounded cycle to run. Overwrites, never
                    // accumulates — only the freshest question matters on a live call.
                    self.blindSpotPendingProbeQuery = outcome.probeQuery
                    let completedAt = Date().timeIntervalSince1970
                    self.blindSpotLastCompletedAt = completedAt
                    self.blindSpotLastResultCount = fresh.count
                    self.blindSpotLastOutcome = fresh.isEmpty ? "empty" : "succeeded"
                    self.blindSpotSuccesses += 1
                    self.blindSpotLastSuccessAt = completedAt
                    self.blindSpotFailureMessage = nil
                    self.blindSpotActiveAttemptGeneration = nil
                    self.blindSpotActiveAttemptSessionID = nil
                    let latencyMS = max(0, Int((completedAt - startedAt) * 1_000))
                    self.devCallDiagnostics.record(event: "blind_spot_terminal", fields: [
                        "attemptID": attemptID,
                        "status": fresh.isEmpty ? "empty" : "succeeded",
                        "response": fresh.map { suggestion in
                            [
                                "title": suggestion.title,
                                "detail": suggestion.detail,
                                "kind": suggestion.kind.rawValue,
                                "evidence": suggestion.evidence ?? "",
                            ]
                        },
                        "provider": self.blindSpotLastProvider ?? "unknown",
                        "model": self.blindSpotLastModel ?? "unknown",
                        "providerLatencyMs": self.blindSpotLastProviderLatencyMs ?? -1,
                        "totalLatencyMs": latencyMS,
                        "chargedCredits": self.blindSpotLastChargedCredits ?? -1,
                        "cacheHit": self.blindSpotLastCacheHit ?? false,
                        "providerAttemptCount": self.blindSpotLastProviderAttemptCount ?? 0,
                        "backendCorrelationID": self.blindSpotLastBackendCorrelationID ?? "",
                    ])
                    Log.general.notice("blind-spot complete id=\(attemptID, privacy: .public) results=\(fresh.count, privacy: .public) latency_ms=\(latencyMS, privacy: .public) provider=\(self.blindSpotLastProvider ?? "unknown", privacy: .public) model=\(self.blindSpotLastModel ?? "unknown", privacy: .public) charged=\(self.blindSpotLastChargedCredits ?? -1, privacy: .public)")
                    // An empty result is what drives the backoff; anything kept
                    // resets it, so the cadence recovers as soon as the
                    // conversation gets interesting again.
                    if fresh.isEmpty {
                        self.blindSpotEmptyResults += 1
                        self.backgroundSpendState.consecutiveEmptyBlindSpotScans += 1
                    } else {
                        self.backgroundSpendState.consecutiveEmptyBlindSpotScans = 0
                        self.mergeSuggestions(fresh)
                    }
                } catch {
                    self.mutateBlindSpotDevTrace(identity: identity) {
                        $0.providerCompletedAt = Date().timeIntervalSince1970
                    }
                    guard self.blindSpotRunIsCurrent(identity) else {
                        await self.bgQueue.finish(key: queueKey)
                        break
                    }
                    self.computeUsageRevision &+= 1
                    let quotaMessage = CreditExhaustion.quotaMessage(from: error)
                    self.noteQuotaExhaustion(error)
                    if let execution = BrainstormService.executionTrace(from: error) {
                        self.recordBlindSpotExecution(execution)
                    }
                    let completedAt = Date().timeIntervalSince1970
                    self.blindSpotLastCompletedAt = completedAt
                    self.blindSpotLastResultCount = nil
                    self.blindSpotActiveAttemptGeneration = nil
                    self.blindSpotActiveAttemptSessionID = nil
                    if Task.isCancelled {
                        self.blindSpotLastOutcome = "cancelled"
                        let latencyMS = max(0, Int((completedAt - startedAt) * 1_000))
                        self.devCallDiagnostics.record(event: "blind_spot_terminal", fields: [
                            "attemptID": attemptID,
                            "status": "cancelled",
                            "totalLatencyMs": latencyMS,
                        ])
                        Log.general.notice("blind-spot cancelled id=\(attemptID, privacy: .public) latency_ms=\(latencyMS, privacy: .public)")
                    } else {
                        self.blindSpotLastOutcome = "failed"
                        self.blindSpotFailures += 1
                        self.blindSpotLastFailureAt = completedAt
                        self.blindSpotFailureMessage = quotaMessage
                            ?? "Blind Spot couldn't reach an AI provider. Retrying automatically."
                        // Do not log the upstream body: provider auth/funding
                        // responses can contain account data or a key suffix.
                        let latencyMS = max(0, Int((completedAt - startedAt) * 1_000))
                        self.devCallDiagnostics.record(event: "blind_spot_terminal", fields: [
                            "attemptID": attemptID,
                            "status": quotaMessage == nil ? "failed" : "quota_latched",
                            "httpStatus": Self.diagnosticHTTPStatus(error) ?? 0,
                            "provider": self.blindSpotLastProvider ?? "unknown",
                            "model": self.blindSpotLastModel ?? "unknown",
                            "providerLatencyMs": self.blindSpotLastProviderLatencyMs ?? -1,
                            "totalLatencyMs": latencyMS,
                            "chargedCredits": self.blindSpotLastChargedCredits ?? -1,
                            "providerAttemptCount": self.blindSpotLastProviderAttemptCount ?? 0,
                            "providerAttempts": self.blindSpotLastProviderAttempts.map {
                                ["provider": $0.provider, "model": $0.model, "reason": $0.reason]
                            },
                            "backendCorrelationID": self.blindSpotLastBackendCorrelationID ?? "",
                        ])
                        if quotaMessage != nil {
                            Log.general.error("blind-spot quota-latched id=\(attemptID, privacy: .public) latency_ms=\(latencyMS, privacy: .public) provider=\(self.blindSpotLastProvider ?? "none", privacy: .public) model=\(self.blindSpotLastModel ?? "unknown", privacy: .public) attempts=\(self.blindSpotLastProviderAttemptCount ?? 0, privacy: .public) charged=\(self.blindSpotLastChargedCredits ?? -1, privacy: .public)")
                        } else {
                            Log.general.error("blind-spot failed id=\(attemptID, privacy: .public) latency_ms=\(latencyMS, privacy: .public) provider=\(self.blindSpotLastProvider ?? "none", privacy: .public) model=\(self.blindSpotLastModel ?? "unknown", privacy: .public) attempts=\(self.blindSpotLastProviderAttemptCount ?? 0, privacy: .public) charged=\(self.blindSpotLastChargedCredits ?? -1, privacy: .public); retry scheduled")
                        }
                    }
                }
                await self.bgQueue.finish(key: queueKey)
            }
            if let self,
               self.blindSpotGeneration == identity.generation,
               self.currentSessionID == identity.sessionID {
                self.brainstormTask = nil
            }
        }
    }

    private static func diagnosticHTTPStatus(_ error: Error) -> Int? {
        if case LLMError.http(_, let status, _) = error { return status }
        return nil
    }

    /// Docs / notes already on the call — no connector spend.
    private func blindSpotLocalContext(query: String, cap: Int = 6_000) -> String {
        var parts: [String] = []
        let notes = contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("Notes:\n\(notes)") }
        for file in contextFiles.prefix(8) {
            let body = file.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            parts.append("\(file.name):\n\(String(body.prefix(1_500)))")
        }
        let remaining = max(0, cap - parts.joined(separator: "\n\n").count)
        if remaining > 0 {
            let folders = ContextFolderRetriever.render(
                folders: contextFolders, query: query,
                characterLimit: min(remaining, 3_000), fileLimit: 3)
            if !folders.isEmpty { parts.append(folders) }
        }
        let joined = parts.joined(separator: "\n\n")
        return String(joined.prefix(cap))
    }

    /// Ground against one or more prompt workflows' connector graphs, then
    /// deterministically pack hits into a bounded fact set. The generation is
    /// revalidated after every connector await and immediately before the
    /// grounded-cycle reservation, so OFF/Stop/new-call cannot spend or merge
    /// work prepared for an obsolete call.
    private func blindSpotGroundedContext(
        goal: String,
        transcript: String,
        probeIDs: [String],
        identity: BlindSpotRunIdentity,
        explicitQuery: String? = nil
    ) async -> String? {
        guard blindSpotRunIsCurrent(identity),
              tariffAllowance.canRunGroundedCycle(
                used: UsageTracker.groundedCyclesThisMonth) else { return nil }
        // Item 10, design #2: the previous scan may have named exactly what to look
        // up. When it did, that query drives this (already-budgeted) cycle instead
        // of the transcript heuristic — same call, sharper target.
        let query = explicitQuery.map { String($0.prefix(320)) }
            ?? GroundingContextPolicy.backgroundQuery(
                goal: goal, recentTranscript: transcript)
        var blocks: [String] = []
        let perWorkflow = probeIDs.count > 1
            ? 1 : CopilotCadence.maxGroundingSources
        mutateBlindSpotDevTrace(identity: identity) {
            $0.connectorStartedAt = Date().timeIntervalSince1970
        }

        for probeID in probeIDs {
            guard blindSpotRunIsCurrent(identity) else { return nil }
            let startedAt = Date().timeIntervalSince1970
            guard let workflow = PromptWorkflows.spec(for: probeID) else {
                let completedAt = Date().timeIntervalSince1970
                mutateBlindSpotDevTrace(identity: identity) {
                    $0.connectorWorkflows.append(BlindSpotConnectorDevTrace(
                        probeID: probeID,
                        startedAt: startedAt,
                        completedAt: completedAt,
                        latencyMs: max(0, Int((completedAt - startedAt) * 1_000)),
                        outcome: "workflow-missing",
                        resultCount: 0,
                        sourceIDs: []))
                }
                continue
            }
            let snippets = await groundingSnippets(
                for: workflow, promptID: probeID, query: query,
                runGeneration: -1, maxSources: perWorkflow,
                deriveQuery: false)
            let completedAt = Date().timeIntervalSince1970
            mutateBlindSpotDevTrace(identity: identity) {
                $0.connectorWorkflows.append(BlindSpotConnectorDevTrace(
                    probeID: probeID,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    latencyMs: max(0, Int((completedAt - startedAt) * 1_000)),
                    outcome: snippets.isEmpty ? "empty" : "succeeded",
                    resultCount: snippets.count,
                    sourceIDs: snippets.map {
                        $0.sourceID ?? $0.serverName
                    }))
            }
            guard blindSpotRunIsCurrent(identity) else { return nil }
            guard !snippets.isEmpty else { continue }
            let body = snippets.prefix(perWorkflow).map {
                "[workflow:\(probeID) · \($0.serverName)] \($0.text)"
            }.joined(separator: "\n\n")
            blocks.append(body)
        }
        mutateBlindSpotDevTrace(identity: identity) {
            $0.connectorCompletedAt = Date().timeIntervalSince1970
        }

        guard !blocks.isEmpty, blindSpotRunIsCurrent(identity) else { return nil }
        // No await occurs between the identity check and the reservation.
        guard UsageTracker.consumeGroundedCycle(for: currentTier) else { return nil }
        mutateBlindSpotDevTrace(identity: identity) {
            $0.groundedCycleConsumedAt = Date().timeIntervalSince1970
        }

        let raw = blocks.joined(separator: "\n\n")
        guard blindSpotRunIsCurrent(identity) else { return nil }
        mutateBlindSpotDevTrace(identity: identity) {
            $0.connectorPackStartedAt = Date().timeIntervalSince1970
        }
        let packed = await BlindSpotContextCompressor.compress(
            goal: goal,
            probe: probeIDs.first ?? "brainstorm",
            rawContext: raw,
            recentTranscript: transcript,
            llm: llm,
            model: LLMCatalog.fastAudit(for: Config.selectedModel))
        mutateBlindSpotDevTrace(identity: identity) {
            $0.connectorPackCompletedAt = Date().timeIntervalSince1970
        }
        guard blindSpotRunIsCurrent(identity),
              let packed, !packed.isEmpty else { return nil }
        return "Packed connector facts:\n\(packed)"
    }

    private func stopBrainstorming() {
        invalidateBlindSpotWork()
    }

    /// Poll the agenda + framing checker while recording — no user action needed.
    /// Best-effort (transient failures ignored), on a slower cadence than the
    /// brainstormer and offset so the two don't fire together. Findings flow into
    /// the same Co-pilot suggestions surface.
    private func startAgendaChecking() {
        agendaTask?.cancel()
        guard Config.agendaCheckerEnabled else { return }
        agendaTask = Task { [weak self] in
            // Stagger off the blind-spot cadence so the two don't fire together.
            try? await Task.sleep(nanoseconds: 20_000_000_000)  // 20s initial offset
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: CopilotCadence.agendaSeconds * 1_000_000_000)
                guard let self, self.isRecording else { break }
                guard self.effectiveRecordingContextKind == .meeting else { continue }
                guard CopilotTranscriptEligibility.canGenerateSuggestions(self.transcript) else { continue }
                guard self.canRunAutomaticCopilot else { continue }
                guard self.shouldSpendOnWatch("agenda") else { continue }
                    guard await self.bgQueue.reserve(key: "agenda", signature: self.transcriptText.count) else { continue }
                if let fresh = try? await CopilotBilling.labelled(.agenda, {
                    try await self.trackingComputeUsage({
                        try await AgendaCheckService.findings(
                            transcript: self.transcriptText,
                            priorTitles: self.suggestions.map { $0.title })
                    })
                }) {
                    self.mergeSuggestions(fresh)
                }
                await self.bgQueue.finish(key: "agenda")
            }
        }
    }

    private func stopAgendaChecking() {
        agendaTask?.cancel()
        agendaTask = nil
    }

    // MARK: - Background checks (fact-check + rhetoric)

    /// Background Fact Check: verify the transcript's claims against the attached
    /// context on a cadence, keeping `factClaims` fresh so the sheet is live.
    /// Cost story: opt-in, only when there is context to check against, on the
    /// metered/tiered backend factcheck path, and SKIPPED when no new transcript
    /// entries arrived since the last run (coalesced). Never clobbers a manual
    /// full sweep in progress.
    private func startFactCheckLoop() {
        factCheckLoopTask?.cancel()
        guard Config.factCheckDuringCallsEnabled else { return }
        factCheckLoopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)   // initial offset
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: CopilotCadence.factCheckSeconds * 1_000_000_000)
                guard let self, self.isRecording, !self.factChecking else { continue }
                let context = self.promptContext(
                    query: self.effectiveCallGoal + "\n" + String(self.transcriptText.suffix(4_000)))
                guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !self.transcript.isEmpty else { continue }
                guard self.canRunAutomaticCopilot else { continue }
                guard await self.bgQueue.reserve(key: "factcheck", signature: self.transcript.count) else { continue }
                let transcript = self.promptTranscript(cap: 8_000)
                let token = await self.wheesprAccessToken()
                let layers = [self.effectiveRecordingContextGuidance,
                              self.activeCallTheme.guidance,
                              RoleSkillMatrix.guidance(roleID: self.userRoleID, promptID: "factcheck"),
                              BundledSkillRouter.guidance(for: "factcheck",
                                                          query: self.bundledSkillQuery())]
                    .compactMap { $0 }
                // searchWeb is HARD false here, structurally: the background
                // loop has no way to reach the web lane — only the sheet's
                // explicit button does (never-silent rule).
                if let outcome = try? await self.trackingComputeUsage({
                    try await self.factCheckProvider(FactCheckProviderRequest(
                        transcript: transcript, context: context, accessToken: token,
                        extraGuidance: layers.isEmpty ? nil : layers.joined(separator: "\n\n"),
                        searchWeb: false), Config.selectedRequestModel)
                }),
                   !self.factChecking {
                    self.factClaims = outcome.claims
                }
                await self.bgQueue.finish(key: "factcheck")
            }
        }
    }

    private func stopFactCheckLoop() {
        factCheckLoopTask?.cancel()
        factCheckLoopTask = nil
    }

    /// Background Rhetoric watch: one compact flag on the fast model tier,
    /// refreshed only when the transcript grows (coalesced). Empty note = clear.
    private func startRhetoricLoop() {
        rhetoricLoopTask?.cancel()
        guard Config.rhetoricDuringCallsEnabled else { return }
        rhetoricLoopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)   // offset from the others
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: CopilotCadence.rhetoricSeconds * 1_000_000_000)
                guard let self, self.isRecording else { continue }
                guard self.transcript.count >= 4 else { continue }
                guard self.canRunAutomaticCopilot else { continue }
                guard self.shouldSpendOnWatch("rhetoric") else { continue }
                    guard await self.bgQueue.reserve(key: "rhetoric", signature: self.transcriptText.count) else { continue }
                let transcript = self.promptTranscript(cap: 6_000)
                let raw = try? await CopilotBilling.labelled(.rhetoric) {
                    try await self.trackingComputeUsage {
                        try await self.llm.streamChat(
                            system: RhetoricWatch.systemPrompt,
                            user: "Recent transcript:\n\(transcript)",
                            model: LLMCatalog.fastAudit(for: Config.selectedModel)) { _ in }
                    }
                }   // fast tier = cost, copilot pool = budget
                self.rhetoricNote = RhetoricWatch.parse(raw ?? "") ?? ""
                await self.bgQueue.finish(key: "rhetoric")
            }
        }
    }

    private func stopRhetoricLoop() {
        rhetoricLoopTask?.cancel()
        rhetoricLoopTask = nil
    }

    /// Background Facilitation watch: one steering note when the meeting drifts
    /// off its goal, loops, leaves a decision open, or sinks time on a tangent.
    /// Cost story: opt-in, fast model tier, coalesced (only fires when the
    /// transcript grew), and needs enough transcript to judge against. Empty
    /// note = on track.
    private func startFacilitationLoop() {
        facilitationLoopTask?.cancel()
        guard Config.facilitationDuringCallsEnabled else { return }
        facilitationLoopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000_000)   // offset from the others
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: CopilotCadence.facilitationSeconds * 1_000_000_000)
                guard let self, self.isRecording else { continue }
                guard self.effectiveRecordingContextKind == .meeting else { continue }
                guard self.transcript.count >= 4 else { continue }
                guard self.canRunAutomaticCopilot else { continue }
                guard self.shouldSpendOnWatch("facilitation") else { continue }
                    guard await self.bgQueue.reserve(key: "facilitation", signature: self.transcriptText.count) else { continue }
                let transcript = self.promptTranscript(cap: 6_000)
                let raw = try? await CopilotBilling.labelled(.facilitation) {
                    try await self.trackingComputeUsage {
                        try await self.llm.streamChat(
                            system: FacilitationWatch.systemPrompt,
                            user: FacilitationWatch.userPrompt(
                                goal: self.effectiveCallGoal,
                                transcript: transcript
                            ),
                            model: LLMCatalog.fastAudit(for: Config.selectedModel)) { _ in }
                    }
                }   // fast tier = cost, copilot pool = budget
                self.facilitationNote = FacilitationWatch.parse(raw ?? "") ?? ""
                await self.bgQueue.finish(key: "facilitation")
            }
        }
    }

    private func stopFacilitationLoop() {
        facilitationLoopTask?.cancel()
        facilitationLoopTask = nil
    }

    func mergeSuggestions(_ fresh: [Suggestion]) {
        let seen = Set(suggestions.map { $0.title.lowercased() })
            .union(dismissedSuggestionTitles)
        let added = fresh.filter { !seen.contains($0.title.lowercased()) }
        suggestions.append(contentsOf: added)
        if suggestions.count > 12 { suggestions.removeFirst(suggestions.count - 12) }
        // Item 17: a silent banner for the user who is looking at the call, not
        // the app. The decision is a pure function so its rules are tested
        // without a live call.
        if BlindSpotNotifier.shouldNotify(
            freshCount: added.count, isRecording: isRecording,
            appIsActive: NSApplication.shared.isActive,
            enabled: Config.blindSpotTextNotificationsEnabled) {
            BlindSpotNotifier.post(added, meetingTitle: meetingTitle)
        }
    }

    func dismissSuggestion(id: UUID) {
        if let dismissed = suggestions.first(where: { $0.id == id }) {
            dismissedSuggestionTitles.insert(dismissed.title.lowercased())
        }
        suggestions.removeAll { $0.id == id }
    }

    /// Push a suggestion into the assistant as a prompt.
    func askSuggestion(_ suggestion: Suggestion) {
        // The overlay is a NONACTIVATING panel by design (clicking it must not
        // steal focus from the call). But Ask routes the user INTO the main
        // window's assistant, so from here activation is the point: without
        // it the app draws a focused prompt field while the previously active
        // app stays key, and the user's typing lands in that app instead.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }

        var text = suggestion.detail.isEmpty ? suggestion.title : "\(suggestion.title) — \(suggestion.detail)"
        // A hunch's substance is its claim, not its headline. Sending title +
        // detail alone would ask the assistant about a label while dropping the
        // actual read and the sentence meant to settle it.
        if suggestion.isTestableHypothesis, let claim = suggestion.claim, let test = suggestion.cheapTest {
            text = "Pressure-test this read on the call: \(claim)\n\n"
                + "The proposed way to settle it: \(test)\n\n"
                + "Is the read supported by what has actually been said? If so, sharpen the question. "
                + "If not, say what would change your mind."
        }
        // Route through the workflow that matches the blind spot's KIND, so Ask
        // fans out to the connected apps that can actually answer it.
        //
        // This passed no promptID, and `run` resolves the connector graph from
        // exactly that (`promptID.flatMap { designedWorkflow(for: $0) }`) — so Ask
        // was the one path in the app that reached the model with no connector
        // research at all. A risk should query the trackers, a missing fact should
        // query the docs, and a hunch should go looking for evidence for or
        // against the claim.
        run(prompt: text, images: [], promptID: Self.workflowPromptID(for: suggestion.kind))
    }

    /// Blind-spot kind → the prompt whose connector workflow suits it.
    static func workflowPromptID(for kind: SuggestionKind) -> String {
        switch kind {
        case .question:    return "whattoask"
        case .risk:        return "risks"
        case .missingInfo: return "factcheck"
        case .advice:      return "advice"
        // A hunch is a claim to be checked against sources, which is the
        // fact-check graph — docs and trackers, not the questioning one.
        case .hypothesis:  return "factcheck"
        }
    }

    // MARK: - Focus panel

    /// Focus owns reminders and active alerts. Co-pilot owns recommendations,
    /// so the same recommendation never appears as two separate cards.
    var focusItems: [FocusItem] {
        FocusRanking.rank(meetings: upcomingMeetings,
                          alert: lastError,
                          now: Date(),
                          dismissedMeetingIDs: dismissedMeetingIDs)
    }

    // MARK: - Dismissing a calendar event

    /// Google event ids hidden from Focus.
    ///
    /// Dismissal is app-local by design: the calendar belongs to the user (and
    /// often to other attendees), so a row nobody wants to see is hidden here
    /// rather than deleted there. Persisted, because the calendar is re-polled
    /// constantly and a dismissal that lasted until the next refresh would be
    /// no dismissal at all.
    @Published private(set) var dismissedMeetingIDs: Set<String> = []

    /// The meetings currently hidden, so the UI can offer them back rather than
    /// making dismissal a one-way door.
    var dismissedMeetings: [UpcomingMeeting] {
        upcomingMeetings.filter { dismissedMeetingIDs.contains($0.id) }
    }

    func dismissMeeting(id: String) {
        guard !id.isEmpty else { return }
        dismissedMeetingIDs.insert(id)
        persistDismissedMeetings()
        evictCalendarSync(meetingID: id)
    }

    /// Hiding a meeting also takes back what it already wrote into the call.
    ///
    /// Dismissal used to hide a Focus row and nothing else, so a meeting the
    /// user had said "not this one" about still named the call, still sat in
    /// context as `Calendar · …`, and still set the attendee count. Hiding has
    /// to mean the same thing everywhere the meeting reached.
    private func evictCalendarSync(meetingID: String) {
        // A Focus tap kept an exact before-snapshot — restore that rather than
        // guessing, and do not re-enter dismissal (it is already recorded).
        let wasApplied = appliedMeetingContext?.meetingID == meetingID
        if wasApplied { undoMeetingContext(dismissing: false) }
        guard let synced = syncedCalendarEvent, synced.id == meetingID else { return }
        syncedCalendarEvent = nil
        calendarSyncNote = ""
        // The snapshot already put the title, goal, attendee count and context
        // file back to their pre-tap values — anything more would overwrite
        // what the user had before, not what the meeting added.
        if wasApplied { return }
        contextFiles.removeAll { $0.name == "Calendar · \(synced.title)" }
        // Only a title still equal to the event's own is taken back: a name the
        // user typed over it is theirs, not the calendar's.
        if meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(synced.title) == .orderedSame {
            meetingTitle = ""
        }
        if suggestedGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(synced.title) == .orderedSame {
            suggestedGoal = nil
        }
        callAttendeeCount = 0
    }

    func restoreMeeting(id: String) {
        dismissedMeetingIDs.remove(id)
        persistDismissedMeetings()
    }

    func restoreAllMeetings() {
        dismissedMeetingIDs.removeAll()
        persistDismissedMeetings()
    }

    private static let dismissedMeetingsKey = "focus.dismissedMeetings"

    private func persistDismissedMeetings() {
        // Only ids still present in the calendar are kept. Without this the set
        // grows forever with events that ended months ago.
        let live = Set(upcomingMeetings.map(\.id))
        let pruned = live.isEmpty ? dismissedMeetingIDs : dismissedMeetingIDs.intersection(live)
        UserDefaults.standard.set(Array(pruned).sorted(), forKey: Self.dismissedMeetingsKey)
    }

    func loadDismissedMeetings() {
        let stored = UserDefaults.standard.array(forKey: Self.dismissedMeetingsKey) as? [String] ?? []
        dismissedMeetingIDs = Set(stored)
    }

    // MARK: - Undoing an applied meeting context

    /// What the workspace looked like before a Focus row was tapped.
    ///
    /// Tapping a meeting rewrites several things at once — the title, the goal,
    /// the attendee count, plus a new context file. A misclick therefore does
    /// not undo by deleting one file; this snapshot is what makes it reversible.
    struct AppliedMeetingContext: Equatable {
        let meetingID: String
        let contextFileName: String
        let previousTitle: String
        let previousGoal: String
        let previousSuggestedGoal: String?
        let previousAttendeeCount: Int
    }

    /// Set for the most recent Focus tap; cleared once undone or superseded.
    @Published private(set) var appliedMeetingContext: AppliedMeetingContext?

    /// Put the workspace back exactly as it was before the row was tapped, and
    /// hide the meeting — an accidental tap almost always means "not this one".
    func undoMeetingContext(dismissing: Bool = true) {
        guard let applied = appliedMeetingContext else { return }
        contextFiles.removeAll { $0.name == applied.contextFileName }
        meetingTitle = applied.previousTitle
        callGoal = applied.previousGoal
        suggestedGoal = applied.previousSuggestedGoal
        callAttendeeCount = applied.previousAttendeeCount
        appliedMeetingContext = nil
        if dismissing { dismissMeeting(id: applied.meetingID) }
    }

    func forgetAppliedMeetingContext() {
        appliedMeetingContext = nil
    }

    /// Test seam: record the snapshot without the Google round trip that
    /// `applyMeetingContext` needs. Nothing in the app calls this.
    func beginAppliedMeetingContextForTesting(meetingID: String, contextFileName: String) {
        appliedMeetingContext = AppliedMeetingContext(
            meetingID: meetingID,
            contextFileName: contextFileName,
            previousTitle: meetingTitle,
            previousGoal: callGoal,
            previousSuggestedGoal: suggestedGoal,
            previousAttendeeCount: callAttendeeCount)
    }

    /// Act on a Focus item: dismiss the alert, ask a suggestion, or (for a
    /// reminder) do nothing — it's informational.
    func act(on item: FocusItem) {
        switch item.kind {
        case .alert:
            lastError = nil
        case .reminder:
            // Picking a meeting loads ITS context, not whatever the calendar
            // thinks is happening now.
            if let meetingID = item.meetingID {
                Task { await applyMeetingContext(meetingID: meetingID, title: item.title) }
            }
        case .risk, .question, .missingInfo, .advice:
            if let id = item.suggestionID, let suggestion = suggestions.first(where: { $0.id == id }) {
                askSuggestion(suggestion)
            }
        }
    }

    /// Actively capturing audio (not a start/stop transition).
    var isRecording: Bool { status == .recording }
    /// A start/stop transition is in flight — controls should disable.
    var isBusy: Bool { status == .starting || status == .stopping }

    /// Consent sheet trigger: recording never starts before the one-time
    /// affirmation (M10.1 — meeting recorders get App Review scrutiny here).
    @Published var showRecordingConsent = false

    func acceptRecordingConsent() {
        Config.recordingConsentAccepted = true
        showRecordingConsent = false
        Task { await startRecording() }   // continue what the user asked for
    }

    func toggleRecording() {
        switch status {
        case .idle, .error:
            guard Config.recordingConsentAccepted else {
                showRecordingConsent = true
                return
            }
            Task { await startRecording() }
        case .recording:
            Task { await stopRecording() }
        case .paused:
            // The primary control still means "finish and write up". Resume is
            // its own action, so the button never has two meanings.
            Task { await stopRecording() }
        case .starting, .stopping:
            break
        }
    }

    /// Suspend capture and every background scan, keeping the session alive.
    ///
    /// Not a stop: the transcript, the goal and the saved session all survive,
    /// and resume continues the same recording rather than starting a new one.
    func pauseRecording() {
        guard status == .recording else { return }
        analytics(.featureUsed(.pauseResume))
        let now = Date()
        recordingElapsed.pause(at: now)
        // Close the transcription boundary before publishing `.paused`.
        // ScreenCaptureKit/AVAudioEngine taps remain installed, so status alone
        // cannot prevent their callbacks from sending to Deepgram or Local.
        systemChunker?.pause()
        micChunker?.pause()
        status = .paused
        localFinalPassContinuityValid = false
        sessionRecorder.pause()
        // Dense PCM removes the wall-clock gap. Keeping either pre- or
        // post-pause audio would shift later diarized/refined turns earlier and
        // replace the wrong live rows. Fail closed for every post-call audio
        // consumer until the recorder grows an explicit interval map.
        sessionRetainedAudioTimelineValid = false
        sessionRecorder.seal()
        sessionRecorder.discard()
        sessionRetainedAudioStart = nil
        sessionAudioStart = nil
        sessionAudioStartSample = 0
        localFinalPassOptedInForSession = false
        localDiarizationOptedInForSession = false
        localDiarizationContinuityValid = false
        // The meter does NOT stop by itself. It accumulates against wall time
        // from `activeSince`, so without this the pause would look right in the
        // UI while still billing co-pilot hours for an empty room — the exact
        // thing this feature exists to prevent.
        copilotActiveTimeMeter.transition(to: false, at: now)
        // Everything that suspends on "not recording" — capture taps, the blind
        // spot scheduler, the co-pilot hour meter — is already gated on
        // isRecording, which is false the moment the status changes.
        stopBrainstorming()
        devCallDiagnostics.record(event: "recording_paused", fields: [:])
    }

    /// Continue the suspended recording. The session id, transcript and goal
    /// are unchanged; only the clock and the capture resume.
    func resumeRecording() {
        guard status == .paused else { return }
        let now = Date()
        recordingElapsed.resume(at: now)
        // Флаг с прошлого звонка не должен встречать следующий.
        systemAudioLostDuringRecording = false
        microphoneLostDuringRecording = false
        // Publish the active state first, then open clean future audio
        // boundaries. No callback can be admitted while the UI still says the
        // meeting is paused.
        status = .recording
        sessionRecorder.resume()
        systemChunker?.resume()
        micChunker?.resume()
        // Back to whatever the co-pilot setting actually is, not
        // unconditionally on: a call paused with automation off must resume
        // with it still off.
        copilotActiveTimeMeter.transition(to: automaticCopilotEnabled, at: now)
        devCallDiagnostics.record(event: "recording_resumed", fields: [:])
    }

    /// Active recording time, paused spans excluded. What the clock shows and
    /// what the hour meter bills must be the same number.
    var activeRecordingSeconds: TimeInterval {
        recordingElapsed.activeSeconds(at: Date())
    }

    var isPaused: Bool { status == .paused }

    /// A session exists — recording or paused. Distinct from `isRecording`,
    /// which is specifically "capturing right now".
    var isSessionLive: Bool { status == .recording || status == .paused }

    func clearAll() {
        cancelFirefliesEnhance()
        invalidateLocalFinalPassTasks(discardRetainedAudio: true)
        supersedeActiveAI()
        aiResponse = ""
        aiResponsePrompt = ""
        submittedPromptPreview = nil
        aiResponseID = nil
        aiResponsePromptID = nil
        aiResponseStartedAt = nil
        aiResponseCompletedAt = nil
        aiResponseStatus = nil
        aiResponseModelID = nil
        aiResponseExportTitle = nil
        aiHistory = []
        aiExchangeEvidence = []
        workflowSteps = []
        stepSeq = 0
        followUpPrompts = []
        factClaims = []
        factCheckError = nil
        transcript.removeAll()
        provisional.removeAll()
        sessionRecorder.reset()
        sessionRetainedAudioStart = nil
        sessionAudioStart = nil
        sessionAudioStartSample = 0
        sessionRetainedAudioTimelineValid = true
        localFinalPassContinuityValid = false
        activeSessionPreparedLocalWhisperModel = nil
        // This is session provenance as well as the live timer origin. Clear it
        // only when the workspace becomes a genuinely fresh meeting; Stop keeps
        // it so the initial save and a late final-partial save remain valid.
        recordingStartedAt = nil
        recordingElapsed.stop()
        recordingElapsed.stop()
        recordingElapsed.stop()
        // Invalidate in-flight chunk transcriptions so a slow chunk finishing
        // after the clear can't resurrect a transcript line.
        chunkGeneration &+= 1
    }

    /// Begin a clean meeting. Each recording is its OWN History track: a new
    /// recording must never inherit the previous meeting's transcript (which
    /// used to save a bloated, duplicated session under a fresh id). The prior
    /// meeting is already persisted to History on its own stop.
    func resetForNewRecording() {
        // Invalidate before changing the session id or clearing counters. A
        // non-cooperative provider from the old call must never repopulate the
        // fresh workspace after this synchronous reset returns.
        stopBrainstorming()
        clearAll()                    // transcript, provisional, aiResponse, recorder, chunkGeneration
        // The previous call's Fireflies merge is still waiting on Fireflies. It
        // has nothing to merge into any more — this session is a new track.
        cancelFirefliesEnhance()
        currentSessionID = UUID()     // its own file, distinct from the last meeting
        meetingTitle = ""
        callGoal = ""
        // Never carry an automatic guess from the previous audio source into a
        // new recording. An explicit override is preserved so a user can set
        // "Tutorial" before pressing Record and keep it for a video series.
        detectedRecordingContext = .meeting
        hasDetectedRecordingContext = false
        // Snooze is per-call by design — a new call starts with suggestions on.
        suggestionsSnoozedThisCall = false
        // A new call may sit in a new billing period or on a fresh upgrade —
        // let the server re-decide instead of carrying yesterday's rejection.
        copilotQuotaMessage = nil
        // No longer looking at History: this is the live workspace again.
        isViewingRestoredSession = false
        suggestedMeetingTitle = nil
        contextFiles.removeAll { $0.name.hasPrefix("Research · ") }
        callDigest = ""
        suggestions.removeAll()
        dismissedSuggestionTitles.removeAll(keepingCapacity: true)
        blindSpotFailureMessage = nil
        blindSpotAttempts = 0
        blindSpotSuccesses = 0
        blindSpotEmptyResults = 0
        blindSpotFailures = 0
        blindSpotLastSuccessAt = nil
        blindSpotLastFailureAt = nil
        blindSpotLastAttemptID = nil
        blindSpotLastBackendCorrelationID = nil
        blindSpotLastProbeIDs.removeAll(keepingCapacity: true)
        blindSpotLastStartedAt = nil
        blindSpotLastCompletedAt = nil
        blindSpotLastResultCount = nil
        blindSpotLastOutcome = nil
        blindSpotLastGrounded = false
        blindSpotLastProvider = nil
        blindSpotLastModel = nil
        blindSpotLastProviderLatencyMs = nil
        blindSpotLastChargedCredits = nil
        blindSpotLastCacheHit = nil
        blindSpotLastProviderAttemptCount = nil
        blindSpotLastProviderAttempts.removeAll(keepingCapacity: true)
        blindSpotActiveAttemptGeneration = nil
        blindSpotActiveAttemptSessionID = nil
        syntheticBlindSpotTraceGoal = nil
        lastSyntheticBlindSpotTrace = nil
        blindSpotCycleEvaluations = 0
        factClaims.removeAll()
        rhetoricNote = ""
        facilitationNote = ""
        // Spend baselines are transcript-relative. Keeping the previous call's
        // larger character count made the new call's delta negative and could
        // suppress Blind Spot until it exceeded the old meeting's length.
        backgroundSpendState.reset()
        blindSpotRefreshDebounce?.cancel()
        blindSpotRefreshDebounce = nil
        blindSpotRefreshRequested = false
        blindSpotScheduleRefreshRequested = false
        // Belongs to the decision filed on the previous call.
        efficiencyFollowUp = nil
        // Clear the background cost gate so the new meeting's first cycles run
        // fresh and no in-flight slot leaks across meetings.
        Task { [bgQueue] in await bgQueue.reset() }
        followUpPrompts = []
        aiStage = nil
        recordingClock.reset()
        copilotActiveTimeMeter.reset()
        callAttendeeCount = 0
    }

    /// Calendar attendee count for the active meeting (0 = unknown) — the
    /// diarization speaker hint. Set when the agenda is fetched at recording
    /// start; reset per meeting.
    private var callAttendeeCount = 0

    func importContext(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        contextImporting = true
        defer { contextImporting = false }

        var errors: [String] = []
        for url in urls {
            do {
                let file = try await ContextImporter.importFile(at: url)
                contextFiles.append(file)
                // Attaching a document is the moment its vocabulary becomes
                // available, and the glossary is the largest measured accuracy
                // lever on domain-heavy calls. Proposes only; nothing is added
                // to the glossary without the user accepting it.
                refreshContextGlossarySuggestions()
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        lastError = errors.isEmpty ? nil : "Import issues — " + errors.joined(separator: "; ")
    }

    func removeContextFile(id: UUID) {
        contextFiles.removeAll { $0.id == id }
    }

    // MARK: - Context folders

    static let maxAttachedContextFolders = 4

    /// Attach a folder as standing context. Scans immediately so the user sees
    /// what actually got picked up — and what did not — instead of trusting that
    /// pointing at a directory did something.
    func attachContextFolder(url: URL) async {
        guard !contextImporting else {
            lastError = "Другой источник ещё индексируется. Дождитесь или отмените его."
            return
        }
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let replacesExisting = contextFolders.contains { $0.path == canonicalPath }
        guard replacesExisting || contextFolders.count < Self.maxAttachedContextFolders else {
            lastError = "Можно подключить не больше \(Self.maxAttachedContextFolders) папок. Уберите одну, чтобы добавить новую."
            return
        }
        contextImporting = true
        defer { contextImporting = false }
        do {
            let bookmark = try ContextFolderScanner.bookmark(for: url)
            let result = try await ContextFolderScanner.scan(bookmark: bookmark)
            try Task.checkCancellation()
            let folder = ContextFolder(
                name: url.lastPathComponent, path: canonicalPath, bookmark: bookmark,
                files: result.files, skipped: result.skipped)
            contextFolders.removeAll { $0.path == folder.path }
            contextFolders.append(folder)
            refreshContextGlossarySuggestions()
            contextFolders.sort {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
            persistContextFolders()
            lastError = nil
            reportFolderSkips(folder)
        } catch is CancellationError {
            // The progress chip disappearing is the cancellation feedback. Do
            // not turn an intentional Cancel into a red global error banner.
        } catch {
            // Do not surface the raw path (or an NSError that may contain it).
            lastError = "Не удалось подключить «\(url.lastPathComponent)». Проверьте, что папка читается, и попробуйте снова."
        }
    }

    func detachContextFolder(id: UUID) {
        contextFolders.removeAll { $0.id == id }
        persistContextFolders()
    }

    /// Re-read an attached folder. Scanning is on demand rather than watched:
    /// a file-system watcher would re-extract PDFs on every incidental write for
    /// a freshness nobody asked for mid-call.
    func rescanContextFolder(id: UUID) async {
        guard !contextImporting else {
            lastError = "Другой источник ещё индексируется. Дождитесь или отмените его."
            return
        }
        guard let folder = contextFolders.first(where: { $0.id == id }) else { return }
        // Capture immutable values before suspending. The user may detach this
        // folder while the scan is in flight; a stale array index in either the
        // success or error path must never crash the composer.
        let bookmark = folder.bookmark
        let displayName = folder.name
        contextImporting = true
        defer { contextImporting = false }
        do {
            let result = try await ContextFolderScanner.scan(bookmark: bookmark)
            guard let current = contextFolders.firstIndex(where: { $0.id == id }) else { return }
            contextFolders[current].files = result.files
            contextFolders[current].skipped = result.skipped
            contextFolders[current].scannedAt = Date()
            persistContextFolders()
            // A rescan can surface files the first scan missed or a budget
            // dropped, so their vocabulary is new too.
            refreshContextGlossarySuggestions()
            lastError = nil
            reportFolderSkips(contextFolders[current])
        } catch is CancellationError {
            // An explicit cancel or detach is not a user-facing error.
        } catch {
            // Scanner errors can carry the absolute path in NSError metadata;
            // the folder name is sufficient and safe for the UI.
            lastError = "Не удалось обновить «\(displayName)». Подключите заново, если доступ изменился."
        }
    }

    /// A budget that silently dropped files would read as a fully attached
    /// folder. Say it once, at attach and refresh time.
    private func reportFolderSkips(_ folder: ContextFolder) {
        guard !folder.skipped.isEmpty else { return }
        lastError = "«\(folder.name)»: подключено файлов — \(folder.files.count); "
            + "не вошло — \(folder.skipped.count) (не хватило места)."
    }

    private static let contextFoldersKey = "context.folders"

    private func persistContextFolders() {
        let payload = contextFolders.map { folder in
            ["name": folder.name, "path": folder.path, "bookmark": folder.bookmark] as [String: Any]
        }
        UserDefaults.standard.set(payload, forKey: Self.contextFoldersKey)
    }

    /// Re-resolve bookmarks at launch and rescan. A folder that has moved or had
    /// its grant revoked is dropped with a message rather than kept as an entry
    /// that silently contributes nothing.
    func restoreContextFolders() async {
        let stored = UserDefaults.standard.array(forKey: Self.contextFoldersKey) as? [[String: Any]] ?? []
        guard !stored.isEmpty else { return }
        var restored: [ContextFolder] = []
        var lost: [String] = []
        for entry in stored.prefix(Self.maxAttachedContextFolders) {
            guard let name = entry["name"] as? String,
                  let path = entry["path"] as? String,
                  let bookmark = entry["bookmark"] as? Data else { continue }
            do {
                let result = try await ContextFolderScanner.scan(bookmark: bookmark)
                restored.append(ContextFolder(name: name, path: path, bookmark: bookmark,
                                              files: result.files, skipped: result.skipped))
            } catch {
                lost.append(name)
            }
        }
        contextFolders = restored.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        persistContextFolders()
        if !lost.isEmpty {
            lastError = "Потерян доступ к \(lost.joined(separator: ", ")) — подключите заново, чтобы выдать его снова."
        }
    }

    // MARK: - Attachments

    private static let maxImageBytes = 20 * 1024 * 1024

    /// Pin images to the next message (vision). Reads off the main thread.
    func attachImages(_ urls: [URL]) async {
        var errors: [String] = []
        for url in urls {
            guard let data = await Self.readScopedAsync(url) else {
                errors.append("\(url.lastPathComponent): unreadable")
                continue
            }
            guard data.count <= Self.maxImageBytes else {
                errors.append("\(url.lastPathComponent): image too large (max 20 MB)")
                continue
            }
            pendingImages.append(Attachment(name: url.lastPathComponent, imageData: data))
        }
        if !errors.isEmpty { lastError = "С картинками не вышло — " + errors.joined(separator: "; ") }
    }

    func removeImage(id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    /// Decode each audio/video file's audio, transcribe it, and add the text as
    /// a context source. Sequential so errors accumulate into one message.
    func attachMedia(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        attaching = true
        defer { attaching = false }

        // Outside a live recording, honor the current Settings selection for
        // this import. A recording keeps its own snapshotted transcriber so an
        // attachment cannot shut down or reconfigure active caption inference.
        if status == .idle {
            await prepareTranscriberForRecording(
                engine: Config.transcriptionEngineValue,
                language: Config.transcriptionLanguage
            )
        }
        let mediaTranscriber = transcriber

        var errors: [String] = []
        for url in urls {
            do {
                let wav = try await MediaTranscoder.extractWAV(url: url)
                let text = try await mediaTranscriber.transcribe(wav: wav)
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else {
                    errors.append("\(url.lastPathComponent): no speech found")
                    continue
                }
                contextFiles.append(ImportedContextFile(name: url.lastPathComponent, text: clean))
                refreshContextGlossarySuggestions()
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        lastError = errors.isEmpty ? nil : "Media issues — " + errors.joined(separator: "; ")
    }

    private static func readScopedAsync(_ url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }.value
    }

    // MARK: - Wheespr account (email OTP / password / phone / social)

    /// Single source of truth for adopting a backend session — used by email
    /// OTP, password, phone, native Apple/Google, paywall, and device-redeem.
    func applySession(_ session: WheesprSession) {
        Config.wheesprSession = session
        wheesprConnectionMutatedSinceLaunch = true
        wheesprConnected = true
        // Breadcrumb for detecting a LATER silent sign-out, and the notice for
        // the previous one is now answered.
        if !session.email.isEmpty { Config.lastSignedInEmail = session.email }
        signedOutNotice = nil
        if !session.email.isEmpty {
            wheesprEmail = session.email

            // The corporate domain names the employer — the term most likely
            // to be spoken on every call this account records. Seeded through
            // the same gate as connected-app suggestions: bounded, deduped
            // against the existing glossary, never re-added after a
            // rejection. A freemail domain contributes nothing.
            let seeded = GlossaryAutoApply.termsToAdd(
                suggestions: EmailDomainGlossary.candidates(fromEmail: session.email)
                    .map { ConnectedGlossarySuggestion(term: $0,
                                                       reason: "Your sign-in domain",
                                                       sources: ["email-domain"]) },
                existing: Config.transcriptionGlossary,
                rejectedKeys: connectedGlossaryRejectedKeys)
            if !seeded.isEmpty {
                Config.transcriptionGlossary = GlossaryAutoApply.merge(
                    existing: Config.transcriptionGlossary, adding: seeded)
            }
        }
        pendingAuthEmail = nil
        lastError = nil
        // The credit bar refreshes on wheesprConnected CHANGING — which a
        // re-sign-in with the same account never does, so the bar kept
        // showing pre-sign-in numbers ("doesn't remember what I spent").
        // Bumping the revision forces a server fetch on every session apply;
        // the server's per-account ledger is the memory.
        computeUsageRevision &+= 1
        reconcileDisplayedTranscriptionEngineIfIdle()
        guard !AppState.isUnderTest else { return }
        Task { [weak self] in
            await PaywallAPI.refreshEntitlement()
            self?.refreshTier()
        }
    }

    /// Request a one-time sign-in code by email.
    func requestSignInCode(email: String) async {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, !authWorking else { return }
        authWorking = true
        defer { authWorking = false }
        do {
            try await WheesprAuth.requestCode(email: clean)
            pendingAuthEmail = clean
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Verify the emailed code and persist the resulting session.
    func verifySignIn(code: String) async {
        guard let email = pendingAuthEmail, !authWorking else { return }
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        authWorking = true
        defer { authWorking = false }
        do {
            let session = try await WheesprAuth.verify(email: email, code: clean)
            applySession(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Back out of the code step to re-enter the email.
    func cancelSignIn() { pendingAuthEmail = nil }

    func signOutWheespr() {
        wheesprConnectionMutatedSinceLaunch = true
        // Abandon any in-flight refresh so its result can't resurrect the session.
        refreshTask?.cancel()
        refreshTask = nil
        WheesprAuth.cancelInflightRefresh()
        let refresh = Config.wheesprSession?.refreshToken
        if let refresh { Task { await WheesprAuth.logout(refreshToken: refresh) } }
        Config.wheesprSession = nil
        wheesprConnected = false
        wheesprEmail = nil
        pendingAuthEmail = nil
        // Asked for: never nag about it, and do not treat the next launch as a
        // surprise sign-out.
        Config.lastSignedInEmail = nil
        signedOutNotice = nil
        reconcileDisplayedTranscriptionEngineIfIdle()
    }

    /// UI-only sign-out after a 401 refresh (Keychain already cleared).
    private func handleSessionExpired() {
        wheesprConnectionMutatedSinceLaunch = true
        refreshTask?.cancel()
        refreshTask = nil
        WheesprAuth.cancelInflightRefresh()
        wheesprConnected = false
        wheesprEmail = nil
        pendingAuthEmail = nil
        // lastError is transient; the notice persists until acknowledged, so a
        // sign-out cannot be missed by looking away for a moment.
        noteSignedOut(.expired)
        lastError = "Сессия истекла — войдите снова"
        reconcileDisplayedTranscriptionEngineIfIdle()
    }

    private func installSessionLifecycleObservers() {
        let adopted = notificationCenter.addObserver(
            forName: .wheesprSessionAdopted, object: nil, queue: .main
        ) { [weak self] note in
            guard let session = note.userInfo?["session"] as? WheesprSession else { return }
            // `queue: .main` already guarantees this runs on the main thread, so
            // the isolation is a fact the compiler cannot see. Asserting it
            // keeps the update synchronous; a `Task { @MainActor }` would defer
            // adoption by a turn, and the UI would render one frame signed out
            // immediately after a successful sign-in.
            MainActor.assumeIsolated { self?.applySession(session) }
        }
        let expired = notificationCenter.addObserver(
            forName: .wheesprSessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSessionExpired() }
        }
        sessionObservers = [adopted, expired]
    }

    /// Permanently delete the signed-in account (App Review 5.1.1(v) — the
    /// backend purges the user + sessions + billing linkage via FK cascade).
    /// Returns true on success; failures land in lastError.
    func deleteAccount() async -> Bool {
        guard let token = await wheesprAccessToken() else {
            lastError = "Войдите, прежде чем удалять аккаунт."
            return false
        }
        switch await AccountDeletion.perform(baseURL: Config.backendBaseURL, token: token) {
        case .deleted:
            signOutWheespr()
            Config.purchasedTier = nil
            lastError = nil
            return true
        case .failed(let message):
            lastError = message
            return false
        }
    }

    /// A fresh access token. Delegates to the single `WheesprAuth.validAccessToken`
    /// refresh path so PaywallAPI / gateways / AppState cannot race-rotate the
    /// refresh token. Syncs email UI state after a successful refresh.
    func wheesprAccessToken() async -> String? {
        let token = await WheesprAuth.validAccessToken()
        if let email = Config.wheesprSession?.email, !email.isEmpty {
            wheesprEmail = email
        }
        if Config.wheesprSession == nil, wheesprConnected {
            // Race: expired notification may not have run yet on this actor turn.
            wheesprConnected = false
        }
        return token
    }

    /// Native Sign in with Apple (gated by `Config.socialAccountLoginEnabled`).
    func signInWithApple() async {
        guard !authWorking else { return }
        authWorking = true
        defer { authWorking = false }
        do {
            let result = try await AppleAccountAuth.shared.signIn()
            let session = try await WheesprAuth.loginAppleNative(
                idToken: result.idToken, nonce: result.nonce)
            applySession(session)
        } catch AppleAccountAuthError.cancelled {
            // User dismissed — no error toast.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Native Google **account** login (openid/email/profile) — distinct from
    /// the Calendar connector in Connected Apps.
    /// The auth steps are injectable so the ORCHESTRATION is testable — the
    /// guard, the restart, the cancel-silence and the error surface — without
    /// a browser or a Google account. Production callers pass nothing.
    func signInWithGoogleAccount(
        authorize: () async throws -> String = {
            try await GoogleAccountAuth.shared.authorizeIDToken(
                clientID: Config.googleSignInClientID,
                clientSecret: Config.googleSignInClientSecret)
        },
        login: (String) async throws -> WheesprSession = WheesprAuth.loginGoogleNative
    ) async {
        if authWorking {
            // Reported as "signed in a second time and the app did not react":
            // the first browser flow was still alive (it waits up to two
            // minutes), so this guard swallowed every further click in total
            // silence. A repeat click is intent, not noise — cancel the stale
            // flow and start a fresh one instead of ignoring the user.
            GoogleAccountAuth.shared.cancel()
            for _ in 0..<50 where authWorking {           // ≤5 s to unwind
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !authWorking else {
                lastError = "Вход ещё не завершён — проверьте окно браузера."
                return
            }
        }
        authWorking = true
        defer { authWorking = false }
        do {
            let idToken = try await authorize()
            let session = try await login(idToken)
            applySession(session)
        } catch GoogleAuthError.cancelled {
            // User dismissed — no error toast.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Run the Google OAuth flow and persist the resulting tokens.
    func connectGoogle() async {
        guard !googleConnecting else { return }
        guard hasGoogleClientID else {
            let message = GoogleAuthError.missingClientID.errorDescription
            googleConnectionError = message
            lastError = message
            return
        }
        guard hasGoogleClientSecret else {
            let message = GoogleAuthError.missingClientSecret.errorDescription
            googleConnectionError = message
            lastError = message
            return
        }
        googleConnectionError = nil
        googleConnecting = true
        defer { googleConnecting = false }
        do {
            let tokens = try await googleAuth.authorize(
                clientID: effectiveGoogleClientID,
                clientSecret: effectiveGoogleClientSecret)
            Config.googleTokens = tokens
            Config.googleScopeVersion = GoogleAuth.scopeVersion
            googleConnectionMutatedSinceLaunch = true
            googleConnected = true
            googleConnectionError = nil
            lastError = nil
            applyReminderSettings()   // reminders need a connected calendar
            rebuildPromptWorkflows()
        } catch GoogleAuthError.cancelled {
            googleConnectionError = nil
        } catch {
            let message = error.localizedDescription
            googleConnectionError = message
            lastError = message
        }
    }

    func cancelGoogleConnection() {
        googleAuth.cancel()
    }

    func disconnectGoogle() {
        googleConnectionMutatedSinceLaunch = true
        googleAuth.cancel()
        let refreshToken = Config.googleTokens?.refreshToken
        Task { await GoogleAuth.revoke(refreshToken: refreshToken) }
        Config.googleTokens = nil
        googleConnected = false
        googleConnectionError = nil
        applyReminderSettings()   // stops polling + clears scheduled reminders
        rebuildPromptWorkflows()
    }

    /// Pull the current calendar event's agenda and add it as a context source.
    func pullAgenda() async {
        guard !calendarImporting else { return }
        guard googleConnected, let current = Config.googleTokens else {
            lastError = GoogleAuthError.notConnected.errorDescription
            return
        }
        calendarImporting = true
        defer { calendarImporting = false }
        do {
            let tokens = try await GoogleAuth.validTokens(
                clientID: effectiveGoogleClientID,
                clientSecret: effectiveGoogleClientSecret,
                current: current)
            if tokens.accessToken != current.accessToken { Config.googleTokens = tokens }
            // Hidden meetings stay hidden even on an explicit pull: "not this
            // one" is an answer about the call, not about one panel.
            let agenda = try await CalendarService.currentAgenda(
                accessToken: tokens.accessToken, excluding: dismissedMeetingIDs)
            contextFiles.append(ImportedContextFile(name: "Calendar · \(agenda.title)", text: agenda.summary))
            // A calendar agenda is written by a person, so it satisfies the
            // "correct, and from outside the audio" rule the measurements set.
            refreshContextGlossarySuggestions()
            applyCalendarAgenda(agenda)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Load a specific calendar event's context into the call: title, agenda,
    /// attendees. Mirrors `pullAgenda` but addresses the event by id, so a
    /// meeting the user picked in Focus wins over whatever is nearest in time.
    ///
    /// `title` is the row's own label, used only to name the failure and the
    /// context file when the fetch cannot happen — the user should still see
    /// which meeting they picked.
    func applyMeetingContext(meetingID: String, title: String) async {
        guard !calendarImporting else { return }
        guard googleConnected, let current = Config.googleTokens else {
            lastError = GoogleAuthError.notConnected.errorDescription
            return
        }
        calendarImporting = true
        defer { calendarImporting = false }
        do {
            let tokens = try await GoogleAuth.validTokens(
                clientID: effectiveGoogleClientID,
                clientSecret: effectiveGoogleClientSecret,
                current: current)
            if tokens.accessToken != current.accessToken { Config.googleTokens = tokens }
            let agenda = try await CalendarService.agenda(
                eventID: meetingID, accessToken: tokens.accessToken)
            // Re-picking the same meeting replaces its context file instead of
            // stacking duplicates — the row is a switch, not an append.
            let name = "Calendar · \(agenda.title)"
            // Snapshot BEFORE anything is rewritten. applyCalendarAgenda changes
            // the title, the goal and the attendee count as well as adding the
            // file, so undoing a misclick means restoring all of it, not just
            // deleting one context entry.
            appliedMeetingContext = AppliedMeetingContext(
                meetingID: meetingID,
                contextFileName: name,
                previousTitle: meetingTitle,
                previousGoal: callGoal,
                previousSuggestedGoal: suggestedGoal,
                previousAttendeeCount: callAttendeeCount)
            contextFiles.removeAll { $0.name == name }
            contextFiles.append(ImportedContextFile(name: name, text: agenda.summary))
            applyCalendarAgenda(agenda)
            lastError = nil
        } catch {
            lastError = "Не удалось загрузить \(title): \(error.localizedDescription)"
        }
    }

    func clearAllContext() {
        contextFiles.removeAll()
        contextFolders.removeAll()
        persistContextFolders()
        contextNotes = ""
    }

    // MARK: - Document connectors (Google Docs / Sheets / Notion)

    /// True when the CURRENT grant covers the Docs + Sheets services (granular
    /// authorization — the user may have excluded them from the grant).
    var googleHasDocsScope: Bool {
        googleConnected
            && Config.googleGrantedServices.contains(GoogleService.docs.rawValue)
            && Config.googleGrantedServices.contains(GoogleService.sheets.rawValue)
    }

    /// A fresh Google access token, refreshing if needed. Nil (with an error
    /// set) when not connected or the grant predates the Docs/Sheets scope.
    private func freshGoogleToken() async -> String? {
        guard googleConnected, let current = Config.googleTokens else {
            lastError = GoogleAuthError.notConnected.errorDescription
            return nil
        }
        guard Config.googleScopeVersion >= GoogleAuth.scopeVersion else {
            lastError = "Переподключите Google в настройках, чтобы выдать доступ к Docs и Sheets."
            return nil
        }
        do {
            let tokens = try await GoogleAuth.validTokens(
                clientID: effectiveGoogleClientID,
                clientSecret: effectiveGoogleClientSecret,
                current: current)
            if tokens.accessToken != current.accessToken { Config.googleTokens = tokens }
            return tokens.accessToken
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Create a NEW Google Doc from the current assistant answer + prompt +
    /// blind spots, then open it in the browser. Fails soft with a guiding
    /// error (connect / reconnect Google) — never silently.
    func exportAssistantAnswerToGoogleDocs() async {
        guard googleConnected else {
            lastError = "Подключите Google в настройках, чтобы создать документ."
            return
        }
        guard Config.googleScopeVersion >= GoogleAuth.scopeVersion,
              Config.googleGrantedServices.contains(GoogleService.docs.rawValue) else {
            lastError = "Переподключите Google в настройках с доступом к Docs, чтобы создать документ."
            return
        }
        do {
            let doc = try await prepareCurrentAnswerExport()
            guard let token = await freshGoogleToken() else { return }   // sets lastError
            let html = AssistantDocHTML.build(
                title: doc.title, date: doc.exportedAt, prompt: doc.prompt,
                answer: doc.answer, blindSpots: doc.blindSpots,
                earlierExchanges: doc.earlierExchanges)
            let created = try await GoogleDocsWriter.create(
                title: doc.title, html: html, accessToken: token)
            if let url = URL(string: created.webViewLink) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            lastError = "Выгрузка в Google Docs не удалась: \(error.localizedDescription)"
        }
    }

    /// The last spreadsheet this app created, kept only so it can be undone.
    ///
    /// Holding the id here — rather than looking it up later — is what lets the
    /// undo be honest about `createdByUs`. Nothing else may delete a Drive file:
    /// a file we did not create cannot end up in this property.
    @Published private(set) var lastCreatedSpreadsheet: GoogleDriveWriter.CreatedFile?
    /// Title of that file, for the undo affordance's label.
    @Published private(set) var lastCreatedSpreadsheetTitle: String?

    /// Create a spreadsheet from a table in the current answer, then open it.
    ///
    /// The proposal is the confirmation: it is only ever raised from a chip that
    /// states the exact title and row count, and the user has to click it.
    func exportAnswerTableToGoogleSheets(_ proposal: GoogleFileExport.Proposal) async {
        guard case let .createSpreadsheet(title, table) = proposal else {
            // Every other case belongs to a different executor. Silently doing
            // "something close" with a proposal the user confirmed is exactly
            // the failure this boundary exists to prevent.
            lastError = "Это действие здесь недоступно."
            return
        }
        guard googleConnected else {
            lastError = "Подключите Google в настройках, чтобы создать таблицу."
            return
        }
        guard let token = await freshGoogleToken() else { return }   // sets lastError
        do {
            let created = try await GoogleDriveWriter.createSpreadsheet(
                title: title, table: table, accessToken: token)
            lastCreatedSpreadsheet = created
            lastCreatedSpreadsheetTitle = title
            if let url = URL(string: created.url) { NSWorkspace.shared.open(url) }
        } catch {
            lastError = "Не удалось создать таблицу: \(error.localizedDescription)"
        }
    }

    /// Move the spreadsheet we just created to the user's Drive trash.
    ///
    /// The only deletion path in the app, and it is a human undo of a human
    /// action seconds earlier — never something inferred from an answer. It
    /// trashes rather than destroys, so Drive's own thirty-day restore still
    /// applies if the undo was itself a mistake.
    func undoLastSpreadsheetExport() async {
        guard let created = lastCreatedSpreadsheet else { return }
        guard let token = await freshGoogleToken() else { return }
        do {
            try await GoogleDriveWriter.trashFile(
                fileID: created.id, createdByUs: true, accessToken: token)
            lastCreatedSpreadsheet = nil
            lastCreatedSpreadsheetTitle = nil
        } catch {
            lastError = "Не удалось отправить в корзину: \(error.localizedDescription)"
        }
    }

    /// Create a Notion page from the current answer + prompt + blind spots via
    /// the connected Notion MCP server, then open it. Fails soft.
    func exportAssistantAnswerToNotion() async {
        guard let mcp, mcp.canExportToNotion else {
            lastError = "Подключите Notion в настройках, чтобы создать страницу."
            return
        }
        do {
            let doc = try await prepareCurrentAnswerExport()
            let markdown = NotionExport.markdown(
                title: doc.title, date: doc.exportedAt, prompt: doc.prompt,
                answer: doc.answer, blindSpots: doc.blindSpots,
                earlierExchanges: doc.earlierExchanges)
            let result = try await mcp.createNotionPage(title: doc.title, content: markdown)
            // The tool result usually carries the new page URL — open it.
            if let url = Self.firstNotionURL(in: result) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            lastError = "Выгрузка в Notion не удалась: \(error.localizedDescription)"
        }
    }

    /// Extract the first Notion page URL from an MCP tool's text result.
    private static func firstNotionURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\"" || $0 == "(" || $0 == ")" }) {
            let s = String(token)
            if s.hasPrefix("https://"), s.contains("notion.so") || s.contains("notion.site") {
                return URL(string: s)
            }
        }
        return nil
    }

    /// First https URL in a tool's text result — trackers usually return the
    /// created item's permalink somewhere in their JSON.
    static func firstHTTPSURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { " \n\"',()[]{}".contains($0) }) {
            // Permalinks inside JSON arrive escaped ("https:\/\/app.asana.com").
            let s = String(token).replacingOccurrences(of: "\\/", with: "/")
            if s.hasPrefix("https://"), let url = URL(string: s) { return url }
        }
        return nil
    }

    func importGoogleDoc(from urlString: String) async {
        guard let id = SourceURL.googleDocID(from: urlString) else {
            lastError = "Это не похоже на ссылку Google Docs."
            return
        }
        await withImporting {
            guard let token = await self.freshGoogleToken() else { return }
            let doc = try await GoogleDocsService.read(documentID: id, accessToken: token)
            self.appendContext(name: "Doc · \(doc.title)", text: doc.text)
        }
    }

    func importGoogleSheet(from urlString: String) async {
        guard let id = SourceURL.googleSheetID(from: urlString) else {
            lastError = "Это не похоже на ссылку Google Sheets."
            return
        }
        await withImporting {
            guard let token = await self.freshGoogleToken() else { return }
            let sheet = try await GoogleSheetsService.read(spreadsheetID: id, accessToken: token)
            self.appendContext(name: "Sheet · \(sheet.title)", text: sheet.text)
        }
    }

    private func appendContext(name: String, text: String) {
        guard !text.isEmpty else { lastError = "В «\(name)» нет читаемого текста."; return }
        contextFiles.append(ImportedContextFile(name: name, text: text))
    }

    /// Shared spinner + error handling for the document connectors.
    private func withImporting(_ work: @escaping () async throws -> Void) async {
        guard !contextImporting else { return }
        contextImporting = true
        defer { contextImporting = false }
        do { try await work(); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    // MARK: - Saved context sets (pin context for repeating calls)

    /// Save the current files + notes as a reusable, named set.
    func saveContextSet(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        contextSets.append(ContextSet(name: trimmed, files: contextFiles, notes: contextNotes))
    }

    /// Replace the current context with a saved set.
    func applyContextSet(id: UUID) {
        guard let set = contextSets.first(where: { $0.id == id }) else { return }
        contextFiles = set.files
        contextNotes = set.notes
    }

    func deleteContextSet(id: UUID) {
        contextSets.removeAll { $0.id == id }
    }

    /// How answers should read this session. Per session rather than global:
    /// the right register for a board update is the wrong one for a debugging
    /// call.
    @Published var answerStyle: AnswerStyle = AnswerStyle.defaultStyle

    /// Send the whole transcript and everything attached on the NEXT request.
    ///
    /// Per request, cleared the moment one is sent. A persistent switch would
    /// keep charging long after the one long call that justified it, and nobody
    /// connects a bill in June to a toggle they flipped in March.
    @Published var fullContextRequested = false

    /// What full context would cost and send right now, for the composer to
    /// show BEFORE the send. Recomputed from live state rather than cached, so
    /// it cannot quote a stale price for a transcript that has since grown.
    var fullContextQuote: FullContextRequest.Quote {
        let model = Config.selectedRequestModel
        return FullContextRequest.quote(
            model: model,
            requested: fullContextRequested,
            inputChars: transcriptText.count + attachedContextCharacters,

            baseCredits: FullContextRequest.baseCredits(for: model))
    }

    /// Whether the control is worth showing at all for the current model.
    var fullContextAvailable: Bool {
        FullContextRequest.isEligible(Config.selectedRequestModel)
    }

    /// Everything attached to the call, in characters.
    ///
    /// Counted into the quote rather than assumed small: a folder of specs can
    /// dwarf the transcript, and a price that ignored it would understate —
    /// which is the one direction this feature must never err in.
    var attachedContextCharacters: Int {
        contextFiles.reduce(0) { $0 + $1.text.count } + contextNotes.count
    }

    /// Whether the assistant answers with questions this session.
    ///
    /// A mode, not a style — see SocraticMode for why. Per session and off by
    /// default: it changes whether you get an answer at all, so it must be
    /// switched on deliberately every time rather than lying in wait from a
    /// setting somebody changed last week.
    @Published var socraticModeEnabled = false {
        didSet {
            guard socraticModeEnabled != oldValue else { return }
            socraticExchanges = 0
            socraticBrokenOut = false
        }
    }

    /// Free-form asks answered with questions since the mode was switched on.
    @Published private(set) var socraticExchanges = 0

    /// Set by the break-out action. Answers plainly WITHOUT leaving the mode:
    /// making the escape hatch also switch the feature off would punish using
    /// it, and the user wants this answer directly, not a different product.
    @Published private(set) var socraticBrokenOut = false

    /// Shown when the bound runs out, so the change in behaviour is announced
    /// rather than left for the user to infer from an answer that suddenly
    /// looks different.
    @Published var socraticNotice: String?

    /// Whether the next free-form ask will be answered with questions. Drives
    /// the indicator, so the posture is visible BEFORE sending rather than
    /// discovered in the reply.
    var socraticWillWithhold: Bool {
        socraticModeEnabled && !socraticBrokenOut
            && SocraticMode.shouldWithholdAnswer(exchangesSoFar: socraticExchanges,
                                                 isRecording: status == .recording)
    }

    /// How many question-turns remain before it answers plainly.
    var socraticRemainingExchanges: Int {
        max(0, SocraticMode.exchangeLimit(isRecording: status == .recording) - socraticExchanges)
    }

    /// The one action that gets a direct answer.
    ///
    /// Applies to the next ask and clears itself once used, so breaking out is a
    /// single decision about a single question rather than a second piece of
    /// state to remember to undo.
    func answerPlainlyNext() {
        guard socraticModeEnabled else { return }
        socraticBrokenOut = true
    }

    func promptForCurrentRecording(_ prompt: QuickPrompt) -> QuickPrompt {
        let adapted = RecordingPromptAdapter.adapt(prompt, kind: effectiveRecordingContextKind)
        // Style applies AFTER the recording-context adaptation, so a lecture
        // prompt stays a lecture prompt and only its delivery changes. The
        // style never alters the structural contract — see AnswerStyle.
        let styled = answerStyle.applied(to: adapted.prompt)
        guard styled != adapted.prompt else { return adapted }
        return QuickPrompt(id: adapted.id, icon: adapted.icon, title: adapted.title,
                           tooltip: adapted.tooltip, prompt: styled)
    }

    func runPrompt(_ originalPrompt: QuickPrompt) {
        let prompt = promptForCurrentRecording(originalPrompt)
        let adaptedForMedia = prompt.prompt != originalPrompt.prompt
        FunnelTracker.trackOnce(.firstAIAction)   // funnel activation (once/device)
        sessionUsedAI = true
        analytics(.promptRun(promptID: originalPrompt.id, style: answerStyle))
        // The Fact Check prompt runs a structured, context-grounded check with a
        // color-coded result instead of a free-text answer.
        if prompt.id == "factcheck" { runFactCheck(originatingPrompt: prompt.prompt); return }
        // Log Decision extracts a structured record and files it to the ledger.
        if prompt.id == "logdecision", !adaptedForMedia {
            runLogDecision(originatingPrompt: prompt.prompt)
            return
        }
        // Tasks + Summary produce typed artifacts with deterministic validation
        // (A6) instead of streamed markdown.
        if prompt.id == "tasks", !adaptedForMedia {
            runStructuredButton(promptID: "tasks", kind: .tasks, originatingPrompt: prompt.prompt)
            return
        }
        if prompt.id == "summary", !adaptedForMedia {
            runStructuredButton(promptID: "summary", kind: .summary, originatingPrompt: prompt.prompt)
            return
        }
        // Quick prompts never consume pinned images — those are for the ask box.
        // Each built-in button carries an expert skill (methodology + quality bar)
        // that primes the system prompt; custom prompts resolve to nil → base only.
        // The prompt id also selects the role×button hint from RoleSkillMatrix.
        run(prompt: prompt.prompt, images: [],
            skill: adaptedForMedia ? nil : PromptSkills.guidance(for: prompt.id),
            promptID: prompt.id)
    }

    /// Log Decision: extract the decision just made (structured, skill-primed),
    /// show it in the response panel, and file it into the Decision Ledger
    /// backend. Local capture always renders; the ledger write is best-effort
    /// (no backend → local-only note, so the button works before deploy).
    func runLogDecision(originatingPrompt: String? = nil) {
        let promptedAt = Date()
        let modelSnapshot = Config.selectedRequestModel
        let selectionSnapshot = modelSnapshot.requestSelectionID ?? modelSnapshot.id
        supersedeActiveAI(status: .superseded, at: promptedAt)
        beginAssistantAnswer(
            prompt: originatingPrompt ?? "Log the decision just made.",
            promptID: "logdecision", promptedAt: promptedAt,
            modelSelectionID: selectionSnapshot)
        let runGeneration = aiRunGeneration
        followUpTask?.cancel()
        // Cleared with the same reasoning as the actions below: the archived
        // exchange keeps its own chips and renders them itself, so carrying
        // them into the next answer only made two answers show an identical
        // row. Per answer, not global.
        if !followUpPrompts.isEmpty { carriedFollowUpPrompts = followUpPrompts }
        followUpPrompts = []
        // Cleared here on purpose: these belong to the answer being replaced,
        // and archiveLiveExchange above has just stored them ON that exchange,
        // which is where they stay visible. Every answer shows its OWN buttons.
        answerActions = []
        answerActionResult = nil
        aiResponse = ""
        aiStreaming = true
        UsageTracker.recordAIRequest()
        refreshTier()
        // Digest-aware: a decision made in minute 5 of a long call must still
        // be capturable at minute 70 (A2).
        let transcript = promptTranscript(cap: 12_000)
        let goal = effectiveCallGoal
        let query = PromptWorkflows.groundingQuery(goal: goal, recentTranscript: transcript)
        let context = promptContext(
            query: (originatingPrompt ?? "log decision") + "\n" + goal + "\n" + query)
        let workflow = designedWorkflow(for: "logdecision")
        installPromptWorkflowPlan(
            workflow: workflow,
            composition: "Capture the decision",
            writeback: ("File the decision", workflowLedgerApp))
        let layers = [activeCallTheme.guidance,
                      RoleSkillMatrix.guidance(roleID: userRoleID, promptID: "logdecision"),
                      PromptSkills.guidance(for: "logdecision"),
                      BundledSkillRouter.guidance(for: "logdecision",
                                                  query: bundledSkillQuery(extra: query))]
            .compactMap { $0 }
        let extraGuidance = layers.isEmpty ? nil : layers.joined(separator: "\n\n")

        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Prior-meeting background: does this reopen an earlier call?
                var groundedContext = context
                if let workflow, !query.isEmpty {
                    let snippets = await self.groundingSnippets(
                        for: workflow, promptID: "logdecision", query: query,
                        runGeneration: runGeneration)
                    if !snippets.isEmpty {
                        let block = PromptWorkflows.renderGrounding(snippets)
                        groundedContext = context.isEmpty ? block : context + "\n\n" + block
                    }
                }
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                self.aiStage = "Capture the decision"

                guard let decision = try await DecisionLogService.extract(
                    transcript: transcript, context: groundedContext,
                    goal: goal, extraGuidance: extraGuidance,
                    model: modelSnapshot) else {
                    guard self.aiRunGeneration == runGeneration, !Task.isCancelled else { return }
                    self.aiResponse = "No concrete decision has been made yet — once the group commits to something, press 📌 again."
                    self.aiStreaming = false
                    self.aiStage = nil
                    return
                }
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                self.aiResponse = decision.markdown

                // Best-effort ledger write.
                let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !base.isEmpty else {
                    self.aiResponse += "\n\n_Captured locally — configure a backend to sync decisions to your ledger._"
                    self.updateWorkflowStep(
                        appID: self.workflowLedgerApp.id, label: "File the decision",
                        status: .skipped, detail: "Backend not configured")
                    self.aiStreaming = false
                    self.aiStage = nil
                    return
                }
                guard let token = await self.wheesprAccessToken() else {
                    guard self.aiRunGeneration == runGeneration, !Task.isCancelled else { return }
                    self.aiResponse += "\n\n_Captured locally — sign in to sync this to your Decision Ledger._"
                    self.updateWorkflowStep(
                        appID: self.workflowLedgerApp.id, label: "File the decision",
                        status: .skipped, detail: "Sign-in required")
                    self.aiStreaming = false
                    self.aiStage = nil
                    return
                }
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                self.aiStage = "File the decision"
                let team = try await DecisionLogService.ensureTeam(base: base, token: token)
                let id = try await DecisionLogService.logDecision(decision, teamID: team.id, base: base, token: token)
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                self.aiResponse += "\n\n✅ _Logged to the Decision Ledger (\(team.name)) — id `\(id.prefix(8))…_"

                // The Efficiency Engine, on the decision just filed. Additive on
                // purpose: the capture and the ledger write have already
                // succeeded, so a failure here must not retract either. It
                // appends a note and leaves the record intact.
                self.aiStage = "Shape the follow-up"
                await self.loadEfficiencyContracts()
                do {
                    let followUp = try await EfficiencyEngineService.generate(
                        decisionID: id, sourceText: transcript, base: base, token: token)
                    try Task.checkCancellation()
                    guard self.aiRunGeneration == runGeneration else { return }
                    // Kept as data before it is rendered: the prose below is a
                    // view of this, and a view is not a record.
                    self.efficiencyFollowUp = SavedFollowUp(followUp)
                    self.aiResponse += "\n\n" + EfficiencyEngineService.render(
                        followUp, fieldOrder: self.efficiencyFieldOrder[followUp.goalType] ?? [])
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard self.aiRunGeneration == runGeneration else { return }
                    self.aiResponse += "\n\n_Follow-up unavailable: \(error.localizedDescription)_"
                }

                self.aiStage = nil
                self.scheduleFollowUps(request: "Log the decision just made.",
                                       material: groundedContext, output: decision.markdown)
            } catch is CancellationError {
                // no-op
            } catch {
                guard self.aiRunGeneration == runGeneration else { return }
                if self.aiStage == "File the decision" {
                    self.updateWorkflowStep(
                        appID: self.workflowLedgerApp.id, label: "File the decision",
                        status: .failed, detail: "Connection failed; capture kept locally")
                } else if let index = self.workflowSteps.firstIndex(where: { $0.status == .running }) {
                    self.workflowSteps[index].status = .failed
                    self.workflowSteps[index].detail = "Decision capture failed"
                }
                // Keep whatever was captured; report the sync failure honestly.
                let note = self.aiResponse.isEmpty ? "Error: " : "\n\n⚠️ _Ledger sync failed: "
                self.aiResponse += note + error.localizedDescription + (self.aiResponse.isEmpty ? "" : "_")
            }
            guard self.aiRunGeneration == runGeneration else { return }
            await MainActor.run {
                self.aiStreaming = false
                self.aiStage = nil
                if !self.isRecording { self.persistCurrentSession() }
            }
        }
    }

    /// Extract factual claims from the transcript and verify them against the
    /// call's user-provided context. Results land in `factClaims`; a sheet opens.
    /// - Parameter searchWeb: per-request opt-in for the web lane (item 11).
    ///   Only the sheet's explicit button passes true; the background cadence
    ///   loop cannot — nothing leaves for a search engine without the user
    ///   asking on that specific check.
    func runFactCheck(originatingPrompt: String? = nil, searchWeb: Bool = false) {
        // A check is already in flight — just re-present its (possibly dismissed) sheet.
        guard !factChecking else { showFactCheck = true; return }
        let promptedAt = Date()
        let modelSnapshot = Config.selectedRequestModel
        let selectionSnapshot = modelSnapshot.requestSelectionID ?? modelSnapshot.id
        supersedeActiveAI(status: .superseded, at: promptedAt)
        beginAssistantAnswer(
            prompt: originatingPrompt ?? "Fact-check the conversation.",
            promptID: "factcheck", promptedAt: promptedAt,
            modelSelectionID: selectionSnapshot)
        let runGeneration = aiRunGeneration
        factChecking = true
        showFactCheck = true
        factClaims = []
        factCheckError = nil
        factCheckSearch = nil
        aiResponse = ""
        aiStreaming = true
        // Digest-aware: long calls keep early claims checkable (A2). Sized to
        // the service's own 8k clip so the digest survives it.
        let transcript = promptTranscript(cap: 8_000)
        let query = PromptWorkflows.groundingQuery(goal: effectiveCallGoal, recentTranscript: transcript)
        let context = promptContext(
            query: (originatingPrompt ?? "fact check") + "\n" + query)
        let workflow = designedWorkflow(for: "factcheck")
        installPromptWorkflowPlan(workflow: workflow, composition: "Verify factual claims")
        // Theme + role steer claim selection; the factcheck button SKILL is
        // deliberately excluded — its outputs (confidence, counter-questions)
        // aren't representable in the FactClaim contract.
        let guidanceLayers = [effectiveRecordingContextGuidance,
                              activeCallTheme.guidance,
                              RoleSkillMatrix.guidance(roleID: userRoleID, promptID: "factcheck"),
                              BundledSkillRouter.guidance(for: "factcheck",
                                                          query: bundledSkillQuery(extra: query))]
            .compactMap { $0 }
        let extraGuidance = guidanceLayers.isEmpty ? nil : guidanceLayers.joined(separator: "\n\n")
        aiTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only the still-current check owns this UI state. A newer
                // prompt has already reset it in supersedeActiveAI().
                if self.aiRunGeneration == runGeneration {
                    self.factChecking = false
                    self.aiStreaming = false
                    self.aiStage = nil
                }
            }
            let token = await self.wheesprAccessToken()
            // Ground the check in live sources (docs, incidents, tickets, CRM)
            // per the factcheck workflow — claims verify against evidence in
            // hand, not model memory. No-op when nothing relevant is connected.
            var groundedContext = context
            if let workflow, !query.isEmpty {
                let snippets = await self.groundingSnippets(
                    for: workflow, promptID: "factcheck", query: query,
                    runGeneration: runGeneration)
                if !snippets.isEmpty {
                    let block = PromptWorkflows.renderGrounding(snippets)
                    groundedContext = context.isEmpty ? block : context + "\n\n" + block
                }
            }
            guard self.aiRunGeneration == runGeneration, !Task.isCancelled else { return }
            self.aiStage = "Verify factual claims"
            do {
                let outcome = try await self.factCheckProvider(FactCheckProviderRequest(
                    transcript: transcript, context: groundedContext,
                    accessToken: token, extraGuidance: extraGuidance,
                    searchWeb: searchWeb), modelSnapshot)
                guard self.aiRunGeneration == runGeneration, !Task.isCancelled else { return }
                self.factClaims = outcome.claims
                self.factCheckSearch = outcome.search
            } catch {
                guard self.aiRunGeneration == runGeneration else { return }
                self.factCheckError = error.localizedDescription
                if let index = self.workflowSteps.firstIndex(where: {
                    $0.label == "Verify factual claims" && $0.status == .running
                }) {
                    self.workflowSteps[index].status = .failed
                    self.workflowSteps[index].detail = "Verification failed"
                }
            }
        }
    }

    /// Run a free-form question the user typed into the ask composer. Consumes
    /// any pinned images (vision).
    /// Run the reflection pass over the finished call.
    ///
    /// Reuses the live blind-spot provider, so the same judge and the same
    /// evidence requirement apply — this method decides only what SURVIVES the
    /// judge, never what counts as a finding. Nothing here re-implements judging.
    func runPostCallReflection(summary: String = "") async {
        guard canRunPostCallReflection else { return }
        reflectionRunning = true
        defer { reflectionRunning = false }

        // Reads `transcriptText` and therefore automatically reads the BETTER
        // text when one exists: the local whole-file pass replaces the remote
        // side of the transcript in place, so a re-transcribed call needs no
        // special case here. That pass measured 32% fewer errors, and a
        // reflection is only as good as the words it read.
        let request = BlindSpotProviderRequest(
            goal: effectiveCallGoal,
            transcript: transcriptText,
            // No prior titles: the live pass suppressed repeats DURING the call,
            // and a point worth making about the finished call is worth making
            // even if a version of it flashed past mid-meeting.
            priorTitles: [],
            accessToken: await blindSpotAccessTokenProvider?(),
            guidance: nil, context: nil, probe: "", theme: activeCallTheme.rawValue,
            grounded: false)

        do {
            let outcome = try await blindSpotSuggestionProvider(request)
            let artefact = PostCallReflection.artefact(from: outcome.suggestions,
                                                       summary: summary)
            // Nil rather than an empty artefact: "ran and found nothing" and
            // "never ran" look the same to the UI on purpose, because both mean
            // there is nothing to show.
            reflectionArtefact = artefact.isEmpty ? nil : artefact
        } catch {
            // A failed reflection is not a failed call. Silent, because the user
            // did not ask for this pass by name and an error about a background
            // artefact is noise.
            Log.general.notice("post-call reflection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apply Socratic mode to a free-form ask, and advance its bound.
    ///
    /// Structured prompts are excluded: they have a required output shape, and
    /// replacing a fact-check verdict or an agenda with questions does not
    /// produce a Socratic version of those, it produces a broken one.
    /// Spend the full-context request. Called once per send, so the mode is per
    /// request in the strongest sense: it cannot survive into a second one even
    /// if the user forgets it was on.
    private func spendFullContextRequest() {
        guard fullContextRequested else { return }
        fullContextRequested = false
    }

    private func applyingSocraticMode(to prompt: String, promptID: String?) -> String {
        guard socraticModeEnabled, SocraticMode.applies(toBuiltInPromptID: promptID) else {
            return prompt
        }
        if socraticBrokenOut {
            // Spent on this ask, so the next one returns to the mode.
            socraticBrokenOut = false
            return prompt
        }
        let isRecording = status == .recording
        guard SocraticMode.shouldWithholdAnswer(exchangesSoFar: socraticExchanges,
                                                isRecording: isRecording) else {
            // The bound is spent. Say so rather than just behaving differently.
            socraticNotice = SocraticMode.boundReachedNotice
            return prompt
        }
        socraticExchanges += 1
        socraticNotice = nil
        return SocraticMode.applied(to: prompt, enabled: true,
                                    exchangesSoFar: socraticExchanges - 1,
                                    isRecording: isRecording, brokenOut: false)
    }

    func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty else { return }

        // A newly accepted message owns the composer turn immediately. Leaving
        // an older clarification card alive here let it supersede this request
        // minutes later when the user eventually clicked an option on the stale
        // card. Cancel both an in-flight assessment and an already-rendered card
        // before publishing the new preview; invalid/empty sends never reach this
        // point and therefore cannot dismiss useful state.
        supersedePendingClarification()

        var images = pendingImages.map { $0.imageData }
        pendingImages.removeAll()
        if !images.isEmpty, !Config.selectedModel.supportsVision {
            lastError = "Выбранная модель не понимает картинки — отправляю только текст."
            images = []
        }
        let prompt = trimmed.isEmpty ? "Describe the attached image(s)." : trimmed
        submittedPromptPreview = prompt

        // Tier 0 is synchronous and free, so an ambiguity that is really a count
        // never costs a round trip. Anything it cannot decide goes to tier 2 in
        // the background while the composer stays responsive.
        if clarificationAllowed, let questions = tierZeroClarification(for: prompt), !questions.isEmpty {
            pendingClarification = PendingClarification(prompt: prompt, images: images, questions: questions)
            return
        }
        guard clarificationAllowed else {
            run(prompt: prompt, images: images)
            return
        }
        beginClarificationAssessment(prompt: prompt, images: images)
    }

    // MARK: - One-click answer actions

    /// Actions offered under the finished answer, from what it contains and what
    /// is connected right now. Recomputed when an answer completes; cleared as
    /// soon as a new run starts so a chip can never act on a stale answer.
    @Published private(set) var answerActions: [AnswerActionPlanner.Action] = []
    /// Action currently executing, by id — the chip shows a spinner.
    @Published private(set) var runningAnswerAction: String?
    /// Result line for the last completed action, e.g. the created issue's URL.
    @Published var answerActionResult: String?

    /// Rebuild the chips for the visible answer. Cheap and synchronous: the
    /// planner is pure and the tool lists are already cached from the handshake.
    func refreshAnswerActions() {
        let answer = aiResponse
        guard !answer.isEmpty, let mcp else {
            answerActions = []
            return
        }
        // Every connected server's advertised write tools, with the argument
        // names each declares — the planner reads the live schema rather than
        // assuming what a given app calls things.
        let capabilities = mcp.researchableServers.flatMap { server in
            mcp.tools(for: server.id).map { tool in
                AnswerActionPlanner.ToolCapability(
                    serverID: server.id,
                    serverName: server.name,
                    toolName: tool.name,
                    toolDescription: tool.description ?? "",
                    argumentKeys: Array(tool.schemaProperties?.keys ?? [:].keys),
                    requiredKeys: tool.requiredArgumentKeys)
            }
        }
        answerActions = AnswerActionPlanner.plan(answer: answer, capabilities: capabilities)
        scheduleAnswerActionProposals(answer: answer, capabilities: capabilities)
    }

    /// One fast-model pass that proposes SPECIFIC actions the schema matcher
    /// cannot see — the record titled after the deal this answer is about, not
    /// just "Attio exposes create_record". Additive: proposals join the matched
    /// chips, and a failure leaves those untouched.
    private func scheduleAnswerActionProposals(answer: String,
                                               capabilities: [AnswerActionPlanner.ToolCapability]) {
        answerProposalTask?.cancel()
        let goal = effectiveCallGoal
        let model = LLMCatalog.background(for: Config.selectedModel)
        answerProposalTask = Task { [weak self] in
            guard let self else { return }
            let proposals = await AnswerActionProposer.propose(
                answer: answer, goal: goal, capabilities: capabilities,
                model: model, gateway: self.llm)
            guard !Task.isCancelled, !proposals.isEmpty else { return }
            // The answer must still be the one these were proposed for.
            guard self.aiResponse == answer else { return }
            for proposal in proposals {
                self.proposedArguments[proposal.action.id] = proposal.arguments
            }
            // Proposals lead: they are specific to this answer, where a matched
            // chip only knows the app can do the category of thing.
            let matched = self.answerActions.filter { !$0.isProposed }
            self.answerActions = Array((proposals.map(\.action) + matched)
                .prefix(AnswerActionPlanner.maxActions))
        }
    }

    /// Arguments a proposed action carries, by action id. Deterministic chips
    /// derive theirs at confirm time instead.
    private var proposedArguments: [String: [String: String]] = [:]

    /// The action awaiting confirmation. Writing into someone else's system is
    /// the one thing here Cruxwing cannot undo, so nothing is written until the
    /// user has seen the exact payload.
    @Published var pendingAnswerAction: PendingAnswerAction?

    /// A staged write: what will be sent, where, and — for a per-item filing —
    /// the individual items it will become.
    struct PendingAnswerAction: Identifiable, Equatable {
        let id: String
        let action: AnswerActionPlanner.Action
        /// Editable payload, keyed by the tool's own schema argument names.
        var fields: [String: String]
        /// Ordered field names, so the sheet does not reshuffle between opens.
        let fieldOrder: [String]
        /// Non-empty when this files one item per action item.
        var items: [TasksArtifact.Item]
        /// Connected-account namespace at the moment the user opened the
        /// confirmation. A reconnect, disconnect, or Cruxwing account switch
        /// invalidates the preview: the reviewed destination is no longer the
        /// destination that would receive the write.
        let connectionScope: UInt64?

        init(id: String,
             action: AnswerActionPlanner.Action,
             fields: [String: String],
             fieldOrder: [String],
             items: [TasksArtifact.Item],
             connectionScope: UInt64? = nil) {
            self.id = id
            self.action = action
            self.fields = fields
            self.fieldOrder = fieldOrder
            self.items = items
            self.connectionScope = connectionScope
        }

        var isPerItem: Bool { !items.isEmpty }
    }

    /// Stage a chip for confirmation. Nothing is written here.
    func prepareAnswerAction(_ action: AnswerActionPlanner.Action) {
        guard let mcp,
              let tool = mcp.tools(for: action.serverID).first(where: { $0.name == action.toolName }) else {
            lastError = "\(action.serverName) больше не подключён."
            return
        }
        let items = action.isPerItem ? AnswerActionItems.parse(aiResponse) : []
        let fields = stagedFields(for: action, tool: tool, items: items)
        pendingAnswerAction = PendingAnswerAction(
            id: action.id,
            action: action,
            fields: fields,
            fieldOrder: fields.keys.sorted(),
            items: items,
            connectionScope: mcp.groundingCacheScope)
    }

    func cancelAnswerAction() {
        pendingAnswerAction = nil
    }

    /// Fold the sheet's edits back before committing, so what the user sees in
    /// the preview is exactly what gets written.
    func applyConfirmEdits(fields: [String: String], items: [TasksArtifact.Item]) {
        guard var pending = pendingAnswerAction else { return }
        pending.fields = fields
        pending.items = items
        pendingAnswerAction = pending
    }

    /// Commit the staged write. The result — usually the created item's URL — is
    /// surfaced rather than swallowed, so nobody has to open the app to find out
    /// whether it worked.
    func commitAnswerAction() async {
        guard let pending = pendingAnswerAction, runningAnswerAction == nil else { return }

        // Production requires a live connection in the exact account namespace
        // captured by the confirmation. Tests may use a dispatcher alone; when
        // they also supply a reviewed scope, the same identity checks apply.
        let liveConnection: (
            manager: MCPConnectionManager,
            server: MCPServerDescriptor,
            scope: UInt64
        )?
        if let reviewedScope = pending.connectionScope {
            guard let mcp,
                  reviewedScope == mcp.groundingCacheScope,
                  let server = mcp.connectedServers.first(where: {
                      $0.id == pending.action.serverID
                  }) else {
                pendingAnswerAction = nil
                lastError = MCPConnectionError.reviewedConnectionChanged(
                    pending.action.serverName).localizedDescription
                return
            }
            liveConnection = (mcp, server, reviewedScope)
        } else if answerActionDispatcher == nil {
            // Every production-created preview carries a scope. Fail closed if
            // an older/restored payload somehow reaches this boundary without
            // one instead of silently selecting today's connected account.
            pendingAnswerAction = nil
            lastError = MCPConnectionError.reviewedConnectionChanged(
                pending.action.serverName).localizedDescription
            return
        } else {
            liveConnection = nil
        }

        pendingAnswerAction = nil
        runningAnswerAction = pending.id
        answerActionResult = nil
        defer { runningAnswerAction = nil }

        let destinationName = liveConnection?.server.name ?? pending.action.serverName

        do {
            if pending.isPerItem {
                var created = 0
                var failures: [String] = []
                for (index, item) in pending.items.enumerated() {
                    do {
                        _ = try await dispatchAnswerAction(
                            AnswerActionDispatchRequest(
                                action: pending.action,
                                payload: .trackerItem(item)),
                            liveConnection: liveConnection)
                        created += 1
                    } catch {
                        failures.append(item.task)
                        if let connectionError = error as? MCPConnectionError,
                           case .reviewedConnectionChanged = connectionError {
                            // The remaining items were approved for the old
                            // account too. Do not spin through them (and never
                            // attempt another write); make the interruption
                            // explicit and require a fresh review.
                            failures.append(contentsOf: pending.items
                                .dropFirst(index + 1).map(\.task))
                            lastError = connectionError.localizedDescription
                            break
                        }
                    }
                }
                // A partial result must say so — "created 2 of 3" is actionable,
                // "done" after two successes and a failure is a lie.
                answerActionResult = failures.isEmpty
                    ? "Created \(created) item(s) in \(destinationName)."
                    : "Created \(created) of \(pending.items.count) in \(destinationName). Failed: \(failures.joined(separator: "; "))"
            } else {
                let result = try await dispatchAnswerAction(
                    AnswerActionDispatchRequest(
                        action: pending.action,
                        payload: .fields(pending.fields)),
                    liveConnection: liveConnection)
                // Success surfacing, not a payload dump: tools answer with raw
                // JSON, and 200 chars of `{"data":{"gid":…` under an answer
                // reads as a crash even when it worked. Show the link if the
                // result carries one; otherwise a plain sentence.
                if let url = Self.firstHTTPSURL(in: result) {
                    answerActionResult = "Created in \(destinationName) — \(url.absoluteString)"
                } else {
                    answerActionResult = "Done — \(destinationName) accepted it."
                }
            }
        } catch {
            lastError = "\(pending.action.title): не удалось — \(error.localizedDescription)"
        }
    }

    /// Invoke either the deterministic fake or the unchanged live MCP path.
    /// The request is captured only after the confirmation edits have been
    /// folded into `pendingAnswerAction`.
    private func dispatchAnswerAction(
        _ request: AnswerActionDispatchRequest,
        liveConnection: (
            manager: MCPConnectionManager,
            server: MCPServerDescriptor,
            scope: UInt64
        )?
    ) async throws -> String {
        // Re-check immediately before every side effect. In a per-item commit,
        // the first network await gives Settings/account actions a chance to
        // interleave; a scope change must stop item two rather than write it to
        // another account.
        if let liveConnection {
            try liveConnection.manager.requireReviewedConnection(
                liveConnection.server,
                scope: liveConnection.scope,
                acceptsOverrideTransport: answerActionDispatcher != nil)
        }
        if let answerActionDispatcher {
            return try await answerActionDispatcher.dispatch(request)
        }
        guard let liveConnection else {
            throw MCPConnectionError.notConnected(request.action.serverName, nil)
        }

        switch request.payload {
        case .trackerItem(let item):
            return try await liveConnection.manager.createTrackerItem(
                item,
                on: liveConnection.server,
                requiredConnectionScope: liveConnection.scope)

        case .fields(let fields):
            let tool = liveConnection.manager.tools(for: liveConnection.server.id)
                .first { $0.name == request.action.toolName }
            let arguments: [String: Value]
            if let tool, tool.hasArgument("pages") {
                // Hosted Notion nests the payload under `pages`; flat
                // key=value args fail its "one supported parameter set"
                // validation. NotionExport owns that shape.
                arguments = NotionExport.arguments(
                    title: fields["title"] ?? answerActionTitle(),
                    content: fields["content"] ?? aiResponse,
                    tool: tool) ?? [:]
            } else {
                arguments = fields.reduce(into: [String: Value]()) { result, entry in
                    guard !entry.value.isEmpty else { return }
                    result[entry.key] = .string(entry.value)
                }
            }
            return try await liveConnection.manager.callToolText(
                server: liveConnection.server,
                tool: request.action.toolName,
                arguments: arguments,
                requiredConnectionScope: liveConnection.scope)
        }
    }

    /// The payload the sheet shows. A proposed action carries the model's own
    /// arguments; a matched chip derives them from the answer.
    private func stagedFields(for action: AnswerActionPlanner.Action,
                              tool: Tool,
                              items: [TasksArtifact.Item]) -> [String: String] {
        if action.isProposed, let proposed = proposedArguments[action.id] {
            return proposed
        }
        if !items.isEmpty {
            // Per-item filing has no single payload — the sheet lists the items.
            return [:]
        }
        // Hosted Notion's nested `pages` schema exposes no flat keys — stage
        // pseudo-fields the commit path folds into the nested shape, so the
        // confirm sheet still shows an editable title and body.
        if tool.hasArgument("pages") {
            return ["title": answerActionTitle(), "content": aiResponse]
        }
        var fields: [String: String] = [:]
        if let titleKey = tool.stringArgumentKey(preferring: AnswerActionPlanner.titleKeys) {
            fields[titleKey] = answerActionTitle()
        }
        for key in AnswerActionPlanner.bodyKeys where tool.hasArgument(key) {
            fields[key] = aiResponse
            break
        }
        return fields
    }

    func dismissAnswerActionResult() {
        answerActionResult = nil
    }

    /// Arguments for a chip, resolved against the tool's live schema so a server
    /// that names its fields differently still gets a valid call.
    private func answerActionPayload(for action: AnswerActionPlanner.Action) -> [String: Value] {
        let title = answerActionTitle()
        let body = aiResponse
        guard let mcp,
              let tool = mcp.tools(for: action.serverID).first(where: { $0.name == action.toolName }) else {
            return [:]
        }
        var arguments: [String: Value] = [:]
        if let titleKey = tool.stringArgumentKey(preferring: ["title", "summary", "name", "subject"]) {
            arguments[titleKey] = .string(title)
        }
        for key in ["description", "body", "content", "text", "message", "details"] where tool.hasArgument(key) {
            arguments[key] = .string(body)
            break
        }
        return arguments
    }

    /// A short title for whatever is being filed: the meeting title, else the
    /// request that produced the answer.
    private func answerActionTitle() -> String {
        let meeting = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meeting.isEmpty { return meeting }
        let prompt = aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? "From a Cruxwing meeting" : String(prompt.prefix(120))
    }

    // MARK: - Save the answer as a document

    /// Turning an answer into a document the user keeps.
    ///
    /// Kept separate from the connected-app action chips: those ACT in a system
    /// (file a ticket, log a deal), these just save what is already on screen.
    /// Mixing them would put an irreversible CRM write next to "save a Word
    /// file", which are not the same kind of decision.
    enum DocumentExport: String, Identifiable, CaseIterable {
        case googleDoc
        case notionPage
        case wordFile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .googleDoc:  return "Google Doc"
            case .notionPage: return "Notion page"
            case .wordFile:   return "Word file"
            }
        }

        var systemImage: String {
            switch self {
            case .googleDoc:  return "doc.richtext"
            case .notionPage: return "note.text"
            case .wordFile:   return "doc.text"
            }
        }
    }

    /// Which document exports are actually usable right now. A Word file needs
    /// nothing; the other two need their connection, and an offer that leads to
    /// "connect X first" is an advert, not an action.
    var availableDocumentExports: [DocumentExport] {
        var available: [DocumentExport] = []
        if googleHasDocsScope { available.append(.googleDoc) }
        if mcp?.canExportToNotion == true { available.append(.notionPage) }
        available.append(.wordFile)
        return available
    }

    @Published private(set) var runningDocumentExport: DocumentExport?

    func runDocumentExport(_ kind: DocumentExport) async {
        guard runningDocumentExport == nil else { return }
        runningDocumentExport = kind
        defer { runningDocumentExport = nil }

        switch kind {
        case .googleDoc:
            await exportAssistantAnswerToGoogleDocs()
        case .notionPage:
            await exportAssistantAnswerToNotion()
        case .wordFile:
            await exportAssistantAnswerAsWordFile()
        }
    }

    /// Word export: build the document, then let the user choose where it goes.
    /// The save panel is presented here rather than in the view so every export
    /// route shares one failure path.
    private func exportAssistantAnswerAsWordFile() async {
        do {
            let document = try await prepareCurrentAnswerExport()
            let data = try AssistantDOCXExporter.makeDocument(document)
            let suggested = AssistantDOCXExporter.suggestedFilename(
                for: document.title, date: document.exportedAt)

            let panel = NSSavePanel()
            panel.title = "Выгрузить ответ ассистента"
            panel.message = "Сохранит в документ Word ответ, исходный запрос, слепые зоны и заголовок, придуманный моделью."
            panel.prompt = "Выгрузить"
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let docx = UTType(filenameExtension: "docx") {
                panel.allowedContentTypes = [docx]
            }
            panel.nameFieldStringValue = suggested.lowercased().hasSuffix(".docx")
                ? suggested
                : suggested + ".docx"

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            answerActionResult = "Saved \(url.lastPathComponent)."
        } catch {
            lastError = "Выгрузка в Word не удалась: \(error.localizedDescription)"
        }
    }

    // MARK: - Transcript selection

    /// Text pushed into the ask composer from elsewhere in the UI. The composer
    /// owns its field as local state, so this is the one-way channel that lets a
    /// transcript selection (or anything else) prefill it. Consumed on read.
    @Published var composerDraft: String?

    /// The transcript text the user currently has highlighted, already
    /// attributed with speaker and timestamp by `TranscriptTextRenderer`.
    ///
    /// Character-level, from a real `NSTextView` selection — highlighting six
    /// words quotes six words, not the whole utterance they sit in.
    @Published var selectedTranscriptQuote: String = ""

    var hasTranscriptSelection: Bool { !selectedTranscriptQuote.isEmpty }

    func updateTranscriptSelection(_ quote: String) {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedTranscriptQuote != trimmed { selectedTranscriptQuote = trimmed }
    }

    func clearTranscriptSelection() {
        selectedTranscriptQuote = ""
    }

    /// Load the selection into the composer as a quote, leaving the cursor for
    /// the user's actual question. The prompt is NOT sent — asking "what about
    /// it?" is the user's half, and auto-sending would guess it for them.
    func askAboutTranscriptSelection() {
        let quote = selectedTranscriptQuote
        guard !quote.isEmpty else { return }
        composerDraft = "About this part of the call:\n\"\"\"\n\(quote)\n\"\"\"\n\n"
    }

    // MARK: - Prompt dictation

    /// Start of the window whose live transcript becomes the prompt. Non-nil
    /// only while capturing from an in-progress call.
    @Published private(set) var dictationWindowStart: Date?

    /// True while the composer is capturing, by either route.
    var isDictating: Bool { dictation.isListening || dictationWindowStart != nil }

    /// Toggle dictation for the composer. Appends to whatever is already typed
    /// rather than replacing it, so speaking after typing extends the prompt
    /// instead of destroying it.
    ///
    /// Two routes, because during a call the microphone is already committed to
    /// the recorder:
    ///
    ///   not recording — its own capture (`PromptDictation`)
    ///   recording     — marks a window and takes what the live transcript
    ///                   produced in it
    ///
    /// The recording route is the better one where it applies: it costs no
    /// second capture, cannot disturb the meeting's input node, and picks up
    /// SYSTEM audio as well as the microphone — so "what they just said" can
    /// become the prompt, which a private mic capture could never hear.
    func toggleDictation(into text: Binding<String>) async {
        if isRecording {
            toggleCallDictation(into: text)
            return
        }
        if dictation.isListening {
            guard let spoken = await dictation.stopAndTranscribe() else {
                if case .failed(let reason) = dictation.state {
                    lastError = "Диктовка не удалась — \(reason)"
                    dictation.clearError()
                }
                return
            }
            appendToComposer(spoken, into: text)
            return
        }
        do {
            try dictation.start()
        } catch {
            lastError = "Не удалось начать диктовку — \(error.localizedDescription)"
        }
    }

    /// Window capture against the live transcript. Includes both sources, so a
    /// question can quote what the other side just said.
    private func toggleCallDictation(into text: Binding<String>) {
        guard let start = dictationWindowStart else {
            dictationWindowStart = Date()
            return
        }
        dictationWindowStart = nil
        let spoken = spokenSinceWindow(start: start)
        guard !spoken.isEmpty else {
            lastError = "За это время ничего не расшифровано."
            return
        }
        appendToComposer(spoken, into: text)
    }

    /// Everything finalized inside the window, plus whatever is still in flight
    /// when the user stops — otherwise the last sentence, the one they were
    /// mid-way through when they hit stop, is the one that goes missing.
    private func spokenSinceWindow(start: Date) -> String {
        var parts = transcript
            .filter { $0.timestamp >= start }
            .map(\.text)
        parts.append(contentsOf: provisionalLines.map(\.text))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func appendToComposer(_ spoken: String, into text: Binding<String>) {
        let existing = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        text.wrappedValue = existing.isEmpty ? spoken : existing + " " + spoken
    }

    // MARK: - Clarifying questions

    /// True when a clarification card could be answered at all. Mid-call the
    /// user is talking, not reading — a question they cannot answer is strictly
    /// worse than an answer built on a guess, so the whole feature stands down
    /// while recording.
    private var clarificationAllowed: Bool {
        Config.clarifyingQuestionsEnabled && !isRecording && pendingClarification == nil
    }

    /// A clarification is part of one accepted composer turn, never global UI.
    /// A later message synchronously invalidates it so a late non-cooperative
    /// assessment cannot publish a card and an old card cannot launch its prompt.
    private func supersedePendingClarification() {
        clarifyingTask?.cancel()
        clarifyingTask = nil
        clarifying = false
        pendingClarification = nil
    }

    /// Tier 0: countable ambiguity, resolved with no model call. Returns nil
    /// when there is nothing to count.
    private func tierZeroClarification(for prompt: String) -> [ClarifyingQuestion]? {
        let candidates = ClarificationPlanner.Candidates(
            documents: allContextFiles.map(\.name),
            trackers: mcp?.writebackTargets().map(\.name) ?? []
        )
        guard !candidates.isEmpty else { return nil }
        let questions = ClarificationPlanner.plan(prompt: prompt, candidates: candidates)
        return questions.isEmpty ? nil : questions
    }

    /// Tier 2: one fast-model pass carrying the routed skill and whatever the
    /// grounding cache already holds. Falls through to a normal run on any
    /// outcome other than "here are questions worth asking".
    private func beginClarificationAssessment(prompt: String, images: [Data]) {
        clarifyingTask?.cancel()
        clarifying = true
        let goal = effectiveCallGoal
        let transcript = promptTranscript(cap: 1_500)
        let skillGuidance = BundledSkillRouter.guidance(
            for: nil, query: bundledSkillQuery(extra: prompt))
        // Only already-cached grounding: this pass must not trigger network
        // fetches of its own, or "should I ask?" costs more than answering.
        let grounding = cachedGroundingDigest()
        let model = LLMCatalog.background(for: Config.selectedModel)

        clarifyingTask = Task { [weak self] in
            guard let self else { return }
            let questions = await ClarificationService.assess(
                prompt: prompt, goal: goal, transcript: transcript,
                grounding: grounding, skillGuidance: skillGuidance,
                model: model, gateway: self.llm)
            guard !Task.isCancelled else { return }
            self.clarifying = false
            // A recording that started while the assessment was in flight makes
            // the card unanswerable — answer instead of interrupting.
            guard !questions.isEmpty, !self.isRecording else {
                self.run(prompt: prompt, images: images)
                return
            }
            self.pendingClarification = PendingClarification(
                prompt: prompt, images: images, questions: questions)
        }
    }

    /// The user answered (or partially answered) the card: fold the choices into
    /// the prompt and run it as an ordinary request.
    func resolveClarification(_ answers: [ClarificationAnswer]) {
        guard let pending = pendingClarification else { return }
        pendingClarification = nil
        let prompt = ClarificationService.fold(
            prompt: pending.prompt, questions: pending.questions, answers: answers)
        run(prompt: prompt, images: pending.images)
    }

    /// The user dismissed the card: answer the original prompt as asked. Never a
    /// dead end — skipping must always still produce the answer they wanted.
    func skipClarification() {
        guard let pending = pendingClarification else { return }
        pendingClarification = nil
        run(prompt: pending.prompt, images: pending.images)
    }

    /// Grounding already in the cache, rendered for the assessment prompt. Never
    /// fetches: an empty result simply means tier 2 reasons without app context.
    private func cachedGroundingDigest() -> String {
        let snippets = groundingCache.values
            .filter { Date().timeIntervalSince($0.at) < Self.groundingTTL }
            .flatMap(\.snippets)
        guard !snippets.isEmpty else { return "" }
        return PromptWorkflows.renderGrounding(Array(snippets.prefix(8)))
    }

    func saveCustomPrompt(_ prompt: QuickPrompt) {
        if let idx = customPrompts.firstIndex(where: { $0.id == prompt.id }) {
            customPrompts[idx] = prompt
        } else {
            customPrompts.append(prompt)
        }
        // Use the same capability matcher as connection success immediately,
        // so a freshly added or edited button gets a usable workflow before its
        // first press.
        rebuildPromptWorkflows()
    }

    func deleteCustomPrompt(id: String) {
        customPrompts.removeAll { $0.id == id }
        designedPromptWorkflows[id] = nil
        promptWorkflowSources[id] = nil
    }

    /// The structured-button pipeline (A6): grounding → typed JSON draft →
    /// deterministic validation → targeted repair (fast model, only when
    /// violations exist) → mechanical downgrade for whatever still fails —
    /// unverifiable quotes get dropped, ungrounded owners get flagged, never
    /// fabricated. Renders as markdown with an honest validation footer.
    func runStructuredButton(promptID: String, kind: StructuredButtonService.Kind,
                             originatingPrompt: String? = nil) {
        let promptedAt = Date()
        let modelSnapshot = Config.selectedRequestModel
        let selectionSnapshot = modelSnapshot.requestSelectionID ?? modelSnapshot.id
        supersedeActiveAI(status: .superseded, at: promptedAt)
        beginAssistantAnswer(
            prompt: originatingPrompt ?? "Produce the \(promptID) artifact from this conversation.",
            promptID: promptID, promptedAt: promptedAt,
            modelSelectionID: selectionSnapshot)
        let runGeneration = aiRunGeneration
        followUpTask?.cancel()
        // Cleared with the same reasoning as the actions below: the archived
        // exchange keeps its own chips and renders them itself, so carrying
        // them into the next answer only made two answers show an identical
        // row. Per answer, not global.
        if !followUpPrompts.isEmpty { carriedFollowUpPrompts = followUpPrompts }
        followUpPrompts = []
        // Cleared here on purpose: these belong to the answer being replaced,
        // and archiveLiveExchange above has just stored them ON that exchange,
        // which is where they stay visible. Every answer shows its OWN buttons.
        answerActions = []
        answerActionResult = nil
        aiResponse = ""
        aiStreaming = true
        aiStage = nil
        UsageTracker.recordAIRequest()
        refreshTier()
        let promptTail = promptTranscript(cap: 12_000)
        let rawTranscript = transcriptText   // validation runs against the FULL raw transcript
        let query = PromptWorkflows.groundingQuery(goal: effectiveCallGoal, recentTranscript: rawTranscript)
        let context = promptContext(
            query: (originatingPrompt ?? promptID) + "\n" + query)
        let workflow = designedWorkflow(for: promptID)
        let repairModel = LLMCatalog.background(for: modelSnapshot)
        installPromptWorkflowPlan(
            workflow: workflow,
            composition: "Draft structured answer",
            validation: "Validate against transcript",
            aiReview: (
                "Repair validation issues",
                workflowAIApp(for: repairModel),
                repairModel.id))
        let themeGuidance = activeCallTheme.guidance
        let roleGuidance = RoleSkillMatrix.guidance(roleID: userRoleID, promptID: promptID)
        let promptGuidance = PromptSkills.guidance(for: promptID)
        let skillQuery = bundledSkillQuery(extra: query)

        aiTask = Task { [weak self] in
            guard let self else { return }
            var latestGroundedContext = context
            do {
                // Summary/task buttons can be the first interaction after
                // launch. Route their large bundled-skill catalog on the same
                // serial off-main lane as ordinary prompts so playback,
                // transcription, and overlays remain responsive during warmup.
                let bundledGuidance = await BundledSkillGuidanceWorker.shared.resolve(
                    promptID: promptID, query: skillQuery)
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                let layers = [themeGuidance, roleGuidance, promptGuidance, bundledGuidance]
                    .compactMap { $0 }
                let extraGuidance = layers.isEmpty
                    ? nil
                    : layers.joined(separator: "\n\n")

                // Stage 1 — grounding (trackers/transcripts/ledger per spec).
                var groundedContext = context
                if let workflow, !query.isEmpty {
                    let snippets = await self.groundingSnippets(
                        for: workflow, promptID: promptID, query: query,
                        runGeneration: runGeneration)
                    if !snippets.isEmpty {
                        let block = PromptWorkflows.renderGrounding(snippets)
                        groundedContext = context.isEmpty ? block : context + "\n\n" + block
                    }
                }
                latestGroundedContext = groundedContext
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }

                // Stage 2 — typed draft.
                self.aiStage = "Draft structured answer"
                var artifact = try await StructuredButtonService.draft(
                    kind: kind, transcript: promptTail, context: groundedContext,
                    extraGuidance: extraGuidance, model: modelSnapshot)
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }

                // Stage 3 — deterministic gate → targeted repair → downgrade.
                self.aiStage = "Validate against transcript"
                var violations = self.validate(artifact, transcript: rawTranscript)
                var repaired = false
                if !violations.isEmpty {
                    try Task.checkCancellation()
                    self.updateWorkflowStep(
                        appID: self.workflowLocalApp.id,
                        label: "Validate against transcript",
                        status: .succeeded,
                        detail: "Found \(violations.count) issue\(violations.count == 1 ? "" : "s")")
                    self.aiStage = "Repair validation issues"
                    self.updateWorkflowStep(
                        appID: self.workflowAIApp(for: repairModel).id,
                        label: "Repair validation issues",
                        status: .running,
                        detail: "Requesting a targeted repair")
                    let fixed = await StructuredButtonService.repair(
                        kind: kind, artifact: artifact, violations: violations,
                        transcript: rawTranscript, model: repairModel)
                    guard self.aiRunGeneration == runGeneration, !Task.isCancelled else { return }
                    if let fixed {
                        artifact = fixed
                        repaired = true
                        violations = self.validate(artifact, transcript: rawTranscript)
                        self.updateWorkflowStep(
                            appID: self.workflowAIApp(for: repairModel).id,
                            label: "Repair validation issues",
                            status: .succeeded,
                            detail: "Repair returned")
                    } else {
                        self.updateWorkflowStep(
                            appID: self.workflowAIApp(for: repairModel).id,
                            label: "Repair validation issues",
                            status: .failed,
                            detail: "No usable repair; applying safe local downgrade")
                    }
                } else {
                    self.updateWorkflowStep(
                        appID: self.workflowLocalApp.id,
                        label: "Validate against transcript",
                        status: .succeeded,
                        detail: "Draft passed")
                }
                var downgraded = 0
                if !violations.isEmpty {
                    downgraded = violations.count
                    artifact = self.downgrade(artifact, transcript: rawTranscript)
                    self.updateWorkflowStep(
                        appID: self.workflowLocalApp.id,
                        label: "Validate against transcript",
                        status: .succeeded,
                        detail: "Rechecked; \(downgraded) unsafe detail\(downgraded == 1 ? "" : "s") downgraded")
                } else if repaired {
                    self.updateWorkflowStep(
                        appID: self.workflowLocalApp.id,
                        label: "Validate against transcript",
                        status: .succeeded,
                        detail: "Draft and repaired result passed")
                }

                self.lastStructuredArtifact = artifact
                self.aiResponse = artifact.markdown + Self.validationFooter(
                    repaired: repaired, downgraded: downgraded)
            } catch is CancellationError {
                // no-op
            } catch {
                guard self.aiRunGeneration == runGeneration else { return }
                if let index = self.workflowSteps.firstIndex(where: { $0.status == .running }) {
                    self.workflowSteps[index].status = .failed
                    self.workflowSteps[index].detail = "Step failed; no data was written"
                }
                self.aiResponse = self.explain(error)
            }
            guard self.aiRunGeneration == runGeneration else { return }
            await MainActor.run {
                self.aiStreaming = false
                self.aiStage = nil
                if !self.isRecording { self.persistCurrentSession() }
            }
            guard self.aiRunGeneration == runGeneration else { return }
            self.scheduleFollowUps(request: "Produce the \(promptID) artifact.",
                                   material: latestGroundedContext,
                                   output: self.aiResponse)
        }
    }

    private func validate(_ artifact: StructuredArtifact, transcript: String) -> [ArtifactValidator.Violation] {
        switch artifact {
        case .tasks(let value): return ArtifactValidator.validate(tasks: value, transcript: transcript)
        case .summary(let value): return ArtifactValidator.validate(summary: value, transcript: transcript)
        }
    }

    private func downgrade(_ artifact: StructuredArtifact, transcript: String) -> StructuredArtifact {
        switch artifact {
        case .tasks(let value): return .tasks(ArtifactValidator.downgrade(tasks: value, transcript: transcript))
        case .summary(let value): return .summary(ArtifactValidator.downgrade(summary: value, transcript: transcript))
        }
    }

    private static func validationFooter(repaired: Bool, downgraded: Int) -> String {
        if downgraded > 0 {
            return "\n\n_⚠️ Понижено подробностей без опоры в расшифровке: \(downgraded). Цитата снята._"
        }
        if repaired {
            return "\n\n_✓ Сверено с расшифровкой (после одной правки)._"
        }
        return "\n\n_✓ Сверено с расшифровкой._"
    }

    /// The per-button pipeline: (1) ground from the button's connected work-apps
    /// (PromptWorkflow — zero-cost when nothing relevant is connected), (2)
    /// stream the skilled draft, (3) for anti-fabrication buttons run a refine
    /// audit over the draft and replace it with the corrected final.
    private func run(prompt: String, images: [Data], skill: String? = nil, promptID: String? = nil) {
        let promptedAt = Date()
        let prompt = applyingSocraticMode(to: prompt, promptID: promptID)
        // After the prompt is built — promptTranscript() has already read the
        // flag by this point, so clearing earlier would silently drop the mode
        // on the very request that asked for it.
        defer { spendFullContextRequest() }
        // Capture the complete picker policy before lifecycle setup. Grounding
        // and skill discovery can suspend for seconds; a Settings change during
        // either must apply only to the next request.
        let modelSnapshot = Config.selectedRequestModel
        let selectionSnapshot = modelSnapshot.requestSelectionID ?? modelSnapshot.id
        supersedeActiveAI(status: .superseded, at: promptedAt)
        beginAssistantAnswer(
            prompt: prompt, promptID: promptID ?? "freeform", promptedAt: promptedAt,
            modelSelectionID: selectionSnapshot)
        let runGeneration = aiRunGeneration
        // Generated follow-up prompts are ephemeral; resolve their inferred
        // workflow before clearing the previous run's follow-up chips.
        let resolvedWorkflow = promptID.flatMap { designedWorkflow(for: $0) }
        followUpTask?.cancel()
        // Cleared with the same reasoning as the actions below: the archived
        // exchange keeps its own chips and renders them itself, so carrying
        // them into the next answer only made two answers show an identical
        // row. Per answer, not global.
        if !followUpPrompts.isEmpty { carriedFollowUpPrompts = followUpPrompts }
        followUpPrompts = []
        // Cleared here on purpose: these belong to the answer being replaced,
        // and archiveLiveExchange above has just stored them ON that exchange,
        // which is where they stay visible. Every answer shows its OWN buttons.
        answerActions = []
        answerActionResult = nil
        aiResponse = ""
        aiStreaming = true
        aiStage = nil
        // Behaviour signal: an AI request. May promote the plan.
        UsageTracker.recordAIRequest()
        refreshTier()
        let snapshot = transcript
        var context = promptContext(
            query: prompt + "\n" + effectiveCallGoal)
        // Cross-meeting recall (roadmap F1) считается ниже, внутри `aiTask`, и
        // НЕ на главном акторе.
        //
        // Здесь он стоял синхронно, а `AppState` — `@MainActor`: каждый вопрос
        // «что мы решили…» читал с диска все сохранённые звонки и считал по ним
        // эмбеддинги, пока интерфейс стоял. Собственный замер приложения даёт
        // 2.26 с на 250 звонках — столько окно и не отвечало, причём ровно в тот
        // момент, когда человек только что задал вопрос на звонке.
        let recallStore = sessionStore
        // Layer the system prompt: base + call theme + role + distilled button
        // skill + capped open-source SKILL.md methodology.
        let themeGuidance = activeCallTheme.guidance
        let roleGuidance = RoleSkillMatrix.guidance(roleID: userRoleID, promptID: promptID)
        let skillQuery = bundledSkillQuery(extra: [promptID, prompt].compactMap { $0 }.joined(separator: " "))
        // ...and HOW to produce it for the model actually running: the shared
        // prompt says what the answer must contain, this says how that lands on
        // a compact vs a deliberating model, and on this provider.
        let styleGuidance = ModelPromptStyle.guidance(for: modelSnapshot)
        let workflow = resolvedWorkflow
        let query = PromptWorkflows.groundingQuery(goal: effectiveCallGoal, recentTranscript: transcriptText)
        let digest = callDigest
        let auditModel = LLMCatalog.fastAudit(for: modelSnapshot).snapshottingSelection()
        installPromptWorkflowPlan(
            workflow: workflow,
            composition: "Compose the answer",
            aiReview: workflow?.refine == nil ? nil : (
                "Audit against transcript",
                workflowAIApp(for: auditModel),
                auditModel.id))

        aiTask = Task { [weak self] in
            guard let self else { return }
            var latestGroundedContext = context
            var deltaPump: Task<Void, Never>?
            defer { deltaPump?.cancel() }
            do {
                // Кросс-встречный поиск: отдельной оторванной задачей, чтобы
                // чтение всех звонков и эмбеддинги шли не на главном акторе.
                // `Task { }` тут не годится — созданная в @MainActor-контексте,
                // она наследует его изоляцию и точно так же держала бы окно.
                let recallBlock = await Task.detached(priority: .userInitiated) {
                    DecisionRecallContext.block(for: prompt, store: recallStore)
                }.value
                let context = recallBlock.map { $0 + "\n\n" + context } ?? context

                // Stage 1 — button-specific grounding from connected apps.
                var groundedContext = context
                if let workflow, let promptID, !query.isEmpty {
                    let snippets = await self.groundingSnippets(
                        for: workflow, promptID: promptID, query: query,
                        runGeneration: runGeneration)
                    if !snippets.isEmpty {
                        let block = PromptWorkflows.renderGrounding(snippets)
                        groundedContext = context.isEmpty ? block : context + "\n\n" + block
                    }
                }
                latestGroundedContext = groundedContext
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                // First-load file discovery/relevance ranking must not occupy
                // MainActor. The worker is serial so superseded prompt bursts
                // cannot launch a CPU-heavy detached scan per click.
                let bundledGuidance = await BundledSkillGuidanceWorker.shared.resolve(
                    promptID: promptID, query: skillQuery)
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                let systemPrompt = SystemInstructions.system(
                    skills: [themeGuidance, roleGuidance, skill, bundledGuidance, styleGuidance])
                // A visible "Composing" step so every run — including a free-text /
                // custom prompt that skips grounding — shows at least one workflow
                // step. The streamed answer below IS this step's live output.
                self.aiStage = "Compose the answer"

                // Stage 2 — skilled draft, streamed to the UI. On long calls
                // the digest keeps early decisions in the prompt (A2).
                // Split where a cache breakpoint belongs: the recording type and
                // the attached context do not change between passes of a call,
                // the transcript and the request do. Providers without explicit
                // caching receive the two halves joined, byte for byte.
                let messageParts = SystemInstructions.buildUserMessageParts(
                    transcript: snapshot,
                    additionalContext: groundedContext,
                    prompt: prompt,
                    digest: digest,
                    recordingContext: self.effectiveRecordingContextGuidance
                )
                let userMessage = messageParts.stable + messageParts.volatile
                let inputTokens = TokenEstimate.tokens(
                    systemPrompt.count + userMessage.count)
                self.devCallDiagnostics.record(event: "assistant_request", fields: [
                    "exchangeID": self.aiResponseID?.uuidString ?? "",
                    "phase": "draft",
                    "requestBody": [
                        "model": modelSnapshot.id,
                        "selection": selectionSnapshot,
                        "provider": modelSnapshot.provider.rawValue,
                        "system": systemPrompt,
                        "user": userMessage,
                        "imageCount": images.count,
                        "maxOutputTokens": OutputTokenBudget.explicitUserFacing,
                    ],
                    "estimatedInputTokens": inputTokens,
                    "estimatedCredits": CreditCostEstimate.credits(
                        model: modelSnapshot.id,
                        inputTokens: inputTokens,
                        imageCount: images.count,
                        maxOutputTokens: OutputTokenBudget.explicitUserFacing),
                    "gateway": Config.llmViaBackend ? "managed_backend"
                        : Config.llmViaEnsemble ? "ensemble" : "direct",
                ])
                let deltaBuffer = AIStreamDeltaBuffer()
                deltaPump = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(
                                AIStreamDeltaBuffer.publishInterval * 1_000_000_000))
                        } catch {
                            return
                        }
                        guard let self, self.aiRunGeneration == runGeneration else { return }
                        let batch = deltaBuffer.drain()
                        if !batch.isEmpty { self.aiResponse += batch }
                    }
                }
                let draft = try await self.llm.streamChat(
                    system: systemPrompt,
                    cachedPrefix: messageParts.stable,
                    volatileSuffix: messageParts.volatile,
                    images: images,
                    model: modelSnapshot,
                    maxOutputTokens: OutputTokenBudget.explicitUserFacing,
                    // Every estimate above this line is a character count
                    // divided by four. This is what the provider actually
                    // billed — and the only way to tell a cache breakpoint that
                    // worked from one the API silently ignored.
                    onUsage: { [weak self] usage in
                        Task { @MainActor in
                            self?.devCallDiagnostics.record(
                                event: "assistant_usage",
                                fields: [
                                    "phase": "draft",
                                    "inputTokens": usage.inputTokens,
                                    "outputTokens": usage.outputTokens,
                                    "cacheCreationTokens": usage.cacheCreationTokens,
                                    "cacheReadTokens": usage.cacheReadTokens,
                                    "cacheHitRate": usage.cacheHitRate,
                                ])
                        }
                    }
                ) { delta in
                    deltaBuffer.append(delta)
                }
                deltaPump?.cancel()
                deltaPump = nil
                try Task.checkCancellation()
                guard self.aiRunGeneration == runGeneration else { return }
                // Prefer the provider's aggregate when present. Some valid SSE
                // gateways have emitted all deltas but returned an empty
                // aggregate; preserve that callback stream instead of erasing
                // the answer. If neither channel contains text, treat the 2xx
                // as an invalid response so the dialog ends with a visible,
                // actionable error rather than a successful blank workflow.
                let streamed = deltaBuffer.completeText()
                _ = deltaBuffer.drain()
                let returned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                let streamedTrimmed = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                let terminalAnswer: String
                if !returned.isEmpty {
                    terminalAnswer = draft
                } else if !streamedTrimmed.isEmpty {
                    terminalAnswer = streamed
                } else {
                    throw LLMError.badResponse(modelSnapshot.provider.label)
                }
                if self.aiResponse != terminalAnswer { self.aiResponse = terminalAnswer }

                // Stage 3 — refine audit (quality-bar re-check against the
                // transcript); replaces the draft only with a non-empty final.
                if let refine = workflow?.refine {
                    try Task.checkCancellation()
                    self.aiStage = "Audit against transcript"
                    // The audit is mechanical checking, not deep reasoning — run
                    // it on the provider's fast tier to halve the added latency.
                    let auditSystem = systemPrompt + "\n\n" + refine
                    let auditUser = userMessage + "\n\nDraft to audit:\n" + terminalAnswer
                    let auditInputTokens = TokenEstimate.tokens(
                        auditSystem.count + auditUser.count)
                    self.devCallDiagnostics.record(event: "assistant_request", fields: [
                        "exchangeID": self.aiResponseID?.uuidString ?? "",
                        "phase": "audit",
                        "requestBody": [
                            "model": auditModel.id,
                            "provider": auditModel.provider.rawValue,
                            "system": auditSystem,
                            "user": auditUser,
                            "imageCount": 0,
                            "maxOutputTokens": OutputTokenBudget.explicitUserFacing,
                        ],
                        "estimatedInputTokens": auditInputTokens,
                        "estimatedCredits": CreditCostEstimate.credits(
                            model: auditModel.id, inputTokens: auditInputTokens,
                            maxOutputTokens: OutputTokenBudget.explicitUserFacing),
                    ])
                    let final = try await self.llm.streamChat(
                        system: auditSystem,
                        user: auditUser,
                        images: [],
                        model: auditModel,
                        maxOutputTokens: OutputTokenBudget.explicitUserFacing
                    ) { _ in }
                    try Task.checkCancellation()
                    guard self.aiRunGeneration == runGeneration else { return }
                    let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self.aiResponse = trimmed }
                }
            } catch is CancellationError {
                // no-op
            } catch {
                guard self.aiRunGeneration == runGeneration else { return }
                if let index = self.workflowSteps.firstIndex(where: { $0.status == .running }) {
                    self.workflowSteps[index].status = .failed
                    self.workflowSteps[index].detail = "Connection or generation failed"
                }
                self.aiResponse = self.explain(error)
            }
            guard self.aiRunGeneration == runGeneration else { return }
            await MainActor.run {
                self.aiStreaming = false
                self.aiStage = nil
                if !self.isRecording { self.persistCurrentSession() }
            }
            // Epilogue — propose what to press next, from everything this run
            // used (request + grounded material + the answer). Cheap, silent.
            guard self.aiRunGeneration == runGeneration else { return }
            self.scheduleFollowUps(request: prompt, material: latestGroundedContext,
                                   output: self.aiResponse, model: modelSnapshot)
        }
    }

    /// One fast-model epilogue call that turns the finished run into up to
    /// three follow-up chips. Silent failure; superseded by the next run.
    private func scheduleFollowUps(request: String, material: String, output: String,
                                   model: LLMModel? = nil) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AnswerFailure.looksLikeFailure(trimmed) else { return }
        // Same moment, but free: the action planner is pure and the tool lists
        // are already cached from each server's handshake.
        refreshAnswerActions()
        let followUpModel = model ?? Config.selectedModel
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            guard let self else { return }
            let raw = try? await self.trackingComputeUsage {
                try await self.llm.streamChat(
                    system: FollowUpService.systemPrompt,
                    user: FollowUpService.userMessage(request: request, material: material, output: trimmed),
                    model: LLMCatalog.fastAudit(for: followUpModel)
                ) { _ in }
            }
            guard !Task.isCancelled else { return }
            let prompts = raw.map(FollowUpService.parse) ?? []
            guard !prompts.isEmpty else {
                // Nothing generated, or the call failed. Put back what the
                // user could see before, rather than leaving an empty row.
                if self.followUpPrompts.isEmpty {
                    self.followUpPrompts = self.carriedFollowUpPrompts
                }
                return
            }
            self.followUpPrompts = prompts
        }
    }

    /// Grounding for one button run: the team's own Decision Ledger (A9) plus
    /// the workflow's connected work-apps, with a stage line and a short cache
    /// so re-pressing a button doesn't re-query every source.
    private func groundingSnippets(for workflow: PromptWorkflow,
                                   promptID: String,
                                   query: String,
                                   runGeneration: Int,
                                   maxSources: Int? = nil,
                                   deriveQuery: Bool = true) async -> [GroundingSnippet] {
        let sourceCap = max(0, maxSources
            ?? GroundingContextPolicy.defaultRetrievalSourceLimit(for: currentTier))
        guard sourceCap > 0 else { return [] }
        let sourceApps = workflowApps(for: workflow)
        let sourceFingerprint = sourceApps.map(\.id).joined(separator: ",")
        let revision = mcp?.capabilityRevision ?? 0
        let canonicalQuery = GroundingContextPolicy.canonicalQuery(query)
        // Keyed on the retrieval SHAPE, not on which button asked. Five
        // background watches routinely ask the same question of the same
        // sources; keying on promptID made each of them miss the others' entry
        // and re-query every connector.
        let key = "\(workflow.groundingShapeKey)|\(canonicalQuery)|\(sourceFingerprint)|\(revision)|\(sourceCap)"
        if let hit = groundingCache[key], Date().timeIntervalSince(hit.at) < Self.groundingTTL {
            if aiRunGeneration == runGeneration {
                finishGroundingTrace(apps: sourceApps, snippets: hit.snippets, cached: true)
            }
            return hit.snippets
        }

        let plannedSourceIDs = Set(sourceApps.map(\.id))
        let reachable = groundApps
            ? (mcp?.researchableServers.filter {
                workflow.servers.contains($0.id) && plannedSourceIDs.contains("mcp:\($0.id)")
            } ?? [])
            : []
        let team = (workflow.includeTeam && groundTeam)
            ? TeamConnectors.configured.filter {
                !isAppMuted(Config.mutedAppID(team: $0.rawValue))
              }
            : []
        let ledgerReady = workflow.includeLedger && groundLedger
            && ledgerSourceAvailable
        let googleServices = Set(sourceApps.compactMap { app -> GoogleService? in
            guard app.id.hasPrefix("google:") else { return nil }
            return GoogleService(rawValue: String(app.id.dropFirst("google:".count)))
        })
        guard !reachable.isEmpty || !team.isEmpty || ledgerReady || !googleServices.isEmpty else {
            return []
        }

        // A4 — precision query: when the button's strategy calls for it (and a
        // search will actually run), distill the live topics / claims from the
        // recent transcript into the search query. Falls back to the broad
        // goal-based `query` when extraction yields nothing.
        var effectiveQuery = query
        let externalSlots = GroundingContextPolicy.sourceSlotPlan(
            totalLimit: sourceCap,
            ledgerResults: ledgerReady ? 1 : 0,
            connectorResults: 0).connectors
        if deriveQuery,
           externalSlots > 0,
           !reachable.isEmpty || !team.isEmpty || !googleServices.isDisjoint(with: [.docs, .sheets, .drive]),
           PromptWorkflows.derivationSystemPrompt(for: workflow.queryStrategy) != nil {
            if aiRunGeneration == runGeneration { aiStage = "Prepare search terms" }
            if let derived = await deriveGroundingQuery(strategy: workflow.queryStrategy) {
                effectiveQuery = derived
            }
            if aiRunGeneration == runGeneration {
                updateWorkflowStep(
                    appID: workflowAIApp.id, label: "Prepare search terms",
                    status: .succeeded,
                    detail: effectiveQuery == query ? "Used the meeting goal" : "Focused on live topics")
            }
        }

        if aiRunGeneration == runGeneration {
            for app in sourceApps {
                updateWorkflowStep(
                    appID: app.id, label: sourceWorkflowLabel(app),
                    status: .running, detail: "Connecting via \(app.kind.displayName)")
            }
        }

        var snippets: [GroundingSnippet] = []
        // Own ledger first — the cheapest, highest-signal continuity source.
        if ledgerReady,
           snippets.count < sourceCap,
           let ledger = await ledgerGroundingSnippet(cap: workflow.maxCharsPerSource) {
            snippets.append(ledger)
        }
        let ledgerResultCount = snippets.count
        let mcpSlots = GroundingContextPolicy.sourceSlotPlan(
            totalLimit: sourceCap,
            ledgerResults: ledgerResultCount,
            connectorResults: 0).connectors
        let beforeMCPCount = snippets.count
        if mcpSlots > 0, let mcp, !reachable.isEmpty || !team.isEmpty {
            snippets += await mcp.groundingSnippets(
                goal: effectiveQuery,
                limitTo: workflow.servers,
                includeTeam: workflow.includeTeam && groundTeam,
                maxCharsPerSource: workflow.maxCharsPerSource,
                maxSources: mcpSlots
            )
        }
        let mcpResultCount = snippets.count - beforeMCPCount
        let googleSlots = GroundingContextPolicy.sourceSlotPlan(
            totalLimit: sourceCap,
            ledgerResults: ledgerResultCount,
            connectorResults: mcpResultCount).google
        if googleSlots > 0, !googleServices.isEmpty {
            let selectedServices = Set(
                googleServices.sorted { $0.rawValue < $1.rawValue }.prefix(googleSlots))
            snippets += await googleGroundingSnippets(
                services: selectedServices, query: effectiveQuery,
                cap: workflow.maxCharsPerSource)
        }
        groundingCache[key] = (Date(), snippets)
        // These snippets were fetched for an answer or a Blind Spot and are
        // already paid for. Extracting glossary candidates from them costs no
        // fetch, no model call and no research cycle, so it runs every time
        // rather than waiting for someone to find the Settings button.
        proposeGlossaryFromConnectedSnippets(snippets)
        if aiRunGeneration == runGeneration {
            finishGroundingTrace(apps: sourceApps, snippets: snippets, cached: false)
        }
        return snippets
    }

    private func finishGroundingTrace(apps: [WorkflowApp],
                                      snippets: [GroundingSnippet],
                                      cached: Bool) {
        for app in apps {
            let matches = snippets.filter { snippet in
                snippet.sourceID == app.id
                    || (snippet.sourceID == nil && snippet.serverName == app.name)
            }
            if matches.isEmpty {
                updateWorkflowStep(
                    appID: app.id, label: sourceWorkflowLabel(app),
                    status: .skipped, detail: "No usable result; workflow continued")
            } else {
                let detail = cached
                    ? "Reused recent context"
                    : (matches.count == 1 ? "Context found" : "\(matches.count) results found")
                updateWorkflowStep(
                    appID: app.id, label: sourceWorkflowLabel(app),
                    status: .succeeded, detail: detail,
                    tool: matches.first?.toolName)
            }
        }
    }

    /// One fast-model pass that turns the recent transcript into a sharp search
    /// query (topics or claims, per the button's strategy). nil — too little
    /// transcript, extraction failed, or nothing concrete — means "use the
    /// broad goal query".
    private func deriveGroundingQuery(strategy: PromptWorkflow.QueryStrategy) async -> String? {
        guard let system = PromptWorkflows.derivationSystemPrompt(for: strategy) else { return nil }
        let recent = String(transcriptText.suffix(4_000))
        guard recent.count >= 300 else { return nil }
        let raw = try? await llm.streamChat(
            system: system, user: "Recent transcript:\n\(recent)",
            model: LLMCatalog.fastAudit(for: Config.selectedModel)) { _ in }
        return PromptWorkflows.sanitizeDerivedQuery(raw ?? "")
    }

    /// The team's recent ledger decisions as one grounding snippet — silent nil
    /// when signed out, offline, or the ledger is empty.
    private func ledgerGroundingSnippet(cap: Int) async -> GroundingSnippet? {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let token = await wheesprAccessToken() else { return nil }
        guard let decisions = try? await DecisionLogService.recentDecisions(base: base, token: token),
              !decisions.isEmpty else { return nil }
        let text = DecisionLogService.renderForGrounding(decisions, cap: cap)
        guard !text.isEmpty else { return nil }
        return GroundingSnippet(
            serverName: "Decision Ledger", toolName: "recent-decisions", text: text,
            sourceID: workflowLedgerApp.id)
    }

    /// Direct Google API grounding. Calendar reads the current event; Docs and
    /// Sheets use Drive metadata search followed by their narrow content APIs.
    /// Each service returns its own snippet so the workflow ledger can show an
    /// honest per-app result.
    private func googleGroundingSnippets(services: Set<GoogleService>,
                                         query: String,
                                         cap: Int) async -> [GroundingSnippet] {
        guard googleConnected, !isAppMuted(Config.googleAppID),
              let token = await freshGoogleToken() else { return [] }
        var snippets: [GroundingSnippet] = []

        if services.contains(.calendar),
           let agenda = try? await CalendarService.currentAgenda(
            accessToken: token, excluding: dismissedMeetingIDs) {
            snippets.append(GroundingSnippet(
                serverName: "Google Calendar", toolName: "events.list",
                text: String(agenda.summary.prefix(cap)), sourceID: "google:calendar"))
        }

        for service in [GoogleService.docs, .sheets, .drive] where services.contains(service) {
            guard let documents = try? await GoogleWorkspaceSearchService.search(
                query: query, services: [service], accessToken: token),
                  !documents.isEmpty else { continue }
            let text = documents.map { "## \($0.title)\n\($0.text)" }
                .joined(separator: "\n\n")
            snippets.append(GroundingSnippet(
                serverName: "Google \(service.label)", toolName: "files.list",
                text: String(text.prefix(cap)), sourceID: "google:\(service.rawValue)"))
        }
        return snippets
    }

    private func startRecording() async {
        // Re-check on the actor: two rapid toggles can both enqueue this task
        // before the first flips `status` (TOCTOU) — the loser must bail or we
        // start two SCStream captures.
        guard status != .recording, status != .starting, status != .stopping else { return }
        pendingStartupLocalFallback = nil
        // Invalidate a stopped call's manual/automatic rewrite before any
        // permission or model await. A non-cooperative decoder may finish, but
        // its revision can no longer commit into the new workspace.
        cancelFirefliesEnhance()
        invalidateLocalFinalPassTasks(discardRetainedAudio: true)
        status = .starting
        lastError = nil
        // Recording into a restored call makes it the live workspace again, so
        // the History affordance no longer applies.
        isViewingRestoredSession = false
        // A fresh capture: no stop to be late relative to.
        recordingStoppedAt = nil
        latestStreamingRouteRetiredAt = nil
        // Playback state at the moment capture begins. "I could not hear
        // anything while it was recording" is otherwise unanswerable after the
        // fact — nothing in the capture stack changes playback, so the reading
        // that matters is whether the output device was already muted or turned
        // down. Paired with the stop-side reading below, the two separate "we
        // silenced it" from "it was silent before we started".
        Log.audio.notice("record start — \(AudioRoute.describeOutputLevel(), privacy: .public)")
        FunnelTracker.trackOnce(.firstRecording)   // funnel activation (once/device)

        // --- Microphone ---
        var mic = Permissions.microphone
        if mic == .notDetermined {
            mic = await Permissions.requestMicrophone()
        }
        if mic != .granted {
            let msg = "Нет доступа к микрофону. Откройте «Системные настройки → Конфиденциальность и безопасность → Микрофон», разрешите orakul, потом закройте приложение и откройте заново."
            lastError = msg
            status = .error(msg)
            return
        }

        // --- Screen Recording (ScreenCaptureKit) ---
        // The cached preflight value is only a hint for whether to prompt; it
        // often reports denied even when access is granted. Trigger the
        // first-run prompt when the hint says we lack access, then gate on the
        // authoritative SCShareableContent probe so a stale preflight never
        // blocks a user who has already granted the permission.
        if Permissions.screenRecording != .granted {
            // Triggers the system prompt on first call; on a prior deny the
            // prompt is suppressed and the user has to fix it in Settings.
            _ = Permissions.requestScreenRecording()
        }
        if await Permissions.screenRecordingAuthorized() == false {
            let msg = "Чтобы слышать собеседников, нужна запись экрана. Откройте «Системные настройки → Конфиденциальность и безопасность → Запись экрана», включите orakul, потом закройте приложение и откройте заново. Если orakul уже в списке, но доступа всё равно нет, — уберите его, перезапустите и добавьте снова."
            lastError = msg
            status = .error(msg)
            return
        }

        let chunkSeconds = Config.transcriptionChunkSeconds
        let configuredSettings = RecordingSettingsSnapshot.configured()
        let sessionEngine = publishRecordingBoundaryEngine()
        let sessionSettings = configuredSettings.replacingEngine(with: sessionEngine)
        let sessionLanguage = sessionSettings.language
        let localFinalPassEnabled = Config.transcriptionPostStopFinalPassEnabled
        let serverDiarizationEligible = canDiarizeOnServer
        let retainSessionAudio = Self.shouldRetainSessionAudio(
            engine: sessionEngine,
            hasAssemblyAI: hasAssemblyAI,
            assemblyDiarization: sessionSettings.assemblyDiarization,
            serverDiarization: serverDiarizationEligible,
            localFinalPassEnabled: localFinalPassEnabled,
            localDiarizationEnabled: sessionSettings.localDiarization)
        // Publish the immutable in-flight snapshot before the potentially slow
        // model preparation await. Settings rejects changes during `.starting`
        // so its visible row can never outrun this route.
        activeRecordingSettings = sessionSettings
        await prepareTranscriberForRecording(
            engine: sessionEngine,
            language: sessionLanguage,
            glossary: sessionSettings.glossary,
            localModel: sessionSettings.localModel)
        activeSessionEngine = sessionEngine
        SpeechQualityMonitor.shared.reset()
        speechQualityIsPoor = false
        activeSessionLanguage = sessionLanguage
        let recordingTranscriber = transcriber
        let preparedLocalWhisperModel = sessionEngine == .local
            && recordingTranscriber is LocalWhisperTranscription
            ? sessionSettings.localModel : nil

        // Warm the transcription engine so the first chunk isn't blocked on a
        // silent, unbounded model download — the on-device Whisper model pulls
        // ~150 MB on first use. Streaming/cloud engines have nothing to warm.
        if sessionEngine == .local {
            prepareLocalModel()
        } else {
            transcriptionState = .ready
        }

        // Always clear the previous session's recorded audio first.
        sessionRecorder.reset()
        sessionRetainedAudioStart = nil
        sessionAudioStart = nil
        sessionAudioStartSample = 0
        sessionRetainedAudioTimelineValid = true
        localFinalPassContinuityValid = false
        localDiarizationContinuityValid = false
        localDiarizationOptedInForSession = false
        systemCaptureDiagnostics.reset()
        micCaptureDiagnostics.reset()

        // Callbacks from either engine stay attached to this recording. Stop
        // retags the token once so only a final partial/final websocket result
        // may land; a restore or the next recording advances past it again.
        let recordingGeneration = chunkGeneration &+ 1
        let generationToken = RecordingGenerationToken(recordingGeneration)
        recordingGenerationToken = generationToken

        if sessionEngine == .deepgram, hasDeepgram {
            activeChunkRouteLease = nil
            // resetForNewRecording() advances to this value as soon as capture
            // succeeds. Every socket callback remains bound to that recording.
            startDeepgram(chunkSeconds: chunkSeconds, generationToken: generationToken,
                          language: sessionLanguage,
                          keyterms: sessionSettings.glossaryTerms)
        } else {
            let routeLease = TranscriptionRouteLease()
            activeChunkRouteLease = routeLease
            systemChunker = AudioChunkBuffer(
                chunkSeconds: chunkSeconds, label: "system",
                onChunk: liveChunkHandler(
                    source: .system, transcriber: recordingTranscriber,
                    engine: sessionEngine, generationToken: generationToken,
                    routeLease: routeLease))
            systemChunker?.vadThreshold = VoiceActivity.systemAudioThreshold
            micChunker = AudioChunkBuffer(
                chunkSeconds: chunkSeconds, label: "mic",
                onChunk: liveChunkHandler(
                    source: .mic, transcriber: recordingTranscriber,
                    engine: sessionEngine, generationToken: generationToken,
                    routeLease: routeLease))
        }

        do {
            // Capture the chunkers locally so the audio-thread taps never touch
            // the @MainActor stored properties (data race with the nil-out at
            // stop) — mirrors the Deepgram streamer handling in startDeepgram.
            let systemChunker = systemChunker
            let micChunker = micChunker
            let micLevelUpdateGate = micLevelUpdateGate
            let audioMeter = audioMeter
            let systemCaptureDiagnostics = systemCaptureDiagnostics
            let micCaptureDiagnostics = micCaptureDiagnostics
            try await systemCapture.start { buffer in
                systemCaptureDiagnostics.record(buffer)
                systemChunker?.append(buffer)
            } onStopped: { [weak self] _ in
                // Запись продолжается — микрофон жив, и обрывать сессию из-за
                // половины источников хуже, чем сохранить половину. Но молчать
                // нельзя: без этого человек узнавал бы о потере собеседников из
                // расшифровки, когда звонок уже кончился.
                Task { @MainActor in self?.noteSystemAudioLost() }
            }
            try micCapture.start(
                noiseSuppressionEnabled: sessionSettings.microphoneNoiseSuppression,
                onBuffer: { buffer in
                    micCaptureDiagnostics.record(buffer)
                    micChunker?.append(buffer)
                    guard micLevelUpdateGate.shouldSample() else { return }
                    let level = AudioLevel.rms(buffer)
                    Task { @MainActor in audioMeter.update(level) }
                },
                // Микрофон не вернулся после смены устройства: наушники
                // отключились, USB-микрофон вынули. Запись продолжается —
                // собеседники пишутся, — но своей половины у человека уже нет,
                // и знать об этом он должен сейчас, а не из расшифровки.
                onStopped: { [weak self] _ in
                    Task { @MainActor in self?.noteMicrophoneLost() }
                })
            // Voice-processed audio is 10–30 dB quieter than raw — with the
            // default −42 dBFS gate every chunk got VAD-dropped and the
            // transcript starved. Match the gate to what VP actually outputs.
            micChunker?.vadThreshold = micCapture.voiceProcessingActive
                ? VoiceActivity.voiceProcessedThreshold
                : VoiceActivity.defaultThreshold
            // Fresh meeting — clear the prior transcript so this recording is
            // its own track (not a merge of every un-cleared meeting before it).
            // Runs only after capture actually started, so a failed start keeps
            // the current workspace intact.
            resetForNewRecording()
            let startedAt = Date()
            recordingStartedAt = startedAt
            // `resetForNewRecording` deliberately clears the previous call's
            // model provenance. Republish the model prepared above only after
            // the new capture succeeded, otherwise every ordinary Local call
            // became ineligible for its own final pass.
            activeSessionPreparedLocalWhisperModel = preparedLocalWhisperModel
            localFinalPassOptedInForSession = localFinalPassEnabled
                && sessionEngine == .local
            localDiarizationOptedInForSession = sessionSettings.localDiarization
                && sessionEngine == .local
            serverDiarizationEligibleForSession = serverDiarizationEligible
            // The reset above clears the old recorder and provenance. Attach
            // the new observer afterwards so Local always retains its private
            // remote track for a safe manual/opt-in final pass.
            if retainSessionAudio {
                beginSessionAudioRetention(on: systemChunker, at: startedAt)
            }
            sessionUsedAI = false
            recordingElapsed.start(at: recordingStartedAt ?? Date())
            // Флаг с прошлого звонка не должен встречать следующий.
            systemAudioLostDuringRecording = false
            microphoneLostDuringRecording = false
            status = .recording
            applyPendingStartupLocalFallbackIfNeeded()
            let recordingContextSessionID = currentSessionID
            Task { [weak self] in
                await self?.detectVisibleRecordingContext(for: recordingContextSessionID)
            }
            devCallDiagnostics.beginCall(
                sessionID: currentSessionID.uuidString,
                fields: [
                    "recordingStartedAt": recordingStartedAt?.timeIntervalSince1970 ?? 0,
                    "activeTranscriptionEngine": activeSessionEngine?.rawValue ?? sessionEngine.rawValue,
                    "language": activeSessionLanguage ?? sessionLanguage,
                    "tier": currentTier.rawValue,
                    "selectedModel": Config.selectedModelID,
                    "recordingContextSelection": recordingContextSelection.mode.rawValue,
                    "recordingContext": effectiveRecordingContextLabel,
                    "connectedAppsGrounding": useConnectedAppsInPrompts,
                    "watchSettings": [
                        "blindSpot": blindSpotsEnabled,
                        "agenda": agendaCheckingEnabled,
                        "factCheck": liveFactCheckingEnabled,
                        "rhetoric": rhetoricWatchEnabled,
                        "facilitation": facilitationWatchEnabled,
                    ],
                ])
            copilotActiveTimeMeter.begin(
                enabled: automaticCopilotEnabled,
                at: recordingStartedAt ?? Date())
            if let requested = pendingEngineChange,
               requested != activeSessionEngine,
               let capturedSettings = activeRecordingSettings,
               let capturedEngine = activeSessionEngine {
                if switchActiveTranscriptionEngine(
                    to: requested,
                    replacing: capturedSettings,
                    previousEngine: capturedEngine) {
                    activeSessionEngine = requested
                    activeRecordingSettings = capturedSettings.replacingEngine(with: requested)
                    noteSuccessfulEngineTransition(
                        from: capturedEngine, to: requested)
                    pendingEngineChange = nil
                } else {
                    Config.transcriptionEngineValue = capturedEngine
                    selectedTranscriptionEngine = capturedEngine
                    pendingEngineChange = nil
                    lastError = "Не удалось переключить звонок на «\(requested.advantageTitle)». Он продолжается на «\(capturedEngine.advantageTitle)»."
                }
            } else {
                pendingEngineChange = nil
            }
            startTicking()
            startBrainstorming()
            startAgendaChecking()
            startFactCheckLoop()
            startRhetoricLoop()
            startFacilitationLoop()
            startGoalSuggestion()
            startTitleSuggestion()
            startDigestLoop()
        } catch {
            // Starting system capture can succeed before microphone capture
            // throws. Invalidate callbacks first, then tear down every capture
            // and cloud-streaming resource so an error screen can never mask a
            // still-running recorder or upload socket.
            generationToken.set(recordingGeneration &+ 1)
            chunkGeneration &+= 1
            recordingGenerationToken = nil
            micCapture.stop()
            await systemCapture.stop()
            systemStreamer?.finish()
            micStreamer?.finish()
            systemStreamer = nil
            micStreamer = nil
            systemChunker = nil
            micChunker = nil
            sessionRecorder.reset()
            sessionRetainedAudioStart = nil
            sessionAudioStart = nil
            sessionAudioStartSample = 0
            sessionRetainedAudioTimelineValid = true
            localFinalPassContinuityValid = false
            localFinalPassOptedInForSession = false
            localDiarizationContinuityValid = false
            localDiarizationOptedInForSession = false
            serverDiarizationEligibleForSession = false
            pendingStartupLocalFallback = nil
            recordingStartedAt = nil
            recordingElapsed.stop()
            activeSessionEngine = nil
            activeSessionLanguage = nil
            activeRecordingSettings = nil
            activeSessionPreparedLocalWhisperModel = nil
            copilotActiveTimeMeter.reset()
            stopTicking()
            audioMeter.reset()
            provisional.removeAll()
            let msg = "Не удалось начать запись. \(Self.systemSaid(error))"
            lastError = msg
            status = .error(msg)
        }
    }

    /// The abandonment signal: how far a recording got, and whether it produced
    /// anything. A session that ran twenty minutes and yielded no transcript is
    /// a different failure from one the user stopped after ten seconds, and the
    /// funnel cannot tell them apart without this.
    func reportSessionOutcome(startedAt: Date?) {
        guard let startedAt else { return }
        let bucket = AnalyticsEvent.DurationBucket(
            seconds: Date().timeIntervalSince(startedAt))
        let hadTranscript = !transcript.isEmpty
        analytics(.sessionEnded(duration: bucket,
                                hadTranscript: hadTranscript,
                                usedAI: sessionUsedAI))
        if !hadTranscript { analytics(.recordingAbandoned(after: bucket)) }
    }

    private func stopRecording() async {
        // Settle before changing status: this includes every prior enabled
        // interval even when the final Settings state is OFF, and excludes the
        // disabled prefix when a watch was enabled late in the call.
        let copilotElapsedSeconds = copilotActiveTimeMeter.finish(at: Date())
        status = .stopping
        // Stamp BEFORE any await: the grace window must start at the moment the
        // user pressed Stop, not whenever this task happens to resume.
        recordingStoppedAt = Date()
        let stopBoundary = recordingStoppedAt ?? Date()
        // Close the streaming timestamp epoch before `finish()` can enqueue
        // its last server final. Stop retags the generation below so that final
        // is still accepted, but it must remain on the old route boundary.
        let hadActiveStream = systemStreamer != nil || micStreamer != nil
        if hadActiveStream {
            recordingGenerationToken?.retireStreamingResults(at: stopBoundary)
        }
        latestStreamingRouteRetiredAt = Self.streamedFinalDrainBoundaryAtStop(
            hadActiveStream: hadActiveStream,
            previouslyRetiredAt: latestStreamingRouteRetiredAt,
            stopBoundary: stopBoundary)
        // Capture callbacks queued behind Stop cannot extend retained audio
        // beyond the privacy boundary used by a destructive final pass.
        sessionRecorder.seal()
        // Pairs with the start-side reading: if muted/volume differ across the
        // recording, capture changed playback and the diff says how.
        Log.audio.notice("record stop — \(AudioRoute.describeOutputLevel(), privacy: .public)")
        let remainingAllowance = tariffAllowance.remainingCopilotSeconds(
            usedSeconds: UsageTracker.copilotSecondsThisMonth)
        UsageTracker.recordCopilot(seconds: min(copilotElapsedSeconds, remainingAllowance))
        // Behaviour signal: a real meeting (>= 10s). May promote the plan.
        if let startedAt = recordingStartedAt, Date().timeIntervalSince(startedAt) >= 10 {
            UsageTracker.recordMeeting()
            refreshTier()
            // Ask, once, how the first real call went. It is the only moment
            // somebody can answer that, and the only feedback that comes from a
            // person who actually ran the thing rather than one who merely
            // downloaded it. Gated on the same >= 10s definition of "real" used
            // above, so a mis-click cannot burn the single chance to ask.
            if FirstMeetingPrompt.shouldAsk(meetingsSoFar: UsageTracker.meetings) {
                FirstMeetingPrompt.markAsked()
                showFirstMeetingFeedback = true
            }
        }
        reportSessionOutcome(startedAt: recordingStartedAt)
        micCapture.stop()
        await systemCapture.stop()
        // Stop means stop: invalidate UI delivery immediately and reject the
        // local actor's queued chunks. Otherwise a slow CPU/GPU pipeline can
        // keep consuming resources and append captions minutes after capture.
        chunkGeneration &+= 1
        // Preserve only the final partial mic/system buffers under the fresh
        // generation; everything already dispatched keeps its old value and is
        // invalid. Retag before the await so a trailing Deepgram final cannot
        // fall into a transient generation gap while Stop is yielding.
        recordingGenerationToken?.set(chunkGeneration)
        await transcriber.cancelPendingTranscriptions(beforeGeneration: chunkGeneration)
        // A mid-call handoff may still be draining the previous engine. Stop is
        // the hard privacy/resource boundary for those routes too: invalidate
        // their queues and unload them now, even if a provider ignored the
        // earlier cooperative task cancellation.
        let retired = Array(retiringTranscribers.values)
        retiringTranscribers.removeAll(keepingCapacity: false)
        pendingDeepgramPreviousTranscriber = nil
        pendingDeepgramPreviousRouteLease = nil
        for service in retired where ObjectIdentifier(service) != ObjectIdentifier(transcriber) {
            await service.cancelPendingTranscriptions(beforeGeneration: chunkGeneration)
            await service.shutdown()
        }
        systemChunker?.flush()
        micChunker?.flush()
        // Flush registers final local work synchronously. Snapshot the route
        // before clearing it so opt-in refinement waits for those live rows.
        let stoppedChunkRouteLease = activeChunkRouteLease
        recordingGenerationToken = nil
        activeChunkRouteLease = nil
        systemChunker = nil
        micChunker = nil
        let stoppedSystemStreamer = systemStreamer
        let stoppedMicStreamer = micStreamer
        stoppedSystemStreamer?.finish()
        stoppedMicStreamer?.finish()
        systemStreamer = nil
        micStreamer = nil
        // Final-pass snapshots are destructive rewrite evidence. Do not take
        // one while a flushed Local chunk or a CloseStream final can still add
        // a live row. The UI remains `.stopping`, so manual refinement is not
        // offered during this barrier.
        if let stoppedChunkRouteLease {
            await stoppedChunkRouteLease.waitUntilDrained()
        }
        // This also covers a stream retired just before Stop during an
        // Instant -> Private handoff, when no active streamer remains here.
        let streamDrainDelay = Self.remainingStreamedFinalDrainDelay(
            retiredAt: latestStreamingRouteRetiredAt,
            now: Date())
        if streamDrainDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(
                streamDrainDelay * 1_000_000_000))
        }
        latestStreamingRouteRetiredAt = nil
        stopTicking()
        stopBrainstorming()
        stopAgendaChecking()
        stopFactCheckLoop()
        stopRhetoricLoop()
        stopFacilitationLoop()
        stopGoalSuggestion()
        stopDigestLoop()   // digest content is kept for post-call button runs
        audioMeter.reset()
        provisional.removeAll()
        status = .idle
        reconcileDisplayedTranscriptionEngineIfIdle()
        persistCurrentSession()   // nothing dies on quit (M3)
        devCallDiagnostics.endCall(fields: [
            "recordingStoppedAt": recordingStoppedAt?.timeIntervalSince1970 ?? 0,
            "durationSeconds": recordingStartedAt.map {
                max(0, (recordingStoppedAt ?? Date()).timeIntervalSince($0))
            } ?? 0,
            "transcriptEntries": transcript.count,
            "assistantAttempts": aiExchangeEvidence.count,
            "blindSpotAttempts": blindSpotAttempts,
            "blindSpotSuccesses": blindSpotSuccesses,
        ])

        scheduleAutomaticLocalFinalPass(after: stoppedChunkRouteLease)

        // Speaker labeling is intentionally manual. Even with a configured key,
        // a Local recording is never uploaded to AssemblyAI just because it ended.

        // When Fireflies is connected, merge its cloud transcript with on-device
        // Whisper — but later, and only if Fireflies was actually on this call
        // (opt-out in Settings).
        if Config.firefliesTranscriptEnhanceEnabled,
           mcp?.prefersMCP("fireflies") == true,
           !transcript.isEmpty {
            scheduleFirefliesEnhance()
        }
    }

    /// Wait for Fireflies before asking it anything.
    ///
    /// Running at the instant the call ended asked for a transcript that does
    /// not exist yet: Fireflies still has to leave the meeting, upload and
    /// transcribe it, which takes minutes. The old immediate call therefore
    /// either failed outright or — worse — matched the newest OTHER meeting and
    /// merged a different call's words into this one. So: sleep, then retry on a
    /// widening schedule, and stop at the first successful merge. Every attempt
    /// demands a Fireflies meeting starting within `firefliesMatchWindow` of
    /// this call, so calls Fireflies never joined simply never enhance.
    private static let firefliesEnhanceSchedule: [TimeInterval] = [5 * 60, 5 * 60, 10 * 60, 20 * 60]

    private func scheduleFirefliesEnhance() {
        cancelFirefliesEnhance()
        let sessionID = currentSessionID
        let revision = firefliesMutationRevision
        firefliesEnhanceTask = Task { [weak self] in
            defer {
                if self?.firefliesMutationRevision == revision {
                    self?.firefliesEnhanceTask = nil
                }
            }
            for delay in Self.firefliesEnhanceSchedule {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // The workspace has moved on — a later call, or one recording
                // now. Enhancing would rewrite the wrong meeting's transcript.
                guard self.currentSessionID == sessionID, self.status == .idle else { return }
                if await self.enhanceTranscriptWithFireflies(automatic: true) { return }
            }
        }
    }

    /// Cancels a pending automatic merge — used when the workspace moves on.
    func cancelFirefliesEnhance() {
        firefliesMutationRevision &+= 1
        firefliesEnhanceTask?.cancel()
        firefliesEnhanceTask = nil
        manualFirefliesEnhanceTask?.cancel()
        manualFirefliesEnhanceTask = nil
        firefliesImportTask?.cancel()
        firefliesImportTask = nil
        // Busy flags belong to the revision that set them. Old providers may
        // ignore cancellation, so clear synchronously and make their defers
        // revision-guarded instead of leaving the new workspace stuck.
        firefliesImporting = false
        enhancingTranscript = false
    }

    /// Manual "Enhance with Fireflies" from the transcript toolbar.
    func enhanceTranscriptWithFirefliesNow() {
        guard canEnhanceWithFireflies else { return }
        // An explicit run replaces the pending automatic one; two merges of the
        // same transcript race each other.
        cancelFirefliesEnhance()
        let revision = firefliesMutationRevision
        manualFirefliesEnhanceTask = Task { [weak self] in
            defer {
                if self?.firefliesMutationRevision == revision {
                    self?.manualFirefliesEnhanceTask = nil
                }
            }
            await self?.enhanceTranscriptWithFireflies(automatic: false)
        }
    }

    private struct TranscriptMutationIdentity: Equatable {
        let sessionID: UUID
        let revision: Int
        let firefliesRevision: Int
        let transcript: [TranscriptEntry]
    }

    private func captureTranscriptMutationIdentity() -> TranscriptMutationIdentity {
        TranscriptMutationIdentity(
            sessionID: currentSessionID,
            revision: transcriptRevision,
            firefliesRevision: firefliesMutationRevision,
            transcript: transcript)
    }

    private func matchesTranscriptMutationIdentity(
        _ identity: TranscriptMutationIdentity
    ) -> Bool {
        currentSessionID == identity.sessionID
            && transcriptRevision == identity.revision
            && firefliesMutationRevision == identity.firefliesRevision
            && transcript == identity.transcript
    }

    private func matchesFirefliesMutationIdentity(
        _ identity: TranscriptMutationIdentity
    ) -> Bool {
        status == .idle && matchesTranscriptMutationIdentity(identity)
    }

    private func fetchFirefliesTranscript(
        near: Date?, within: TimeInterval? = nil
    ) async throws -> FirefliesTranscript? {
        if let firefliesTranscriptProvider {
            return try await firefliesTranscriptProvider(near, within)
        }
        guard let mcp else { return nil }
        return try await mcp.firefliesTranscript(near: near, within: within)
    }

    /// Import Fireflies via MCP, attach as context, then reconcile into the
    /// live transcript when Whisper captions exist for this session.
    func importAndEnhanceWithFireflies() async {
        guard firefliesTranscriptProvider != nil || mcp != nil,
              status == .idle,
              !firefliesImporting, !enhancingTranscript,
              !localRetranscribing, !diarizing else { return }
        // One explicit import replaces a pending automatic/manual merge. This
        // advances the revision before we capture the new operation identity.
        cancelFirefliesEnhance()
        let expected = captureTranscriptMutationIdentity()
        let near = recordingStartedAt ?? sessionDate
        firefliesImporting = true
        let revision = expected.firefliesRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFirefliesImport(expected: expected, near: near)
        }
        firefliesImportTask = task
        await task.value
        guard firefliesMutationRevision == revision else { return }
        firefliesImportTask = nil
        firefliesImporting = false
    }

    private func performFirefliesImport(
        expected: TranscriptMutationIdentity,
        near: Date
    ) async {
        guard matchesFirefliesMutationIdentity(expected) else { return }
        do {
            guard let fireflies = try await fetchFirefliesTranscript(near: near),
                  matchesFirefliesMutationIdentity(expected) else { return }
            contextFiles.removeAll {
                $0.name.hasPrefix("Fireflies ·") || $0.name.hasPrefix("Enhanced · Fireflies")
            }
            contextFiles.append(ImportedContextFile(
                name: "Fireflies · \(fireflies.title)",
                text: fireflies.text))
            lastError = nil
            if !transcript.isEmpty {
                enhancingTranscript = true
                await applyFirefliesEnhancement(fireflies, automatic: false)
                if firefliesMutationRevision == expected.firefliesRevision {
                    enhancingTranscript = false
                }
            }
        } catch {
            guard matchesFirefliesMutationIdentity(expected) else { return }
            lastError = error.localizedDescription
        }
    }

    /// Pull Fireflies (matched near session start) and replace `transcript`
    /// with the LLM-reconciled merge. Non-destructive on failure.
    ///
    /// - Returns: whether the merge happened, so the automatic schedule knows to
    ///   stop retrying.
    @discardableResult
    private func enhanceTranscriptWithFireflies(automatic: Bool) async -> Bool {
        guard firefliesTranscriptProvider != nil || mcp != nil else { return false }
        guard status == .idle else { return false }
        guard !enhancingTranscript, !localRetranscribing, !diarizing else { return false }
        guard !transcript.isEmpty else {
            if !automatic { lastError = TranscriptEnhancementError.emptyWhisper.localizedDescription }
            return false
        }
        let expected = captureTranscriptMutationIdentity()
        enhancingTranscript = true
        defer {
            if firefliesMutationRevision == expected.firefliesRevision {
                enhancingTranscript = false
            }
        }
        let near = recordingStartedAt ?? sessionDate
        do {
            // Both paths insist the Fireflies meeting IS this call. A manual run
            // is a request to enhance THIS transcript, not to import a different
            // meeting's words into it.
            guard let fireflies = try await fetchFirefliesTranscript(
                near: near,
                within: MCPConnectionManager.firefliesMatchWindow),
                  matchesFirefliesMutationIdentity(expected) else { return false }
            // Keep the raw Fireflies text available as context for prompt runs.
            if !contextFiles.contains(where: { $0.name == "Fireflies · \(fireflies.title)" }) {
                contextFiles.append(ImportedContextFile(
                    name: "Fireflies · \(fireflies.title)",
                    text: fireflies.text))
            }
            return await applyFirefliesEnhancement(fireflies, automatic: automatic)
        } catch {
            guard matchesFirefliesMutationIdentity(expected) else { return false }
            if !automatic {
                lastError = error.localizedDescription
            } else {
                Log.general.info(
                    "Automatic Fireflies enhance skipped — \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    /// - Returns: whether Fireflies answered usefully. A merge, a partial merge
    ///   and a summary-only reply all count: the retry schedule exists to wait
    ///   for a transcript to EXIST, not to re-ask a model that already spoke.
    @discardableResult
    private func applyFirefliesEnhancement(_ fireflies: FirefliesTranscript, automatic: Bool) async -> Bool {
        let expected = captureTranscriptMutationIdentity()
        let sessionStart = recordingStartedAt ?? transcript.first?.timestamp ?? sessionDate
        let whisperSnapshot = expected.transcript
        let goalSnapshot = effectiveCallGoal
        let digestSnapshot = callDigest
        // Pull connected-app context (Notion/CRM/trackers/…) so the merge can
        // correct names and project terms — not just ASR common sense.
        var grounding: [GroundingSnippet] = []
        if useConnectedAppsInPrompts, let mcp {
            let query = goalSnapshot.isEmpty
                ? String(SystemInstructions.formatEntries(whisperSnapshot).suffix(500))
                : goalSnapshot
            grounding = await mcp.groundingSnippets(
                goal: query,
                includeTeam: true,
                maxCharsPerSource: 1_500,
                maxSources: 6)
            guard matchesFirefliesMutationIdentity(expected) else { return false }
        }
        do {
            let result = try await TranscriptEnhancementService.enhance(
                whisper: whisperSnapshot,
                fireflies: fireflies,
                sessionStart: sessionStart,
                goal: goalSnapshot,
                digest: digestSnapshot,
                grounding: grounding)
            guard matchesFirefliesMutationIdentity(expected) else { return false }
            // A partial merge covers only the start of the meeting. Replacing
            // the transcript with it would DELETE every line after the cut, so
            // the merged part is offered as context and the on-device
            // transcript is left exactly as it was.
            if result.isPartial {
                transcriptEnhanceNote =
                    "\(result.summary) · partial merge — transcript left unchanged"
            } else {
                transcript = result.entries
                localDiarizationNote = nil
                transcriptEnhanceNote = result.summary
            }
            contextFiles.removeAll { $0.name.hasPrefix("Enhanced · Fireflies") }
            contextFiles.append(ImportedContextFile(
                name: "Enhanced · Fireflies · \(result.firefliesTitle)"
                    + (result.isPartial ? " (partial)" : ""),
                text: SystemInstructions.formatEntries(result.entries)))
            lastError = nil
            persistCurrentSession()
            return true
        } catch TranscriptEnhancementError.summaryOnly(let summary) {
            guard matchesFirefliesMutationIdentity(expected) else { return false }
            // The model summarised what changed but its entry list was
            // unusable. That summary is still the useful half of the answer —
            // show it instead of an error full of broken JSON.
            transcriptEnhanceNote = "\(summary) · transcript left unchanged"
            lastError = nil
            return true
        } catch {
            guard matchesFirefliesMutationIdentity(expected) else { return false }
            if !automatic {
                lastError = error.localizedDescription
            } else {
                Log.general.info(
                    "Fireflies enhance failed — \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    /// Re-run diarization on demand (e.g. from a button).
    func diarizeNow() {
        guard canDiarize else { return }
        Task { await diarizeSession() }
    }

    /// Private post-call refinement. It uses bounded overlapping windows; a
    /// measured five-minute whole-file call returned only 92 words from 611,
    /// so a successful single decoder call is not proof of complete coverage.
    @Published var localRetranscribing = false

    static func shouldRetainSessionAudio(
        engine: TranscriptionEngine,
        hasAssemblyAI: Bool,
        assemblyDiarization: Bool,
        serverDiarization: Bool = false,
        localFinalPassEnabled: Bool = Config.transcriptionPostStopFinalPassEnabled,
        localDiarizationEnabled: Bool = false
    ) -> Bool {
        (engine == .local && (localFinalPassEnabled || localDiarizationEnabled))
            || (hasAssemblyAI && assemblyDiarization)
            || serverDiarization
    }

    /// Post-call speaker labeling is the only reason a non-Local route may
    /// keep writing the remote track. An origin merely says where existing PCM
    /// began; it is not authorization to retain every later route forever.
    private var hasSessionDiarizationAudioConsumer: Bool {
        sessionRetainedAudioTimelineValid
            && (serverDiarizationEligibleForSession
                || (hasAssemblyAI
                    && (activeRecordingSettings?.assemblyDiarization ?? false)))
    }

    private func shouldCollectRetainedAudio(on engine: TranscriptionEngine) -> Bool {
        guard sessionRetainedAudioTimelineValid else { return false }
        return hasSessionDiarizationAudioConsumer
            || (engine == .local
                && (localFinalPassOptedInForSession
                    || localDiarizationOptedInForSession))
    }

    private func beginLocalPostprocessSuffix(at startedAt: Date) {
        guard sessionRetainedAudioTimelineValid else { return }
        let finalPassEnabled = Config.transcriptionPostStopFinalPassEnabled
        let localDiarizationEnabled = activeRecordingSettings?.localDiarization ?? false
        guard finalPassEnabled || localDiarizationEnabled else { return }
        if sessionRetainedAudioStart == nil {
            sessionRetainedAudioStart = startedAt
        }
        sessionAudioStart = startedAt
        sessionAudioStartSample = sessionRecorder.retainedSampleCount
        localFinalPassOptedInForSession = finalPassEnabled
        localDiarizationOptedInForSession = localDiarizationEnabled
        localDiarizationContinuityValid = localDiarizationEnabled
    }

    /// Attach only after `resetForNewRecording`; otherwise the reset erases the
    /// timestamp while the observer keeps appending provenance-free audio.
    func beginSessionAudioRetention(on chunker: AudioChunkBuffer?, at startedAt: Date) {
        guard sessionRetainedAudioTimelineValid else { return }
        if sessionRetainedAudioStart == nil {
            sessionRetainedAudioStart = startedAt
        }
        if localFinalPassOptedInForSession || localDiarizationOptedInForSession {
            sessionAudioStart = startedAt
            sessionAudioStartSample = sessionRecorder.retainedSampleCount
        } else {
            sessionAudioStart = nil
            sessionAudioStartSample = 0
        }
        localFinalPassContinuityValid = localFinalPassOptedInForSession
            && activeSessionPreparedLocalWhisperModel != nil
        localDiarizationContinuityValid = localDiarizationOptedInForSession
        let recorder = sessionRecorder
        chunker?.addSampleObserver { samples in recorder.append(samples) }
    }

    private struct LocalFinalPassAudioBounds {
        let start: Date
        let end: Date
        let replaceLocalRowsBefore: Date
        let duration: TimeInterval
        let wasTruncated: Bool
    }

    private struct LocalFinalPassAudioSnapshot {
        let bounds: LocalFinalPassAudioBounds
        let samples: [Int16]
    }

    private func localFinalPassAudioBounds() -> LocalFinalPassAudioBounds? {
        guard sessionRetainedAudioTimelineValid,
              localFinalPassContinuityValid,
              let start = sessionAudioStart else { return nil }
        let duration = sessionRecorder.retainedDuration(from: sessionAudioStartSample)
        guard duration > 0 else { return nil }
        let end = start.addingTimeInterval(duration)
        // The cap can cut through a live six-second row whose timestamp marks
        // its start. Preserve one live-window guard band at a truncated edge;
        // a narrow duplicate is safer than deleting speech after the last PCM.
        let replaceBefore = sessionRecorder.isTruncated
            ? max(start, end.addingTimeInterval(-Config.transcriptionChunkSeconds))
            : end
        return LocalFinalPassAudioBounds(
            start: start,
            end: end,
            replaceLocalRowsBefore: replaceBefore,
            duration: duration,
            wasTruncated: sessionRecorder.isTruncated)
    }

    private func localFinalPassAudioSnapshot() -> LocalFinalPassAudioSnapshot? {
        guard let bounds = localFinalPassAudioBounds() else { return nil }
        let samples = sessionRecorder.sampleSnapshot(from: sessionAudioStartSample)
        guard !samples.isEmpty else { return nil }
        return LocalFinalPassAudioSnapshot(bounds: bounds, samples: samples)
    }

    var canRetranscribeLocally: Bool {
        guard let audio = localFinalPassAudioBounds() else { return false }
        let localInterval = LocalFinalPass.localSystemInterval(
            in: transcript,
            retainedAudioStart: audio.start,
            retainedAudioEnd: audio.end,
            replaceLocalRowsBefore: audio.replaceLocalRowsBefore)
        return !localRetranscribing
            && !enhancingTranscript
            && !firefliesImporting
            && !diarizing
            && localFinalPassOptedInForSession
            && activeSessionPreparedLocalWhisperModel != nil
            && status == .idle
            && !localInterval.isEmpty
            && !LocalFinalPass.retainedIntervalHasNonLocalSystemRows(
                transcript,
                retainedAudioStart: audio.start,
                retainedAudioEnd: audio.end)
    }

    static func shouldReleaseRetainedAudioAfterLocalFinalPass(
        hasAssemblyAI: Bool,
        assemblyDiarization: Bool,
        serverDiarization: Bool = false,
        localDiarization: Bool = false
    ) -> Bool {
        !(serverDiarization || localDiarization
            || (hasAssemblyAI && assemblyDiarization))
    }

    func cancelLocalSpeakerLabels(showNotice: Bool = true) {
        let wasRunning = localDiarizationRunning
        localDiarizationRevision &+= 1
        localDiarizationTask?.cancel()
        localDiarizationTask = nil
        localDiarizationRunID = nil
        localDiarizationRunning = false
        localDiarizationProgress = 0
        if wasRunning { diarizing = false }
        if showNotice, wasRunning {
            localDiarizationNote = "Определение говорящих отменено."
        }
        if !showNotice { localDiarizationNote = nil }
    }

    private func invalidateLocalFinalPassTasks(discardRetainedAudio: Bool) {
        cancelLocalSpeakerLabels(showNotice: false)
        localFinalPassRevision &+= 1
        automaticLocalFinalPassTask?.cancel()
        manualLocalFinalPassTask?.cancel()
        automaticLocalFinalPassTask = nil
        manualLocalFinalPassTask = nil
        localRetranscribing = false
        if discardRetainedAudio {
            sessionRecorder.discard()
            sessionRetainedAudioStart = nil
            sessionAudioStart = nil
            sessionAudioStartSample = 0
            localFinalPassContinuityValid = false
            localFinalPassOptedInForSession = false
            localDiarizationContinuityValid = false
            localDiarizationOptedInForSession = false
            serverDiarizationEligibleForSession = false
        }
    }

    @discardableResult
    func scheduleAutomaticLocalFinalPass(
        after routeLease: TranscriptionRouteLease?,
        enabled: Bool = Config.transcriptionPostStopFinalPassEnabled
    ) -> Task<Void, Never>? {
        automaticLocalFinalPassTask?.cancel()
        automaticLocalFinalPassTask = nil
        guard let audio = localFinalPassAudioBounds() else { return nil }
        let unsafeInterval = LocalFinalPass.retainedIntervalHasNonLocalSystemRows(
            transcript,
            retainedAudioStart: audio.start,
            retainedAudioEnd: audio.end)
        guard LocalFinalPass.shouldRunAutomatically(
            enabled: enabled,
            sessionEngine: activeSessionPreparedLocalWhisperModel == nil ? nil : .local,
            hasUnsafeRetainedInterval: unsafeInterval),
              canRetranscribeLocally else { return nil }

        manualLocalFinalPassTask?.cancel()
        manualLocalFinalPassTask = nil
        localFinalPassRevision &+= 1
        let revision = localFinalPassRevision
        localRetranscribing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let routeLease { await routeLease.waitUntilDrained() }
            await self.performLocalFinalPass(trigger: .automatic, revision: revision)
        }
        automaticLocalFinalPassTask = task
        return task
    }

    func retranscribeLocallyNow() {
        guard canRetranscribeLocally else { return }
        analytics(.featureUsed(.retranscribeLocal))
        automaticLocalFinalPassTask?.cancel()
        automaticLocalFinalPassTask = nil
        manualLocalFinalPassTask?.cancel()
        localFinalPassRevision &+= 1
        let revision = localFinalPassRevision
        localRetranscribing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLocalFinalPass(trigger: .manual, revision: revision)
        }
        manualLocalFinalPassTask = task
    }

    private func performLocalFinalPass(
        trigger: LocalFinalPass.Trigger,
        revision: Int
    ) async {
        defer {
            if localFinalPassRevision == revision {
                localRetranscribing = false
                if trigger == .automatic { automaticLocalFinalPassTask = nil }
                else { manualLocalFinalPassTask = nil }
            }
        }
        guard !Task.isCancelled,
              localFinalPassRevision == revision,
              !enhancingTranscript,
              !firefliesImporting,
              let audio = localFinalPassAudioSnapshot() else {
            recordLocalFinalPass(trigger: trigger, reason: .notEligible)
            return
        }
        let bounds = audio.bounds

        let requestedSessionID = currentSessionID
        let requestedGeneration = chunkGeneration
        let requestedTranscriptRevision = transcriptRevision
        let requestedTranscript = transcript
        let settings = activeRecordingSettings
        let releaseRetainedAudio = Self.shouldReleaseRetainedAudioAfterLocalFinalPass(
            hasAssemblyAI: hasAssemblyAI,
            assemblyDiarization: settings?.assemblyDiarization ?? false,
            serverDiarization: serverDiarizationEligibleForSession,
            localDiarization: localDiarizationOptedInForSession)
        // There is deliberately no implicit retry contract. Once a pass has
        // consumed the PCM, decoder failure and conservative quality refusal
        // both preserve the live text and release the audio unless opted-in
        // diarization still needs it. Revision/session guards keep an obsolete
        // task from touching a newer call.
        defer {
            if localFinalPassRevision == revision,
               currentSessionID == requestedSessionID {
                localFinalPassContinuityValid = false
                localFinalPassOptedInForSession = false
                activeSessionPreparedLocalWhisperModel = nil
                if releaseRetainedAudio {
                    sessionRecorder.discard()
                    sessionRetainedAudioStart = nil
                    sessionAudioStart = nil
                    sessionAudioStartSample = 0
                }
            }
        }
        let liveModel = activeSessionPreparedLocalWhisperModel
            ?? settings?.localModel
            ?? Config.localWhisperModel
        let model = LocalWhisperModel.postCallRefinementModel(
            liveModel: liveModel,
            availableModels: [LocalWhisperModel.migrated(liveModel)],
            isAppleSilicon: Hardware.isAppleSilicon)
        let language = settings?.language ?? Config.transcriptionLanguage
        let glossary = settings?.glossary ?? Config.transcriptionGlossary
        let goal = effectiveCallGoal
        let theme = activeCallTheme
        let liveLocalInterval = LocalFinalPass.localSystemInterval(
            in: requestedTranscript,
            retainedAudioStart: bounds.start,
            retainedAudioEnd: bounds.end,
            replaceLocalRowsBefore: bounds.replaceLocalRowsBefore)

        if let refusal = LocalFinalPass.audioCoverageRefusal(
            targetDurationSeconds: bounds.end.timeIntervalSince(bounds.start),
            retainedAudioSeconds: bounds.duration,
            retainedAudioWasTruncated: bounds.wasTruncated) {
            recordLocalFinalPass(
                trigger: trigger, reason: refusal,
                recordingDuration: bounds.duration,
                retainedDuration: bounds.duration)
            return
        }

        let service = localFinalPassServiceFactory(model, language)
        let decoded: Result<[TranscriptEntry], any Error>
        do {
            decoded = .success(try await LocalFinalPass.decode(
                samples: audio.samples,
                retainedAudioStart: bounds.start,
                using: service))
        } catch {
            decoded = .failure(error)
        }
        await service.shutdown()

        guard !Task.isCancelled, localFinalPassRevision == revision else { return }
        guard currentSessionID == requestedSessionID else {
            recordLocalFinalPass(
                trigger: trigger, reason: .staleSession,
                recordingDuration: bounds.duration,
                retainedDuration: bounds.duration)
            return
        }
        guard chunkGeneration == requestedGeneration else {
            recordLocalFinalPass(
                trigger: trigger, reason: .staleGeneration,
                recordingDuration: bounds.duration,
                retainedDuration: bounds.duration)
            return
        }
        guard transcriptRevision == requestedTranscriptRevision,
              transcript == requestedTranscript else {
            recordLocalFinalPass(
                trigger: trigger, reason: .staleTranscript,
                recordingDuration: bounds.duration,
                retainedDuration: bounds.duration)
            return
        }

        switch decoded {
        case .failure(let error):
            if trigger == .manual { lastError = error.localizedDescription }
            recordLocalFinalPass(
                trigger: trigger, reason: .decoderFailed,
                recordingDuration: bounds.duration,
                retainedDuration: bounds.duration)
        case .success(let decodedEntries):
            let decodedText = LocalFinalPass.systemText(decodedEntries)
            let casingTerms = DomainLexicon.casingOnlyTerms(
                for: goal + " " + decodedText) + ThemeGlossary.terms(for: theme)
            let refinedEntries = decodedEntries.compactMap { entry -> TranscriptEntry? in
                let restored = GlossaryRestore.restore(
                    transcript: entry.text,
                    glossary: Glossary.terms(from: glossary),
                    casingOnlyGlossary: casingTerms)
                let text = RussianLexicon.restoreIfRussian(restored)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptEntry(
                    id: entry.id,
                    source: .system,
                    text: text,
                    timestamp: entry.timestamp,
                    speaker: nil,
                    transcriptionEngine: .local)
            }
            let decision = LocalFinalPass.evaluate(
                live: liveLocalInterval,
                refined: refinedEntries,
                targetDurationSeconds: bounds.duration,
                retainedAudioSeconds: bounds.duration,
                retainedAudioWasTruncated: bounds.wasTruncated)
            guard decision.replace else {
                recordLocalFinalPass(
                    trigger: trigger, decision: decision,
                    recordingDuration: bounds.duration,
                    retainedDuration: bounds.duration)
                return
            }
            guard !Task.isCancelled,
                  localFinalPassRevision == revision,
                  currentSessionID == requestedSessionID,
                  chunkGeneration == requestedGeneration,
                  transcriptRevision == requestedTranscriptRevision,
                  transcript == requestedTranscript else {
                recordLocalFinalPass(
                    trigger: trigger, reason: .staleTranscript,
                    recordingDuration: bounds.duration,
                    retainedDuration: bounds.duration)
                return
            }
            transcript = LocalFinalPass.replacingLocalSystemInterval(
                live: requestedTranscript,
                refined: refinedEntries,
                retainedAudioStart: bounds.start,
                retainedAudioEnd: bounds.end,
                replaceLocalRowsBefore: bounds.replaceLocalRowsBefore)
            localDiarizationNote = nil
            lastError = nil
            persistCurrentSession()
            recordLocalFinalPass(
                trigger: trigger, decision: decision,
                recordingDuration: bounds.duration,
                retainedDuration: bounds.duration,
                refinedCharacters: LocalFinalPass.systemText(refinedEntries).count)
        }
    }

    private func recordLocalFinalPass(
        trigger: LocalFinalPass.Trigger,
        reason: LocalFinalPass.Reason? = nil,
        decision: LocalFinalPass.Decision? = nil,
        recordingDuration: TimeInterval = 0,
        retainedDuration: TimeInterval = 0,
        refinedCharacters: Int = 0
    ) {
        let resolvedReason = decision?.reason ?? reason ?? .notEligible
        let outcome = resolvedReason == .accepted ? "replaced" : "preserved"
        Log.transcribe.notice(
            "Local final pass trigger=\(trigger.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) reason=\(resolvedReason.rawValue, privacy: .public) recordingSeconds=\(recordingDuration, privacy: .public) retainedSeconds=\(retainedDuration, privacy: .public)")
        devCallDiagnostics.record(event: "local_final_pass", fields: [
            "trigger": trigger.rawValue,
            "outcome": outcome,
            "reason": resolvedReason.rawValue,
            "recordingDurationSeconds": recordingDuration,
            "retainedDurationSeconds": retainedDuration,
            "audioCoverage": decision?.audioCoverage ?? 0,
            "liveWords": decision?.liveWordCount ?? 0,
            "refinedWords": decision?.refinedWordCount ?? 0,
            "liveTokenRecall": decision?.liveTokenRecall ?? 0,
            "orderedTokenRecall": decision?.orderedTokenRecall ?? 0,
            "refinedCharacters": refinedCharacters,
            "windowSeconds": LocalFinalPass.windowSeconds,
            "overlapSeconds": LocalFinalPass.overlapSeconds,
        ])
    }

    private struct LocalDiarizationAudioSnapshot {
        let pcm: ArraySlice<Int16>
        let start: Date
        let end: Date
        let wasTruncated: Bool
    }

    private func localDiarizationAudioSnapshot() -> LocalDiarizationAudioSnapshot? {
        guard sessionRetainedAudioTimelineValid,
              localDiarizationOptedInForSession,
              localDiarizationContinuityValid,
              let start = sessionAudioStart else { return nil }
        let pcm = sessionRecorder.snapshotSamples(
            fromSampleOffset: sessionAudioStartSample)
        guard LocalDiarization.canRun(sampleCount: pcm.count) else { return nil }
        return LocalDiarizationAudioSnapshot(
            pcm: pcm,
            start: start,
            end: start.addingTimeInterval(Double(pcm.count) / 16_000),
            wasTruncated: sessionRecorder.isTruncated)
    }

    /// Manual Beta action. `Вы` owns slot 1 because the microphone track is
    /// already known; remote clusters are stable Спикер 2...5 by first
    /// appearance. Paused or mixed-route PCM is refused rather than shifted
    /// onto the wrong transcript rows.
    var canLabelSpeakersLocally: Bool {
        guard let settings = activeRecordingSettings else { return false }
        let retainedLocalSamples = max(
            0, sessionRecorder.retainedSampleCount - sessionAudioStartSample)
        return settings.engine == .local
            && settings.localDiarization
            && localDiarizationOptedInForSession
            && localDiarizationContinuityValid
            && sessionRetainedAudioTimelineValid
            && status == .idle
            && !transcript.isEmpty
            && sessionAudioStart != nil
            && !diarizing
            && !localRetranscribing
            && automaticLocalFinalPassTask == nil
            && manualLocalFinalPassTask == nil
            && !enhancingTranscript
            && !firefliesImporting
            && LocalDiarization.canRun(sampleCount: retainedLocalSamples)
    }

    var hasScheduledLocalDiarization: Bool { localDiarizationTask != nil }

    func labelSpeakersLocallyNow(
        expectedRemoteSpeakerCount: Int = Config.localDiarizationRemoteSpeakerCount
    ) {
        guard canLabelSpeakersLocally,
              let audio = localDiarizationAudioSnapshot() else { return }

        let runID = UUID()
        let revision = localDiarizationRevision
        let requestedSessionID = currentSessionID
        let requestedGeneration = chunkGeneration
        let requestedTranscriptRevision = transcriptRevision
        let requestedTranscript = transcript
        // Retention consent is snapshotted with the recording; the count is a
        // run-time hint so it can be corrected and rerun on the same PCM.
        let expected = LocalDiarization.normalizedRemoteSpeakerCount(
            expectedRemoteSpeakerCount)

        localDiarizationRunID = runID
        localDiarizationRunning = true
        localDiarizationProgress = 0
        localDiarizationNote = nil
        diarizing = true
        localDiarizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLocalSpeakerLabels(
                audio: audio,
                expectedRemoteSpeakerCount: expected,
                requestedSessionID: requestedSessionID,
                requestedGeneration: requestedGeneration,
                requestedTranscriptRevision: requestedTranscriptRevision,
                requestedTranscript: requestedTranscript,
                requestedRevision: revision,
                runID: runID)
            guard self.localDiarizationRunID == runID else { return }
            self.localDiarizationTask = nil
            self.localDiarizationRunID = nil
            self.localDiarizationRunning = false
            self.localDiarizationProgress = 0
            self.diarizing = false
        }
    }

    private func performLocalSpeakerLabels(
        audio: LocalDiarizationAudioSnapshot,
        expectedRemoteSpeakerCount: Int,
        requestedSessionID: UUID,
        requestedGeneration: Int,
        requestedTranscriptRevision: Int,
        requestedTranscript: [TranscriptEntry],
        requestedRevision: Int,
        runID: UUID
    ) async {
        let progress: LocalDiarization.Progress = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.localDiarizationRunID == runID,
                      self.localDiarizationRevision == requestedRevision else { return }
                self.localDiarizationProgress = min(1, max(0, value))
            }
        }

        do {
            let samples = try await LocalDiarization.floatSamples(from: audio.pcm)
            try Task.checkCancellation()
            let segments: [SpeakerSegment]
            if let override = localDiarizationRunnerOverride {
                segments = try await override(
                    samples, expectedRemoteSpeakerCount, progress)
            } else {
                segments = try await LocalDiarization.segments(
                    samples: samples,
                    expectedRemoteSpeakerCount: expectedRemoteSpeakerCount,
                    progress: progress)
            }

            guard localDiarizationRunID == runID,
                  currentSessionID == requestedSessionID,
                  chunkGeneration == requestedGeneration,
                  transcriptRevision == requestedTranscriptRevision,
                  localDiarizationRevision == requestedRevision,
                  transcript == requestedTranscript,
                  status == .idle,
                  localDiarizationContinuityValid,
                  !Task.isCancelled else { return }

            let found = SpeakerAssignment.distinctSpeakers(in: segments)
            guard found > 0 else {
                localDiarizationNote =
                    "Речь собеседников недостаточно ясна. Транскрипт не изменён."
                return
            }
            let labeled = SpeakerAssignment.apply(
                segments: segments,
                to: requestedTranscript,
                sessionStart: audio.start,
                firstRemoteSpeakerNumber: 2,
                localSpeakerLabel: SpeakerAssignment.localSpeakerLabel)
            // The Local route may be only a suffix after an Instant fallback,
            // and the one-hour cap may leave later rows without PCM. Never
            // relabel outside the exact retained interval.
            transcript = zip(requestedTranscript, labeled).map { original, candidate in
                guard original.timestamp >= audio.start,
                      original.timestamp < audio.end else { return original }
                return candidate
            }
            persistCurrentSession()
            let resultNote = found == expectedRemoteSpeakerCount
                ? "Говорящие определены на этом Mac. Бета — проверьте имена перед отправкой."
                : "Найдено голосов: \(found) из \(expectedRemoteSpeakerCount). Бета — проверьте метки или запустите снова с другим числом."
            localDiarizationNote = resultNote + (audio.wasTruncated
                ? " Подписана только полностью сохранённая часть; поздние строки не изменены."
                : "")
            devCallDiagnostics.record(
                event: "local_diarization",
                fields: [
                    "expectedRemoteSpeakers": "\(expectedRemoteSpeakerCount)",
                    "foundRemoteSpeakers": "\(found)",
                    "segments": "\(segments.count)",
                    "pipeline": "offline-community-1",
                ])
        } catch is CancellationError {
            // Cancel/New Call/History are ordinary lifecycle boundaries.
        } catch {
            guard localDiarizationRunID == runID,
                  localDiarizationRevision == requestedRevision else { return }
            localDiarizationNote =
                "Не удалось определить говорящих на этом Mac. Транскрипт не изменён."
            Log.general.error(
                "local diarization skipped — \(error.localizedDescription)")
        }
    }

    /// Confirmation for the last digest copy, shown briefly in the menu.
    @Published var digestCopyNotice: String?

    /// Build this week's digest for one audience and put it on the clipboard
    /// (roadmap F3's entry point).
    ///
    /// Copy, never send. The mined record of this category is a series of
    /// auto-send incidents — a transcript mailed to everyone on the call, a
    /// client sent the two minutes of talk about them — so Cruxwing composes
    /// the text and a human chooses where it goes. The `write` seam exists so
    /// the behaviour is testable without a pasteboard.
    /// `store` defaults to nil so it resolves to the store this AppState was
    /// built with. Defaulting to `.shared` looked harmless and meant the menu
    /// item read a different history than the rest of the app whenever one was
    /// injected — the same slip recall shipped with.
    func copyWeeklyDigest(audience: WeeklyDigest.Audience,
                          store: SessionStore? = nil,
                          write: (String) -> Void = { text in
                              NSPasteboard.general.clearContents()
                              NSPasteboard.general.setString(text, forType: .string)
                          }) {
        let text = WeeklyDigest.build(audience: audience, store: store ?? sessionStore)
        write(text)
        digestCopyNotice = "\(audience.heading) copied — paste it wherever it belongs."
        devCallDiagnostics.record(event: "weekly_digest_copied",
                                  fields: ["audience": audience.rawValue,
                                           "chars": "\(text.count)"])
    }

    private func diarizeSession() async {
        guard sessionRetainedAudioTimelineValid,
              !diarizing,
              canDiarizeOnServer
                || (hasAssemblyAI && Config.assemblyAIDiarizationEnabled) else { return }
        let wav = sessionRecorder.makeWAV()
        guard !wav.isEmpty, let start = sessionRetainedAudioStart else { return }
        let requestedSessionID = currentSessionID
        let requestedGeneration = chunkGeneration

        diarizing = true
        defer { diarizing = false }
        do {
            // Server first: it needs no key from the user and bills the
            // recording once. A BYO AssemblyAI key stays the fallback for
            // anyone who prefers it, or who is offline from our backend.
            let utterances: [DiarizedUtterance]
            if canDiarizeOnServer {
                utterances = try await ServerDiarizationService.diarize(
                    wav: wav,
                    language: activeSessionLanguage ?? Config.transcriptionLanguage)
            } else {
                utterances = try await AssemblyAIService.diarize(
                    wav: wav, apiKey: Config.assemblyAIAPIKey,
                    speakersExpected: AssemblyAIService.speakersExpected(attendeeCount: callAttendeeCount),
                    language: activeSessionLanguage ?? Config.transcriptionLanguage)
            }
            guard currentSessionID == requestedSessionID,
                  chunkGeneration == requestedGeneration else { return }
            guard !utterances.isEmpty else { return }
            let diarized = utterances.map { utterance in
                TranscriptEntry(source: .system,
                                text: utterance.text,
                                timestamp: start.addingTimeInterval(Double(utterance.startMs) / 1000),
                                speaker: "Speaker \(utterance.speaker)")
            }
            let mine = transcript.filter { $0.source == .mic }
            transcript = (diarized + mine).sorted { $0.timestamp < $1.timestamp }
            localDiarizationNote = nil
            lastError = nil
            persistCurrentSession()
        } catch {
            guard currentSessionID == requestedSessionID,
                  chunkGeneration == requestedGeneration else { return }
            lastError = error.localizedDescription
        }
    }

    // MARK: - Live timer

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let start = self.recordingStartedAt {
                    self.recordingClock.update(Date().timeIntervalSince(start))
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - First-run permission pre-flight

    /// Re-read live permission status for the onboarding screen. Screen
    /// Recording uses the authoritative async probe (the cached preflight lies).
    func refreshPermissionStatus() async {
        micGranted = Permissions.microphone == .granted
        screenRecordingGranted = await Permissions.screenRecordingAuthorized()
    }

    /// Trigger the mic system prompt (first time) then re-read status.
    func requestMicrophonePermission() async {
        _ = await Permissions.requestMicrophone()
        await refreshPermissionStatus()
    }

    /// Trigger the Screen Recording prompt (first time only — after a prior
    /// deny the user must toggle it in System Settings and relaunch).
    func requestScreenRecordingPermission() async {
        Permissions.requestScreenRecording()
        await refreshPermissionStatus()
    }

    /// Warm the on-device model during onboarding — only when the local engine
    /// is selected (cloud engines have nothing to download).
    func prewarmLocalModelIfNeeded() {
        guard Config.transcriptionEngineValue == .local else { return }
        prepareLocalModel()
    }

    /// Prepare (download + load) the on-device model ahead of the first chunk,
    /// reflecting progress in `transcriptionState`. Idempotent: a warm model or
    /// an in-flight preparation short-circuits. A failure is surfaced (not
    /// swallowed) so the transcript panel can explain itself and offer a fix.
    func prepareLocalModel() {
        guard transcriptionState != .preparing, transcriptionState != .ready else { return }
        transcriptionState = .preparing
        let preparingTranscriber = transcriber
        let preparationID = ObjectIdentifier(preparingTranscriber)
        Task { [weak self, preparingTranscriber] in
            guard let self else { return }
            do {
                try await preparingTranscriber.prewarm()
                await MainActor.run {
                    guard ObjectIdentifier(self.transcriber) == preparationID else { return }
                    if self.transcriptionState != .ready { self.transcriptionState = .ready }
                }
            } catch {
                await MainActor.run {
                    guard ObjectIdentifier(self.transcriber) == preparationID else { return }
                    self.transcriptionState = .failed(error.localizedDescription)
                    self.lastError = "Модель распознавания не загрузилась: \(error.localizedDescription) — проверьте сеть или смените движок в настройках."
                }
            }
        }
    }

    func dispatchTranscription(wav: Data, source: TranscriptSource,
                               generation requestedGeneration: Int? = nil,
                               using requestedTranscriber: TranscriptionService? = nil,
                               engine requestedEngine: TranscriptionEngine? = nil,
                               capturedAt requestedCaptureTime: Date? = nil) async {
        let generation = requestedGeneration ?? chunkGeneration
        // This check precedes any provider call: cleared/older audio must never
        // reach whichever backend is selected for a later recording.
        guard chunkGeneration == generation else { return }
        let recordingTranscriber = requestedTranscriber ?? transcriber
        let recordingEngine = requestedEngine ?? activeSessionEngine ?? Config.transcriptionEngineValue
        do {
            // Prefix the source with this recording generation so stale queued
            // Whisper work can never append into a later meeting.
            let streamID = "\(generation):\(source.rawValue)"
            let text = try await recordingTranscriber.transcribe(wav: wav, streamID: streamID)
            guard chunkGeneration == generation else { return }
            if let recommendation = await recordingTranscriber.takePerformanceRecommendation() {
                guard chunkGeneration == generation else { return }
                applyTranscriptionPerformanceRecommendation(recommendation)
            }
            // A chunk came back at all — the engine is working; clear any
            // lingering "preparing"/"failed" state.
            await MainActor.run {
                guard self.chunkGeneration == generation else { return }
                if self.transcriptionState != .ready { self.transcriptionState = .ready }
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                // Persisted breadcrumb: "listening, no transcript" used to be
                // undiagnosable because empty results vanished right here.
                Log.transcribe.notice("empty transcription result (\(source == .mic ? "mic" : "system", privacy: .public), \(wav.count) bytes)")
                return
            }
            await MainActor.run {
                // clearAll() while we were transcribing invalidated this line.
                guard self.chunkGeneration == generation else { return }
                // Preserve capture chronology across a mid-call engine switch:
                // an old Local decode may complete after a newer Instant final.
                let timestamp = requestedCaptureTime ?? Date()
                // Windows overlap so no word sits alone at a seam, which means
                // the seam decodes twice. Cut the repeat INSIDE the line rather
                // than dropping the line: the new window carries fresh speech
                // as well, and dropping it is how the old hard-cut path lost
                // words. Scoped per track — the two tracks are independent
                // streams and their seams do not line up.
                let stitched = ChunkStitcher.stitch(
                    previous: self.lastChunkText[source] ?? "", next: clean)
                guard !stitched.isEmpty else { return }
                self.lastChunkText[source] = clean
                let deechoed = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
                    from: stitched, source: source, recent: self.transcript, at: timestamp)
                guard !deechoed.isEmpty else { return }
                let entry = TranscriptEntry(
                    source: source, text: deechoed, timestamp: timestamp,
                    transcriptionEngine: recordingEngine)
                guard self.admitTranscriptEntry(entry) else { return }
                if self.status == .idle {
                    // A final partial chunk can finish just after stop's first
                    // save; persist again so History includes the last words.
                    self.persistCurrentSession()
                }
            }
        } catch {
            await MainActor.run {
                guard self.chunkGeneration == generation else { return }
                let message = error.localizedDescription
                // Runtime inference can fail after a successful prewarm, so
                // `.ready` must not leave the UI claiming it is still listening.
                if recordingEngine == .local {
                    let failed = TranscriptionState.failed(message)
                    // Publish the toast only on the state transition. If the
                    // user dismisses it, suspended chunks must not reopen it.
                    guard self.transcriptionState != failed else { return }
                    self.transcriptionState = failed
                    self.lastError = message
                } else if self.lastError != message {
                    self.lastError = message
                }
            }
        }
    }

    /// Redirect the two AudioChunkBuffer instances retained by the live capture
    /// callbacks. Replacing AppState's stored references is insufficient: the
    /// ScreenCaptureKit/AVAudioEngine taps captured the original objects when
    /// recording began.
    private func parkRetiringTranscriber(_ service: TranscriptionService) {
        retiringTranscribers[ObjectIdentifier(service)] = service
    }

    private func unparkRetiringTranscriber(_ service: TranscriptionService) {
        retiringTranscribers.removeValue(forKey: ObjectIdentifier(service))
    }

    private func retireTranscriber(
        _ service: TranscriptionService,
        routeLease: TranscriptionRouteLease
    ) {
        let id = ObjectIdentifier(service)
        let registered = routeLease.retire { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let retiring = self.retiringTranscribers.removeValue(forKey: id)
                else { return }
                await retiring.shutdown()
            }
        }
        if registered { retiringTranscribers[id] = service }
    }

    private func retirePendingDeepgramPreviousRoute() {
        guard let service = pendingDeepgramPreviousTranscriber,
              let routeLease = pendingDeepgramPreviousRouteLease else { return }
        pendingDeepgramPreviousTranscriber = nil
        pendingDeepgramPreviousRouteLease = nil
        retireTranscriber(service, routeLease: routeLease)
    }

    private func completeDeepgramHandoff(
        previous service: TranscriptionService,
        routeLease: TranscriptionRouteLease
    ) {
        if let pending = pendingDeepgramPreviousTranscriber,
           ObjectIdentifier(pending) == ObjectIdentifier(service),
           pendingDeepgramPreviousRouteLease === routeLease {
            pendingDeepgramPreviousTranscriber = nil
            pendingDeepgramPreviousRouteLease = nil
        }
        retireTranscriber(service, routeLease: routeLease)
    }

    private func switchActiveTranscriptionEngine(
        to engine: TranscriptionEngine,
        replacing previousSettings: RecordingSettingsSnapshot,
        previousEngine: TranscriptionEngine
    ) -> Bool {
        if let transcriptionEngineSwitchOverride {
            return transcriptionEngineSwitchOverride(engine)
        }
        guard managesTranscriberLifecycle,
              status == .recording,
              let systemChunker,
              let micChunker,
              recordingGenerationToken != nil,
              transcriptionEngineAvailability(engine) else { return false }

        // An engine switch is a route boundary, not a recording boundary. Keep
        // this call's generation so already-emitted old-engine chunks can land;
        // Stop/Clear/new recording remain the only operations that invalidate
        // the generation. A Deepgram route being retired may therefore deliver
        // its final pre-switch server result after `finish()`; no future audio
        // reaches it because the retained chunkers move atomically below. A
        // failed pre-ready handoff is different and explicitly poisons only its
        // own token in `restoreEngineAfterFailedDeepgramHandoff`.
        let handoffBoundary = Date()
        recordingGenerationToken?.retireRoute(at: handoffBoundary)
        if previousEngine == .deepgram {
            latestStreamingRouteRetiredAt = handoffBoundary
        }
        let nextRouteStart = RecordingGenerationToken.nextRouteStart(
            after: handoffBoundary)
        let generationToken = RecordingGenerationToken(
            chunkGeneration, routeStartedAt: nextRouteStart)
        recordingGenerationToken = generationToken
        provisional.removeAll()

        let previousTranscriber = transcriber
        let previousRouteLease = activeChunkRouteLease
        if previousEngine == .deepgram {
            retirePendingDeepgramPreviousRoute()
        }
        if engine == .deepgram {
            if previousRouteLease != nil {
                parkRetiringTranscriber(previousTranscriber)
                pendingDeepgramPreviousTranscriber = previousTranscriber
                pendingDeepgramPreviousRouteLease = previousRouteLease
            }
            activeChunkRouteLease = nil
            let placeholder = transcriptionServiceFactory(
                engine, previousSettings.language, previousSettings.glossary,
                previousSettings.localModel, nil)
            transcriber = placeholder
            transcriberEngine = engine
            transcriberLocalModel = nil
            transcriberLanguage = previousSettings.language
            transcriberGlossary = previousSettings.glossary
            transcriptionState = .ready

            startDeepgram(
                chunkSeconds: Config.transcriptionChunkSeconds,
                generationToken: generationToken,
                language: previousSettings.language,
                keyterms: previousSettings.glossaryTerms,
                reusingSystemChunker: systemChunker,
                reusingMicChunker: micChunker,
                restoreOnFailedHandoff: previousSettings.replacingEngine(with: previousEngine),
                restoreTranscriberOnFailedHandoff: previousTranscriber,
                restoreRouteLeaseOnFailedHandoff: previousRouteLease)
        } else {
            systemStreamer?.finish()
            micStreamer?.finish()
            systemStreamer = nil
            micStreamer = nil

            let nextTranscriber = transcriptionServiceFactory(
                engine, previousSettings.language, previousSettings.glossary,
                previousSettings.localModel, nil)
            let nextRouteLease = TranscriptionRouteLease()
            let systemHandler = liveChunkHandler(
                source: .system, transcriber: nextTranscriber,
                engine: engine, generationToken: generationToken,
                routeLease: nextRouteLease)
            let micHandler = liveChunkHandler(
                source: .mic, transcriber: nextTranscriber,
                engine: engine, generationToken: generationToken,
                routeLease: nextRouteLease)
            let recorder = sessionRecorder
            if engine == .local, previousEngine != .local {
                // Every explicit non-Local → Private switch starts a new exact
                // refinement interval. The recorder may keep an earlier prefix
                // for opted-in diarization, so remember the sample offset
                // rather than counting that prefix as Local coverage.
                beginLocalPostprocessSuffix(at: nextRouteStart)
            }
            let keepRecording = shouldCollectRetainedAudio(on: engine)
            systemChunker.reconfigure(
                onChunk: systemHandler,
                onSamples: keepRecording ? { recorder.append($0) } : nil,
                flushBufferedSamplesToPreviousHandler: previousEngine != .deepgram)
            micChunker.reconfigure(
                onChunk: micHandler, onSamples: nil,
                flushBufferedSamplesToPreviousHandler: previousEngine != .deepgram)

            transcriber = nextTranscriber
            activeChunkRouteLease = nextRouteLease
            transcriberEngine = engine
            transcriberLocalModel = engine == .local ? previousSettings.localModel : nil
            if engine == .local {
                activeSessionPreparedLocalWhisperModel =
                    nextTranscriber is LocalWhisperTranscription
                    ? previousSettings.localModel : nil
                localFinalPassContinuityValid =
                    localFinalPassOptedInForSession
                        && activeSessionPreparedLocalWhisperModel != nil
                localDiarizationContinuityValid =
                    localDiarizationOptedInForSession
                        && sessionAudioStart != nil
            }
            transcriberLanguage = previousSettings.language
            transcriberGlossary = previousSettings.glossary
            transcriptionState = engine == .local ? .idle : .ready
            if engine == .local { prepareLocalModel() }

            if let previousRouteLease {
                retireTranscriber(previousTranscriber, routeLease: previousRouteLease)
            } else if previousEngine != .deepgram {
                Task { await previousTranscriber.shutdown() }
            }
        }
        return true
    }

    private func liveChunkHandler(
        source: TranscriptSource,
        transcriber: TranscriptionService,
        engine: TranscriptionEngine,
        generationToken: RecordingGenerationToken,
        routeLease: TranscriptionRouteLease
    ) -> AudioChunkBuffer.ChunkHandler {
        { [weak self, transcriber] wav, timing in
            guard routeLease.begin() else { return }
            let generation = generationToken.read()
            let capturedAt = generationToken.captureStart(
                duration: timing.captureSpan)
            Task(priority: .utility) {
                defer { routeLease.finish() }
                await self?.dispatchTranscription(
                    wav: wav, source: source, generation: generation,
                    using: transcriber, engine: engine, capturedAt: capturedAt)
            }
        }
    }

    /// A Deepgram socket can fail after `start()` returned because WebSocket
    /// open is optimistic. Until both tracks are ready, restore the engine that
    /// was already carrying this call and revert the saved Settings row.
    private func restoreEngineAfterFailedDeepgramHandoff(
        _ settings: RecordingSettingsSnapshot,
        transcriber previousTranscriber: TranscriptionService,
        routeLease previousRouteLease: TranscriptionRouteLease?,
        preReadyBuffer: DeepgramPreReadyBuffer?,
        generationToken: RecordingGenerationToken,
        message: String
    ) {
        guard recordingGenerationToken === generationToken,
              status == .recording,
              activeSessionEngine == .deepgram,
              let systemChunker,
              let micChunker else { return }

        // Invalidate only the failed stream. Local chunks captured before the
        // attempted switch may still complete as live prefix rows, but the
        // post-call pass starts a fresh suffix after this rollback boundary.
        generationToken.set(chunkGeneration &+ 1)
        let rollbackBoundary = Date()
        let restoredRouteStart = RecordingGenerationToken.nextRouteStart(
            after: rollbackBoundary)
        let restoredGeneration = RecordingGenerationToken(
            chunkGeneration, routeStartedAt: restoredRouteStart)
        recordingGenerationToken = restoredGeneration
        provisional.removeAll()

        systemStreamer?.finish()
        micStreamer?.finish()
        systemStreamer = nil
        micStreamer = nil

        let restoredRouteLease = previousRouteLease ?? TranscriptionRouteLease()
        if settings.engine == .local {
            // The attempted cloud route ended the old Local interval even when
            // it failed before readiness. Start a provable future-only suffix;
            // replayed pre-ready chunks remain live prefix rows outside it.
            beginLocalPostprocessSuffix(at: restoredRouteStart)
        }
        let keepRecording = shouldCollectRetainedAudio(on: settings.engine)
        systemChunker.reconfigure(
            onChunk: liveChunkHandler(
                source: .system, transcriber: previousTranscriber,
                engine: settings.engine, generationToken: restoredGeneration,
                routeLease: restoredRouteLease),
            onSamples: keepRecording
                ? { [recorder = sessionRecorder] samples in recorder.append(samples) }
                : nil,
            discardBufferedSamples: false,
            flushBufferedSamplesToPreviousHandler: preReadyBuffer != nil)
        micChunker.reconfigure(
            onChunk: liveChunkHandler(
                source: .mic, transcriber: previousTranscriber,
                engine: settings.engine, generationToken: restoredGeneration,
                routeLease: restoredRouteLease),
            onSamples: nil,
            discardBufferedSamples: false,
            flushBufferedSamplesToPreviousHandler: preReadyBuffer != nil)

        let failedInstantTranscriber = transcriber
        if let pending = pendingDeepgramPreviousTranscriber,
           ObjectIdentifier(pending) == ObjectIdentifier(previousTranscriber),
           pendingDeepgramPreviousRouteLease === restoredRouteLease {
            pendingDeepgramPreviousTranscriber = nil
            pendingDeepgramPreviousRouteLease = nil
        }
        unparkRetiringTranscriber(previousTranscriber)
        activeChunkRouteLease = restoredRouteLease
        transcriber = previousTranscriber
        transcriberEngine = settings.engine
        transcriberLocalModel = settings.engine == .local ? settings.localModel : nil
        transcriberLanguage = settings.language
        transcriberGlossary = settings.glossary
        transcriptionState = .ready
        publishTranscriptionEngineRollback(settings)
        if settings.engine == .local {
            activeSessionPreparedLocalWhisperModel =
                previousTranscriber is LocalWhisperTranscription
                ? settings.localModel : nil
            localFinalPassContinuityValid = localFinalPassOptedInForSession
                && activeSessionPreparedLocalWhisperModel != nil
                && sessionAudioStart != nil
            localDiarizationContinuityValid = localDiarizationOptedInForSession
                && sessionAudioStart != nil
        }
        let bufferedChunks = preReadyBuffer?.drainForRollback() ?? []
        for buffered in bufferedChunks where restoredRouteLease.begin() {
            let generation = restoredGeneration.read()
            Task(priority: .utility) { [weak self, previousTranscriber] in
                defer { restoredRouteLease.finish() }
                await self?.dispatchTranscription(
                    wav: buffered.wav, source: buffered.source,
                    generation: generation, using: previousTranscriber,
                    engine: settings.engine, capturedAt: buffered.capturedAt)
            }
        }
        Task { await failedInstantTranscriber.shutdown() }
        lastError = "Мгновенная расшифровка не запустилась: \(message) Продолжаем на «\(settings.engine.advantageTitle)»."
    }

    /// Prepare the snapshot selected for a fresh recording. Reuse a matching
    /// warm local pipeline, but unload it before moving to cloud or a new model.
    private func prepareTranscriberForRecording(engine: TranscriptionEngine,
                                                 language: String,
                                                 glossary: String = Config.transcriptionGlossary,
                                                 localModel: String = Config.localWhisperModel) async {
        guard managesTranscriberLifecycle else { return }
        let desiredLocalModel = engine == .local ? localModel : nil
        guard transcriberEngine != engine
                || transcriberLocalModel != desiredLocalModel
                || transcriberLanguage != language
                || transcriberGlossary != glossary else { return }
        await transcriber.shutdown()
        transcriber = transcriptionServiceFactory(
            engine, language, glossary, localModel, nil)
        transcriberEngine = engine
        transcriberLocalModel = desiredLocalModel
        transcriberLanguage = language
        transcriberGlossary = glossary
        transcriptionState = .idle
    }

    private func applyTranscriptionPerformanceRecommendation(
        _ recommendation: TranscriptionPerformanceRecommendation
    ) {
        switch recommendation {
        case .lighterLocalModel(let current, let recommended):
            guard Config.transcriptionEngineValue == .local,
                  Config.localWhisperModel == current else { return }
            Config.localModelSelectionProvenance = .adaptive
            Config.localWhisperModel = recommended
            transcriptionPerformanceNotice = TranscriptionPerformanceNotice(
                message: "On-device captions are falling behind. Cruxwing will use \(LocalWhisperModel.title(for: recommended)) (\(recommended)) instead of \(current) for the next recording; audio stays on this Mac.",
                action: .none
            )
        case .coolerLocalModel(let current, let recommended):
            guard Config.transcriptionEngineValue == .local,
                  Config.localWhisperModel == current else { return }
            Config.localModelSelectionProvenance = .adaptive
            Config.localWhisperModel = recommended
            transcriptionPerformanceNotice = TranscriptionPerformanceNotice(
                message: "Your Mac is running hot while transcribing. Cruxwing will use the lighter \(LocalWhisperModel.title(for: recommended)) (\(recommended)) model for the next recording to keep it cool; audio stays on this Mac.",
                action: .none
            )
        case .offerDeepgram:
            guard Config.transcriptionEngineValue == .local,
                  Config.localWhisperModel == "base",
                  Config.engineAvailable(.deepgram) else { return }
            transcriptionPerformanceNotice = TranscriptionPerformanceNotice(
                message: "On-device captions are falling behind on the lightest validated local model. Deepgram can reduce Mac load for the next recording, but sends meeting audio to the cloud.",
                action: .useDeepgram
            )
        }
    }

    func useRecommendedDeepgramForNextRecording() {
        guard transcriptionEngineAvailability(.deepgram) else { return }
        Config.transcriptionEngineValue = .deepgram
        // During a live/starting/paused call this is only a NEXT-call choice.
        // Publishing it now would claim cloud while the active Local route was
        // never rerouted (and paused/starting routes deliberately cannot be).
        switch status {
        case .idle, .error:
            selectedTranscriptionEngine = .deepgram
        case .starting, .recording, .paused, .stopping:
            break
        }
        transcriptionPerformanceNotice = nil
    }

    func dismissTranscriptionPerformanceNotice() {
        transcriptionPerformanceNotice = nil
    }

    // MARK: - Deepgram live streaming

    /// Open two Deepgram sessions (system diarized, mic single-speaker) and feed
    /// them the mono-16k PCM the chunkers convert. The chunkers do no Whisper
    /// transcription in this mode — they're used purely as converters, unless a
    /// mid-call credit cap flips the degrade state and they start feeding
    /// on-device Whisper instead.
    ///
    /// Auth: a baked/BYO key bills the operator's own Deepgram account. Keyless
    /// builds mint short-lived tokens from the backend — every grant re-checks
    /// compute credits, and both streams heartbeat their sent audio into the
    /// shared credit pool (two tracks: you + the room).
    private func startDeepgram(
        chunkSeconds: Double,
        generationToken: RecordingGenerationToken,
        language: String,
        keyterms: [String],
        reusingSystemChunker: AudioChunkBuffer? = nil,
        reusingMicChunker: AudioChunkBuffer? = nil,
        restoreOnFailedHandoff: RecordingSettingsSnapshot? = nil,
        restoreTranscriberOnFailedHandoff: TranscriptionService? = nil,
        restoreRouteLeaseOnFailedHandoff: TranscriptionRouteLease? = nil
    ) {
        let auth: DeepgramAuth
        if let deepgramAuthOverride {
            auth = deepgramAuthOverride
        } else {
            let bakedKey = Config.deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            auth = bakedKey.isEmpty
                ? .grant { try await DeepgramBackend.grantToken() }
                : .key(bakedKey)
        }
        let degrade = LiveStreamDegradeState()
        let degradeRouteLease = TranscriptionRouteLease()
        let handoffState = restoreOnFailedHandoff.map { _ in DeepgramHandoffState() }
        let preReadyBuffer = handoffState.map { _ in DeepgramPreReadyBuffer() }
        let deliverResult: (DeepgramPreReadyBuffer.Result) -> Void = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.chunkGeneration == generationToken.read() else { return }
                self.appendStreamed(
                    text: result.text, source: result.source,
                    speakerIndex: result.speakerIndex, at: result.receivedAt)
            }
        }
        let receiveResult: (
            String, TranscriptSource, Int?
        ) -> Void = { text, source, speakerIndex in
            let result = DeepgramPreReadyBuffer.Result(
                text: text, source: source, speakerIndex: speakerIndex,
                receivedAt: generationToken.timestampForStreamingResult())
            guard let preReadyBuffer else {
                deliverResult(result)
                return
            }
            switch preReadyBuffer.stage(result) {
            case .buffered, .discard:
                return
            case .deliver(let committed):
                deliverResult(committed)
            }
        }
        let completeHandoffIfReady: (Bool) -> Void = { [weak self] ready in
            guard ready else { return }
            for result in preReadyBuffer?.commitSuccessful() ?? [] {
                deliverResult(result)
            }
            guard let previousTranscriber = restoreTranscriberOnFailedHandoff,
                  let previousRouteLease = restoreRouteLeaseOnFailedHandoff else { return }
            Task { @MainActor [weak self] in
                self?.completeDeepgramHandoff(
                    previous: previousTranscriber, routeLease: previousRouteLease)
            }
        }
        let markHandoffReady: (DeepgramHandoffState.Track) -> Void = { track in
            completeHandoffIfReady(handoffState?.markReady(track) == true)
        }
        let restorePreviousIfNeeded: (
            String
        ) -> DeepgramHandoffState.FailureDisposition = { [weak self] message in
            guard let settings = restoreOnFailedHandoff,
                  let previousTranscriber = restoreTranscriberOnFailedHandoff,
                  let handoffState else { return .healthyStream }
            let disposition = handoffState.claimPreReadyFailure()
            if disposition == .claimedRollback {
                Task { @MainActor [weak self] in
                    self?.restoreEngineAfterFailedDeepgramHandoff(
                        settings, transcriber: previousTranscriber,
                        routeLease: restoreRouteLeaseOnFailedHandoff,
                        preReadyBuffer: preReadyBuffer,
                        generationToken: generationToken, message: message)
                }
            }
            return disposition
        }

        let system = deepgramStreamerFactory(auth, true, language, keyterms)
        system.onReady = { markHandoffReady(.system) }
        system.onTerminalFailure = { [weak self] message in
            guard restorePreviousIfNeeded(message) == .healthyStream else { return }
            Task { @MainActor [weak self] in
                self?.degradeLiveStreamToLocal(
                    message: message, generationToken: generationToken,
                    state: degrade, routeLease: degradeRouteLease)
            }
        }
        system.onResult = { text, speaker in
            receiveResult(text, .system, speaker)
        }
        system.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self,
                      self.recordingGenerationToken === generationToken,
                      self.status == .starting || self.status == .recording else { return }
                self.lastError = "Deepgram: \(message)"
            }
        }
        // FIFO main-queue delivery (not two racing Tasks) so a late interim can't
        // land after the clear that a final already posted.
        system.onInterim = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          self.chunkGeneration == generationToken.read(),
                          self.status == .recording else { return }
                    self.setProvisional(text, source: .system)
                }
            }
        }
        let mic = deepgramStreamerFactory(auth, false, language, keyterms)
        mic.onReady = { markHandoffReady(.microphone) }
        mic.onTerminalFailure = { [weak self] message in
            guard restorePreviousIfNeeded(message) == .healthyStream else { return }
            Task { @MainActor [weak self] in
                self?.degradeLiveStreamToLocal(
                    message: message, generationToken: generationToken,
                    state: degrade, routeLease: degradeRouteLease)
            }
        }
        mic.onResult = { text, _ in
            receiveResult(text, .mic, nil)
        }
        mic.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self,
                      self.recordingGenerationToken === generationToken,
                      self.status == .starting || self.status == .recording else { return }
                self.lastError = "Deepgram, микрофон: \(message)"
            }
        }
        mic.onInterim = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          self.chunkGeneration == generationToken.read(),
                          self.status == .recording else { return }
                    self.setProvisional(text, source: .mic)
                }
            }
        }
        // Metered (grant) mode: both streams report sent audio into the credit
        // pool; a cap — at grant time or on a heartbeat — degrades this session
        // to on-device Whisper instead of killing the transcript.
        if auth.isMetered {
            let reporter: (Int) async -> DeepgramUsageVerdict = { chunks in
                await DeepgramBackend.reportUsage(chunks: chunks)
            }
            let fallback: (String) -> Void = { [weak self] message in
                guard restorePreviousIfNeeded(message) == .healthyStream else { return }
                Task { @MainActor [weak self] in
                    self?.degradeLiveStreamToLocal(message: message,
                                                   generationToken: generationToken,
                                                   state: degrade,
                                                   routeLease: degradeRouteLease)
                }
            }
            system.usageReporter = reporter
            mic.usageReporter = reporter
            system.onFallback = fallback
            mic.onFallback = fallback
        }

        systemStreamer = system
        micStreamer = mic
        system.start()
        mic.start()

        // A network black hole is different from a definitive auth failure:
        // each streamer will keep reconnecting, so neither emits
        // `onTerminalFailure`. Bound only the pre-ready handoff interval. Once
        // both tracks have delivered a server message, `claimPreReadyFailure`
        // reports `.healthyStream` and normal reconnect semantics resume.
        if handoffState != nil {
            Task {
                try? await Task.sleep(
                    nanoseconds: DeepgramHandoffState.readinessTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                _ = restorePreviousIfNeeded("Connection timed out before both audio tracks became ready.")
            }
        }

        // Capture the streamers locally so the audio-thread tap never touches
        // the @MainActor `systemStreamer`/`micStreamer` properties (data race).
        // `send` is a no-op once the streamer is finished.
        //
        // The chunk callbacks are dormant while the streams carry the
        // transcript; after a credit-cap degrade they feed the same chunks to
        // on-device Whisper — the taps keep their chunker references, nothing
        // is rebuilt mid-recording.
        let systemFallbackHandler: AudioChunkBuffer.ChunkHandler = { [weak self] wav, timing in
            let capturedAt = generationToken.captureStart(
                duration: timing.captureSpan)
            if preReadyBuffer?.capture(
                wav: wav, duration: timing.audioDuration, source: .system,
                capturedAt: capturedAt) == true { return }
            guard let transcriber = degrade.activeTranscriber() else { return }
            guard degradeRouteLease.begin() else { return }
            let generation = generationToken.read()
            Task(priority: .utility) {
                defer { degradeRouteLease.finish() }
                await self?.dispatchTranscription(wav: wav, source: .system,
                                                  generation: generation,
                                                  using: transcriber,
                                                  engine: .local,
                                                  capturedAt: capturedAt)
            }
        }
        let recorder = sessionRecorder
        let keepRecordingForDiarization = shouldCollectRetainedAudio(on: .deepgram)
        let systemSamples: ([Int16]) -> Void = { [weak system] samples in
            system?.send(samples)
            if keepRecordingForDiarization { recorder.append(samples) }
        }
        let liveSystemChunker = reusingSystemChunker ?? AudioChunkBuffer(
            chunkSeconds: chunkSeconds, label: "system-stream",
            onChunk: systemFallbackHandler)
        liveSystemChunker.reconfigure(
            onChunk: systemFallbackHandler,
            onSamples: systemSamples,
            discardBufferedSamples: reusingSystemChunker != nil,
            flushBufferedSamplesToPreviousHandler: reusingSystemChunker != nil)
        liveSystemChunker.vadThreshold = VoiceActivity.systemAudioThreshold

        let micFallbackHandler: AudioChunkBuffer.ChunkHandler = { [weak self] wav, timing in
            let capturedAt = generationToken.captureStart(
                duration: timing.captureSpan)
            if preReadyBuffer?.capture(
                wav: wav, duration: timing.audioDuration, source: .mic,
                capturedAt: capturedAt) == true { return }
            guard let transcriber = degrade.activeTranscriber() else { return }
            guard degradeRouteLease.begin() else { return }
            let generation = generationToken.read()
            Task(priority: .utility) {
                defer { degradeRouteLease.finish() }
                await self?.dispatchTranscription(wav: wav, source: .mic,
                                                  generation: generation,
                                                  using: transcriber,
                                                  engine: .local,
                                                  capturedAt: capturedAt)
            }
        }
        let micSamples: ([Int16]) -> Void = { [weak mic] samples in
            mic?.send(samples)
        }
        let liveMicChunker = reusingMicChunker ?? AudioChunkBuffer(
            chunkSeconds: chunkSeconds, label: "mic-stream",
            onChunk: micFallbackHandler)
        liveMicChunker.reconfigure(
            onChunk: micFallbackHandler,
            onSamples: micSamples,
            discardBufferedSamples: reusingMicChunker != nil,
            flushBufferedSamplesToPreviousHandler: reusingMicChunker != nil)

        systemChunker = liveSystemChunker
        micChunker = liveMicChunker
        completeHandoffIfReady(handoffState?.markRoutesCutOver() == true)
    }

    /// Complete a Deepgram failure that arrived before capture initialization
    /// finished. Internal so the deterministic handoff suite can exercise the
    /// same post-reset edge without opening ScreenCaptureKit hardware.
    func applyPendingStartupLocalFallbackIfNeeded() {
        guard status == .recording,
              let pending = pendingStartupLocalFallback else { return }
        pendingStartupLocalFallback = nil
        degradeLiveStreamToLocal(
            message: pending.message,
            generationToken: pending.generationToken,
            state: pending.state,
            routeLease: pending.routeLease)
    }

    /// Mid-call credit cap on a metered live stream: finish both sockets and
    /// hand the already-running chunkers to on-device Whisper. Idempotent —
    /// system and mic streams both hit the cap and race to call this.
    private func degradeLiveStreamToLocal(message: String,
                                          generationToken: RecordingGenerationToken,
                                          state: LiveStreamDegradeState,
                                          routeLease: TranscriptionRouteLease) {
        guard recordingGenerationToken === generationToken,
              status == .recording || status == .starting,
              !state.isActive else { return }

        if status == .starting {
            // `resetForNewRecording` runs only after both captures start. Let
            // it establish the new session first, then apply this exact route
            // fallback once; otherwise it erases the Local recorder boundary
            // and prepared-model provenance immediately after we create them.
            if pendingStartupLocalFallback == nil {
                pendingStartupLocalFallback = PendingStartupLocalFallback(
                    message: message,
                    generationToken: generationToken,
                    state: state,
                    routeLease: routeLease)
            }
            return
        }

        let fallbackBoundary = Date()
        let nextRouteStart = generationToken.transitionFromStreamingToChunked(
            at: fallbackBoundary)
        latestStreamingRouteRetiredAt = fallbackBoundary
        systemStreamer?.finish()
        micStreamer?.finish()

        let localSpeakerRetentionEnabled =
            activeRecordingSettings?.localDiarization ?? false
        if (Config.transcriptionPostStopFinalPassEnabled
                || localSpeakerRetentionEnabled),
           sessionRetainedAudioTimelineValid {
            // Drop the unfinished cloud window, then retain only PCM captured
            // after the private fallback boundary. Cloud transcript rows stay
            // intact; the final pass may refine only this Local suffix.
            systemChunker?.discardBufferedSamples()
            micChunker?.discardBufferedSamples()
            let wasAlreadyRetaining = hasSessionDiarizationAudioConsumer
            beginLocalPostprocessSuffix(at: nextRouteStart)
            let recorder = sessionRecorder
            if !wasAlreadyRetaining {
                systemChunker?.addSampleObserver { samples in recorder.append(samples) }
            }
        }

        // Preserve the immutable recording snapshot. A Settings edit during a
        // call must not silently change fallback language, glossary, or model.
        // In Auto, a clearly Cyrillic accepted transcript may seed the first
        // local generation while `multi` stays active for real code-switches.
        let settings = activeRecordingSettings
        let configuredLanguage = settings?.language
            ?? activeSessionLanguage
            ?? transcriberLanguage
            ?? Config.transcriptionLanguage
        let recentText = transcript.suffix(40).map(\.text).joined(separator: " ")
        let autoLanguageHint = LocalWhisperTranscription.fallbackAutoLanguageHint(
            configured: configuredLanguage, recentText: recentText)
        let fallbackGlossary = settings?.glossary
            ?? transcriberGlossary
            ?? Config.transcriptionGlossary
        let fallbackModel = settings?.localModel
            ?? transcriberLocalModel
            ?? Config.localWhisperModel
        let local = transcriptionServiceFactory(
            .local,
            configuredLanguage,
            fallbackGlossary,
            fallbackModel,
            autoLanguageHint)
        state.activate(local)
        let previousTranscriber = transcriber
        transcriber = local
        transcriberEngine = .local
        transcriberLocalModel = fallbackModel
        transcriberLanguage = configuredLanguage
        transcriberGlossary = fallbackGlossary
        activeSessionEngine = .local
        activeSessionPreparedLocalWhisperModel = local is LocalWhisperTranscription
            ? fallbackModel : nil
        localFinalPassContinuityValid = localFinalPassOptedInForSession
            && sessionAudioStart != nil
            && activeSessionPreparedLocalWhisperModel != nil
        localDiarizationContinuityValid = localDiarizationOptedInForSession
            && sessionAudioStart != nil
        activeRecordingSettings = activeRecordingSettings?.replacingEngine(with: .local)
        activeChunkRouteLease = routeLease
        pendingEngineChange = nil
        selectedTranscriptionEngine = .local
        // First chunks may wait on the model load; the service queues them.
        Task { try? await local.prewarm() }
        Task { await previousTranscriber.shutdown() }

        Log.transcribe.notice(
            "live fallback uses local model=\(fallbackModel, privacy: .public) language=\(configuredLanguage, privacy: .public) autoHint=\(autoLanguageHint ?? "none", privacy: .public)")

        transcriptionPerformanceNotice = TranscriptionPerformanceNotice(
            message: message + " Transcription continues on-device for the rest of this call.",
            action: .none
        )
    }

    private func appendStreamed(
        text: String,
        source: TranscriptSource,
        speakerIndex: Int?,
        at timestamp: Date = Date()
    ) {
        ingestStreamedLine(text: text, source: source,
                           speaker: speakerIndex.map { "Speaker \(Self.speakerLetter($0))" },
                           transcriptionEngine: .deepgram, at: timestamp)
    }

    /// When Stop was pressed. `nil` while recording or before the first call.
    private(set) var recordingStoppedAt: Date?

    /// How long after Stop a streamed line may still be accepted.
    ///
    /// Deepgram keeps its socket open briefly after Stop to deliver the final
    /// recognition of the last utterance, and losing that clips the end of the
    /// meeting — so a window is right. An UNBOUNDED window is not: the guard in
    /// the streamer callbacks compares `chunkGeneration` against a token that
    /// Stop deliberately retags to the new generation, so it stops rejecting
    /// anything, and `ingestStreamedLine` persists whenever `status !=
    /// .recording`. Between them, a result arriving at any later time was
    /// appended — which is how a YouTube video watched AFTER Stop ended up in
    /// the transcript.
    ///
    /// Three seconds covers a trailing final comfortably. Anything later is not
    /// the tail of the meeting; it is audio the user believes was never
    /// recorded, and it must never reach the transcript, the disk, or a prompt.
    static let postStopGraceWindow: TimeInterval = 3

    /// Refinement must not snapshot while a stopped or just-retired stream may
    /// still publish its final. Task-local so focused tests can remove the wall
    /// clock wait without weakening the shipped boundary.
    @TaskLocal static var streamedFinalDrainGraceWindow: TimeInterval = 3

    static func streamedFinalDrainBoundaryAtStop(
        hadActiveStream: Bool,
        previouslyRetiredAt: Date?,
        stopBoundary: Date
    ) -> Date? {
        // A stream retired earlier in a mixed Instant -> Private call can still
        // enqueue a provider-delayed final after Stop. Rebase the bounded
        // stability barrier to Stop rather than the old handoff time.
        (hadActiveStream || previouslyRetiredAt != nil) ? stopBoundary : nil
    }

    static func remainingStreamedFinalDrainDelay(
        retiredAt: Date?,
        now: Date
    ) -> TimeInterval {
        guard let retiredAt else { return 0 }
        return max(0, streamedFinalDrainGraceWindow
            - max(0, now.timeIntervalSince(retiredAt)))
    }

    /// The one line-ingestion path: trim, dedup, append, persist-after-stop.
    /// Internal (not private) so the dev-build live-test hooks can feed
    /// synthetic lines through EXACTLY the pipeline real audio uses — an edge
    /// test that bypassed dedup would prove nothing about it.
    func ingestStreamedLine(text: String, source: TranscriptSource, speaker: String? = nil,
                            transcriptionEngine: TranscriptionEngine? = nil,
                            at timestamp: Date = Date()) {
        let deechoed = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: text, source: source, recent: transcript, at: timestamp)
        let clean = deechoed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // The privacy boundary. Placed at ingestion rather than in each
        // streamer callback so every producer — Deepgram, on-device Whisper,
        // a post-stop flush — is bounded by the same rule.
        if !isRecording, let stoppedAt = recordingStoppedAt,
           Date().timeIntervalSince(stoppedAt) > Self.postStopGraceWindow {
            Log.transcribe.error(
                "dropped a transcript line arriving \(Int(Date().timeIntervalSince(stoppedAt)), privacy: .public)s after Stop — capture had ended")
            return
        }
        let engine = transcriptionEngine
            ?? ((status == .recording || status == .starting || status == .stopping)
                ? activeSessionEngine : nil)
        let entry = TranscriptEntry(
            source: source, text: clean, timestamp: timestamp, speaker: speaker,
            transcriptionEngine: engine)
        guard admitTranscriptEntry(entry) else { return }
        if status != .recording {
            // Deepgram intentionally keeps its socket alive briefly after Stop
            // to deliver final recognition. Update the stopped session on disk,
            // just like the local final-partial path does.
            persistCurrentSession()
        }
    }

    /// Admit one finalized line with source preference and capture-time order.
    /// A cleaner system final can replace its earlier microphone echo; all
    /// other duplicates retain the existing first-arrival behavior. Delayed
    /// pre-handoff Local chunks are inserted by capture time, so allowing them
    /// to finish cannot scramble the transcript around newer Instant rows.
    @discardableResult
    private func admitTranscriptEntry(_ entry: TranscriptEntry) -> Bool {
        if Config.transcriptDeduplicationEnabled,
           let echoedMic = TranscriptDeduplicator.preferredMicEchoIndex(
               forSystem: entry, in: transcript) {
            transcript.remove(at: echoedMic)
            Log.transcribe.debug(
                "replaced earlier microphone echo with cleaner system transcript")
        }
        guard !isDuplicateTranscriptLine(entry) else { return false }
        if let insertion = transcript.firstIndex(where: { $0.timestamp > entry.timestamp }) {
            transcript.insert(entry, at: insertion)
        } else {
            transcript.append(entry)
        }
        return true
    }

    /// Dev-hook diagnostic seam. Counts remain available after Stop so the
    /// artifact can prove that both capture sources stayed live through the
    /// complete playback, even when VAD/AEC intentionally emitted no mic text.
    func liveTestAudioDiagnostics() -> (
        system: AudioTrackDiagnosticSnapshot,
        mic: AudioTrackDiagnosticSnapshot,
        voiceProcessingActive: Bool,
        outputRoute: String,
        outputLevel: String
    ) {
        (
            systemCaptureDiagnostics.snapshot(),
            micCaptureDiagnostics.snapshot(),
            micCapture.voiceProcessingActive,
            AudioRoute.describeOutput(),
            AudioRoute.describeOutputLevel()
        )
    }

    /// Dev-build test seam: latch the quota gate exactly as a live 429 would.
    /// The edge-test driver cannot make the real backend refuse on cue, and a
    /// latch that can only be tested by emptying a real pool goes untested.
    func debugLatchQuota(message: String) {
        guard Config.isDevBuild else { return }
        noteQuotaExhaustion(LLMError.http(
            "Backend", 429, #"{"error":"\#(message)","upgrade":true}"#))
    }

    /// Dev-build companion to `debugLatchQuota`: lets the video/UI harness
    /// render a mandatory notice over active playback, capture it, and then
    /// continue with later prompt types without starting a different call.
    func debugClearQuotaLatch() {
        guard Config.isDevBuild else { return }
        copilotQuotaMessage = nil
    }

    /// Drop a line that repeats speech already captured — the meeting playing
    /// through speakers is heard by the microphone too, so remote speech
    /// reappears under the local label, and chunked Whisper re-emits its own
    /// tail. Only the recent tail is compared; the same sentence said again
    /// later in the call is genuine and kept.
    private func isDuplicateTranscriptLine(_ entry: TranscriptEntry) -> Bool {
        guard Config.transcriptDeduplicationEnabled else { return false }
        // Reject self-evident decoder noise before neighbour comparison: a
        // bare connective, or a line made solely of prompt-biased glossary
        // terms. Real one-word replies are excluded by the closed list.
        if TranscriptDeduplicator.isNoiseArtifact(entry, glossary: Config.glossaryTerms) {
            Log.transcribe.debug("dropped noise artifact (\(entry.source == .mic ? "mic" : "system", privacy: .public))")
            return true
        }
        // Tail selected BY TIME, not by a fixed count. The deduplicator's window
        // is 14s, but this passed `suffix(12)`: when chunks fragment into many
        // short lines, the true duplicate can sit inside the time window and yet
        // outside the last twelve entries, so it was never compared. Capped at 40
        // so a pathological burst cannot turn this into a long scan.
        let cutoff = entry.timestamp.addingTimeInterval(-TranscriptDeduplicator.window)
        let tail = Array(transcript.suffix(40).filter { $0.timestamp >= cutoff })
        // Refresh the quality read on every appended line — it is the same tick,
        // and quality changes within a call (someone joins from a car).
        speechQualityIsPoor = SpeechQualityMonitor.shared.isPoor
        guard TranscriptDeduplicator.isDuplicate(entry, of: tail) else {
            // Near-misses are the whole diagnostic story for "sometimes it still
            // duplicates". Without this the only observable is the drop, so a MISS
            // leaves no trace and the thresholds can only be guessed at.
            if let near = TranscriptDeduplicator.closestScore(entry, of: tail),
               near.score >= TranscriptDeduplicator.similarityThreshold - 0.15 {
                Log.transcribe.info(
                    "dedup near-miss \(String(format: "%.2f", near.score), privacy: .public) vs threshold \(String(format: "%.2f", TranscriptDeduplicator.similarityThreshold), privacy: .public) — kept")
            }
            return false
        }
        Log.transcribe.debug("dropped duplicate transcript line (\(entry.source == .mic ? "mic" : "system", privacy: .public))")
        return true
    }

    /// Update the provisional (interim) line for a source; empty clears it.
    private func setProvisional(_ text: String, source: TranscriptSource) {
        let deechoed = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: text, source: source, recent: transcript)
        let clean = deechoed.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            guard provisional[source] != nil else { return }
            provisional[source] = nil
        } else {
            guard provisional[source] != clean else { return }
            provisional[source] = clean
        }
    }

    /// Test seam for the private Deepgram callback path. It traverses the same
    /// cumulative-echo filter as a real interim without opening audio hardware
    /// or a provider socket.
    func applyTestProvisionalLine(_ text: String, source: TranscriptSource) {
        guard Self.isUnderTest else { return }
        setProvisional(text, source: source)
    }

    /// 0 → "A", 1 → "B", … (clamped). Pure — usable off the main actor.
    nonisolated static func speakerLetter(_ index: Int) -> String {
        let clamped = max(0, min(index, 25))
        return String(UnicodeScalar(UInt8(65 + clamped)))
    }
}
