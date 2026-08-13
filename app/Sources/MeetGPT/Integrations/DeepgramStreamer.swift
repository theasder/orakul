import Foundation

/// A parsed outcome of one Deepgram message, in emission order. Keeps the
/// message-decoding logic pure (and testable) — the streamer just maps these to
/// its `onInterim` / `onResult` callbacks.
enum DeepgramEvent: Equatable {
    case interim(String)
    case result(text: String, speaker: Int?)
    case clearInterim
}

/// FIFO replay buffer of pending audio frames, byte-capped. Appends push to the
/// back; the drain pops the front; a failed send re-inserts at the front; and
/// appends past the cap drop the OLDEST frames (a deliberate gap) so memory
/// stays bounded under a sustained outage. Pure value type — the streamer holds
/// one under its lock.
struct ReplayBuffer {
    private(set) var frames: [[Int16]] = []
    private(set) var byteCount = 0
    let byteCap: Int

    init(byteCap: Int) { self.byteCap = byteCap }

    var isEmpty: Bool { frames.isEmpty }

    mutating func append(_ samples: [Int16]) {
        frames.append(samples)
        byteCount += samples.count * 2
        trim()
    }

    mutating func popFront() -> [Int16]? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        byteCount -= frame.count * 2
        return frame
    }

    mutating func requeueFront(_ samples: [Int16]) {
        frames.insert(samples, at: 0)
        byteCount += samples.count * 2
        trim()
    }

    private mutating func trim() {
        while byteCount > byteCap, !frames.isEmpty {
            byteCount -= frames.removeFirst().count * 2
        }
    }
}

/// Narrow transport seam for deterministic lifecycle tests. Production leaves
/// every closure nil, preserving URLSession's WebSocket implementation. Tests
/// can instead create a dormant socket, observe start/receive wiring, and
/// acknowledge sends without opening a network connection.
struct DeepgramTransportOverrides {
    let makeSocket: ((URLRequest) -> URLSessionWebSocketTask)?
    let startSocket: ((URLSessionWebSocketTask) -> Void)?
    let beginReceiving: ((URLSessionWebSocketTask) -> Void)?
    let sendMessage: ((URLSessionWebSocketTask, URLSessionWebSocketTask.Message) async throws -> Void)?

    init(
        makeSocket: ((URLRequest) -> URLSessionWebSocketTask)? = nil,
        startSocket: ((URLSessionWebSocketTask) -> Void)? = nil,
        beginReceiving: ((URLSessionWebSocketTask) -> Void)? = nil,
        sendMessage: ((URLSessionWebSocketTask, URLSessionWebSocketTask.Message) async throws -> Void)? = nil
    ) {
        self.makeSocket = makeSocket
        self.startSocket = startSocket
        self.beginReceiving = beginReceiving
        self.sendMessage = sendMessage
    }
}

/// Streams PCM16 (mono 16 kHz) audio to Deepgram's live transcription
/// WebSocket and emits finalized transcript segments, with a speaker index when
/// diarization is enabled. One instance per audio source.
///
/// Resilience (Phase 0): the socket auto-reconnects with exponential backoff +
/// jitter after an unexpected drop, and audio produced while the socket is down
/// is held in a bounded replay buffer and re-sent — in order — on reconnect, so
/// a network blip no longer silently tears a hole in the transcript. Under
/// sustained backpressure the oldest buffered audio is dropped to keep memory
/// bounded. All socket writes go through a single-consumer drain so frames stay
/// FIFO even across a mid-flush failure.
final class DeepgramStreamer {
    /// (transcript, speakerIndex?) for each finalized segment.
    var onResult: ((String, Int?) -> Void)?
    /// The in-progress (provisional) utterance; empty string means "clear it".
    var onInterim: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// The socket has delivered at least one message, proving the optimistic
    /// WebSocket open actually became usable. AppState uses this to distinguish
    /// a failed mid-call handoff from a later reconnect.
    var onReady: (() -> Void)?
    /// An unrecoverable setup/auth failure. This is separate from `onError`,
    /// which also carries the non-terminal "reconnecting" notice.
    var onTerminalFailure: ((String) -> Void)?
    /// Terminal credit/config failure in grant mode: the stream cannot
    /// continue and the caller should degrade this session on-device. Fired
    /// at most once; the streamer finishes itself right after.
    var onFallback: ((String) -> Void)?
    /// Metered (grant) mode only: called with elapsed 6-second chunks of audio
    /// actually sent to Deepgram. Returns the server's verdict; `.capped`
    /// stops the stream via `onFallback`.
    var usageReporter: ((Int) async -> DeepgramUsageVerdict)?

    private let auth: DeepgramAuth
    private let diarize: Bool
    /// Deepgram language. "multi" = nova-3 multilingual auto (code-switching
    /// across 10 languages incl. Russian); or a fixed code like "ru"/"en".
    private let language: String
    /// Immutable across reconnects; a Settings edit is for the next recording.
    private let keyterms: [String]
    private let transportOverrides: DeepgramTransportOverrides
    private let session = URLSession(configuration: .default)
    private let lock = NSLock()

    private enum State { case idle, connecting, open, reconnecting, closed }
    private var state: State = .idle
    private var task: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// At most one drain runs at a time — this is the single-consumer guard that
    /// keeps replayed frames in FIFO order.
    private var draining = false

    /// Audio not yet confirmed sent on an open socket (FIFO, front = oldest).
    /// Held as raw Int16 samples and serialized to PCM16 only in the drain, so
    /// the byte conversion never runs on the audio render thread. Replayed on
    /// reconnect; trimmed from the front once it exceeds the cap.
    private var outbox = ReplayBuffer(byteCap: DeepgramStreamer.outboxByteCap)
    private var reconnectAttempts = 0
    /// Reset backoff only once a (re)connected socket actually delivers a
    /// message — proving it works, not merely that `resume()` was called.
    private var healthySinceConnect = false

    // Credit metering (grant mode): samples confirmed sent on the socket vs
    // samples already reported to the backend. The delta converts to 6-second
    // chunks on each heartbeat; a failed report keeps the delta and retries.
    private var sentSamples = 0
    private var reportedSamples = 0
    /// Set after a `.capped` verdict so the finish-time flush can't re-report
    /// (and re-trigger the fallback) against an exhausted ledger.
    private var meteringStopped = false
    private var usageHeartbeat: Task<Void, Never>?

    /// ~30 s of mono-16k PCM16 (16000 samples/s × 2 bytes × 30 s). Caps replay
    /// memory; a longer outage drops its oldest audio (a gap) rather than grow.
    private static let outboxByteCap = 16_000 * 2 * 30
    private static let maxReconnectDelay: Double = 15
    /// Surface a soft notice once after this many consecutive failed reconnects.
    private static let notifyAfterAttempts = 6
    /// One credit-metering chunk = 6 s of mono-16k audio (matches the server).
    private static let samplesPerChunk = 16_000 * 6
    private static let usageReportInterval: UInt64 = 60_000_000_000

    init(auth: DeepgramAuth, diarize: Bool, language: String = "multi",
         keyterms: [String] = Config.glossaryTerms,
         transportOverrides: DeepgramTransportOverrides = .init()) {
        self.auth = auth
        self.diarize = diarize
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = lang.isEmpty ? "multi" : lang
        self.keyterms = keyterms
        self.transportOverrides = transportOverrides
    }

    convenience init(apiKey: String, diarize: Bool, language: String = "multi",
                     keyterms: [String] = Config.glossaryTerms) {
        self.init(auth: .key(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
                  diarize: diarize, language: language, keyterms: keyterms)
    }

    /// Regression seam: reconnects must retain the recording's vocabulary.
    func keytermsSnapshot() -> [String] { keyterms }

    // MARK: Lifecycle

    func start() {
        lock.lock()
        guard state == .idle else { lock.unlock(); return }
        lock.unlock()
        openSocket(isReconnect: false)
        startKeepAlive()
        startUsageHeartbeat()
    }

    /// Enqueue mono-16k Int16 samples. Serialization to PCM16 bytes is deferred
    /// to the drain (off the audio render thread that calls this).
    func send(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        let current = state
        guard current != .closed, current != .idle else { lock.unlock(); return }
        enqueueLocked(samples)
        lock.unlock()
        // While reconnecting the frame stays buffered and is replayed on reopen.
        if current == .open { flush() }
    }

    /// Flush and close: tell Deepgram no more audio, let trailing finals arrive,
    /// then tear down the socket. Terminal — no further reconnects.
    func finish() {
        lock.lock()
        let already = (state == .closed)
        state = .closed
        let dyingTask = task
        let ka = keepAlive
        let rt = reconnectTask
        let hb = usageHeartbeat
        lock.unlock()
        guard !already else { return }

        ka?.cancel()
        rt?.cancel()
        hb?.cancel()
        sendControl(["type": "CloseStream"], on: dyingTask)
        // Hold a strong ref through the flush window so trailing final results
        // are still delivered after AppState drops its reference.
        Task {
            // Bill the trailing partial chunk before the reference is dropped.
            await self.reportUsageDelta(final: true)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            dyingTask?.cancel(with: .normalClosure, reason: nil)
            withExtendedLifetime(self) {}
        }
    }

    // MARK: Socket

    private func openSocket(isReconnect: Bool) {
        lock.lock()
        guard state != .closed else { lock.unlock(); return }
        state = .connecting
        healthySinceConnect = false
        lock.unlock()

        switch auth {
        case .key(let key):
            // Permanent key: no network hop — connect synchronously, exactly
            // the pre-grant behavior.
            finishOpen(authHeader: DeepgramAuth.header(key: key), isReconnect: isReconnect)
        case .grant(let provider):
            // Grant tokens have a ~60 s connect-time TTL, so every (re)connect
            // mints a fresh one — which also re-checks the credit cap.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let token = try await provider()
                    self.finishOpen(authHeader: DeepgramAuth.header(grantToken: token),
                                    isReconnect: isReconnect)
                } catch let error as DeepgramGrantError where error.isTerminal {
                    // Out of credits / not configured / signed out: reconnecting
                    // cannot help — hand the session to the on-device fallback.
                    self.onFallback?(error.fallbackMessage)
                    self.finish()
                } catch {
                    // Transient grant failure — same path as a dropped socket:
                    // exponential backoff, fresh token on the next attempt.
                    guard !self.isClosed else { return }
                    self.handleDrop()
                }
            }
        }
    }

    private func finishOpen(authHeader: String, isReconnect: Bool) {
        guard let url = Self.buildURL(language: language, diarize: diarize, keyterms: keyterms) else {
            onTerminalFailure?("Could not build Deepgram URL.")
            onError?("Could not build Deepgram URL.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let socket = transportOverrides.makeSocket?(request)
            ?? session.webSocketTask(with: request)

        // Re-check terminal state under the lock: a finish() may have landed
        // while we were building the request. Without this, we'd resurrect a
        // closed streamer and leak a live socket into an endless reconnect.
        lock.lock()
        guard state != .closed else {
            lock.unlock()
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        self.task = socket
        state = .open   // optimistic; a failed connect surfaces via receive()
        lock.unlock()

        if let startSocket = transportOverrides.startSocket {
            startSocket(socket)
        } else {
            socket.resume()
        }
        if let beginReceiving = transportOverrides.beginReceiving {
            beginReceiving(socket)
        } else {
            receive(on: socket)
        }
        if isReconnect { flush() }   // replay buffered audio onto the new socket
    }

    static func buildURL(language: String, diarize: Bool, keyterms: [String] = []) -> URL? {
        guard var components = URLComponents(string: "wss://api.deepgram.com/v1/listen") else { return nil }
        var items: [URLQueryItem] = [
            .init(name: "model", value: "nova-3"),
            // "multi" enables nova-3 multilingual auto-detection / code-switching
            // (incl. Russian) so speech isn't force-decoded as English.
            .init(name: "language", value: language),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "punctuate", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "interim_results", value: "true"),
            // Deepgram's recommended endpointing for code-switching.
            .init(name: "endpointing", value: "100")
        ]
        if diarize {
            // `diarize=true` is Deepgram's deprecated, permanently-v1 alias.
            // The versioned streaming selector keeps the request on the newest
            // GA streaming diarizer while preserving the same word-level
            // speaker response contract. Never send both parameters: Deepgram
            // rejects that combination.
            items.append(.init(name: "diarize_model", value: "latest"))
        }
        // Custom vocabulary — nova-3 keyterm prompting biases toward these
        // exact spellings (one query item per term).
        for term in keyterms { items.append(.init(name: "keyterm", value: term)) }
        components.queryItems = items
        return components.url
    }

    // MARK: Send buffer (replay + backpressure)

    private func enqueueLocked(_ samples: [Int16]) {
        outbox.append(samples)   // byte-cap trim happens inside the buffer
    }

    /// Kick the drain if one isn't already running. `draining` makes the drain a
    /// single consumer, so frames leave in FIFO order and a failed frame that is
    /// re-buffered can't be reordered by a concurrent sender.
    private func flush() {
        lock.lock()
        guard state == .open, task != nil, !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        Task { [weak self] in await self?.drainOutbox() }
    }

    private func drainOutbox() async {
        // Lock access is delegated to synchronous helpers — taking the NSLock
        // directly inside this async function is a Swift 6 error.
        defer { finishDraining() }
        while let (socket, frame) = dequeueForSend() {
            do {
                // Serialize to PCM16 bytes here (off the audio thread), not at send().
                let message = URLSessionWebSocketTask.Message.data(Self.pcm16LE(frame))
                if let sendMessage = transportOverrides.sendMessage {
                    try await sendMessage(socket, message)
                } else {
                    try await socket.send(message)
                }
                recordSent(sampleCount: frame.count)
            } catch {
                // Re-buffer the unsent frame (single consumer → no reordering) and
                // fold into a reconnect iff this socket is still the live one — a
                // failure on an already-replaced socket must not tear down its
                // successor.
                let stillCurrent = requeueFailed(frame, socket: socket)
                if stillCurrent, !isClosed { handleDrop() }
                return
            }
        }
    }

    /// Pop the next frame + live socket, or nil if nothing to send right now.
    private func dequeueForSend() -> (URLSessionWebSocketTask, [Int16])? {
        lock.lock(); defer { lock.unlock() }
        guard state == .open, let socket = task, let frame = outbox.popFront() else { return nil }
        return (socket, frame)
    }

    /// Put a failed frame back at the front (in order); returns whether its
    /// socket is still current (i.e. whether the caller should reconnect).
    private func requeueFailed(_ frame: [Int16], socket: URLSessionWebSocketTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        outbox.requeueFront(frame)
        return task === socket
    }

    private func finishDraining() {
        lock.lock(); defer { lock.unlock() }
        draining = false
    }

    /// Int16 samples → little-endian PCM16 bytes (Deepgram `linear16`). Apple
    /// platforms are little-endian, so the sample bytes are already correct.
    static func pcm16LE(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    // MARK: Credit metering (grant mode)

    /// Unreported sent audio → whole 6-second chunks. Heartbeats floor (the
    /// remainder carries to the next beat); the finish-time flush ceils so a
    /// trailing partial chunk is still billed. Pure — unit-tested.
    static func chunksToReport(sentSamples: Int, reportedSamples: Int, final: Bool = false) -> Int {
        let delta = max(0, sentSamples - reportedSamples)
        if final { return (delta + samplesPerChunk - 1) / samplesPerChunk }
        return delta / samplesPerChunk
    }

    private func recordSent(sampleCount: Int) {
        guard auth.isMetered else { return }
        lock.lock()
        sentSamples += sampleCount
        lock.unlock()
    }

    private func startUsageHeartbeat() {
        guard auth.isMetered, usageReporter != nil else { return }
        let heartbeat = Task { [weak self] in
            while !(self?.isClosed ?? true) {
                try? await Task.sleep(nanoseconds: Self.usageReportInterval)
                guard let self, !self.isClosed else { return }
                await self.reportUsageDelta(final: false)
            }
        }
        lock.lock()
        usageHeartbeat = heartbeat
        lock.unlock()
    }

    private func reportUsageDelta(final isFinal: Bool) async {
        guard let reporter = usageReporter else { return }
        guard let pending = pendingUsage(final: isFinal) else { return }
        switch await reporter(pending) {
        case .ok:
            commitReported(chunks: pending)
        case .capped(let message):
            // The server refused the reservation — stop metering (a re-report
            // would just 429 again) and hand the session to the fallback.
            stopMetering()
            onFallback?(message)
            finish()
        case .failed:
            break   // keep the delta; the next heartbeat retries cumulatively
        }
    }

    /// nil when there is nothing to report or metering has stopped.
    private func pendingUsage(final isFinal: Bool) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !meteringStopped else { return nil }
        let chunks = Self.chunksToReport(sentSamples: sentSamples,
                                         reportedSamples: reportedSamples,
                                         final: isFinal)
        return chunks > 0 ? chunks : nil
    }

    private func commitReported(chunks: Int) {
        lock.lock()
        reportedSamples += chunks * Self.samplesPerChunk
        lock.unlock()
    }

    private func stopMetering() {
        lock.lock()
        meteringStopped = true
        lock.unlock()
    }

    // MARK: Reconnect

    private func handleDrop() {
        lock.lock()
        guard state == .open || state == .connecting else { lock.unlock(); return }
        state = .reconnecting
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let dying = task
        task = nil
        lock.unlock()

        dying?.cancel(with: .abnormalClosure, reason: nil)
        // The in-progress hypothesis died with the socket and its audio was
        // already sent (not in the replay buffer), so no final will arrive to
        // clear it — drop any provisional line now. Fresh interims come from the
        // reconnected socket.
        onInterim?("")
        if attempt == Self.notifyAfterAttempts {
            onError?("Reconnecting to Deepgram…")
        }
        scheduleReconnect(attempt: attempt)
    }

    private func scheduleReconnect(attempt: Int) {
        let delay = Self.backoffDelay(attempt)
        let reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isClosed else { return }
            self.openSocket(isReconnect: true)
        }
        lock.lock()
        reconnectTask = reconnect
        lock.unlock()
    }

    /// Exponential (0.5·2ⁿ, capped) plus up to 30% jitter to de-sync retries.
    static func backoffDelay(_ attempt: Int) -> Double {
        let base = min(pow(2.0, Double(attempt)) * 0.5, maxReconnectDelay)
        return base + Double.random(in: 0...(base * 0.3))
    }

    /// The un-jittered exponential floor for a given attempt (test seam — the
    /// jittered delay always lands in `[base, base * 1.3]`).
    static func backoffBase(_ attempt: Int) -> Double {
        min(pow(2.0, Double(attempt)) * 0.5, maxReconnectDelay)
    }

    // MARK: Receive

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.markHealthy(socket)
                self.handle(message)
                self.receive(on: socket)   // keep receiving until the socket closes
            case .failure(let error):
                self.handleReceiveFailure(error, on: socket)
            }
        }
    }

    /// A live socket delivered a message — reset backoff. Ignored for a stale
    /// chain whose socket has already been replaced.
    /// Returns whether THIS call made the socket ready — that is, whether it is
    /// the one that fired `onReady`. Marking an already-healthy socket is a
    /// no-op and says so.
    @discardableResult
    private func markHealthy(_ socket: URLSessionWebSocketTask) -> Bool {
        var becameReady = false
        lock.lock()
        if task === socket, !healthySinceConnect {
            healthySinceConnect = true
            reconnectAttempts = 0
            becameReady = true
        }
        lock.unlock()
        if becameReady { onReady?() }
        return becameReady
    }

    /// Route a deterministic test signal through the same readiness method as
    /// a real first server frame. The test-only process guard prevents a debug
    /// app or dev hook from manufacturing socket health.
    ///
    /// Returns whether readiness actually fired. It used to return `true` for
    /// merely having a socket, which made `#expect(markCurrent…())` pass while
    /// `onReady` never ran — so the buffered results were never flushed and the
    /// failure surfaced several lines later as an empty transcript, looking for
    /// all the world like a timing flake.
#if DEBUG
    @discardableResult
    func markCurrentSocketHealthyForTesting() -> Bool {
        guard AppState.isUnderTest else { return false }
        lock.lock()
        let socket = task
        lock.unlock()
        guard let socket else { return false }
        return markHealthy(socket)
    }
#endif

    private func handleReceiveFailure(_ error: Error, on socket: URLSessionWebSocketTask) {
        // Ignore failures from a chain we've already superseded, and our own
        // cancellations (finish() / reconnect tear-down).
        guard isCurrent(socket), !isClosed else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }

        // A failed WebSocket upgrade exposes the HTTP status. Bad auth on a
        // permanent key is terminal (reconnecting won't fix a wrong key); a
        // rejected grant token is transient — it likely expired between mint
        // and connect, and the reconnect path fetches a fresh one.
        if let http = socket.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            if case .key = auth {
                let message = "Invalid API key (check Settings → Integrations)."
                onTerminalFailure?(message)
                onError?(message)
                finish()
                return
            }
        }
        handleDrop()
    }

    private func isCurrent(_ socket: URLSessionWebSocketTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return task === socket
    }

    // MARK: Message handling

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        for event in Self.parseMessage(text, diarize: diarize) {
            switch event {
            case .interim(let transcript):        onInterim?(transcript)
            case .result(let transcript, let s):  onResult?(transcript, s)
            case .clearInterim:                   onInterim?("")
            }
        }
    }

    /// Parse one Deepgram `Results` message into ordered events. Pure — no
    /// socket, no side effects — so the interim/final and diarization logic is
    /// directly testable. Non-Results, malformed, or empty-transcript messages
    /// yield no events.
    static func parseMessage(_ text: String, diarize: Bool) -> [DeepgramEvent] {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["type"] as? String == "Results",
              let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let alternative = alternatives.first,
              let transcript = alternative["transcript"] as? String,
              !transcript.isEmpty else { return [] }

        // Interim hypothesis: surface provisionally (interims lack stable
        // speaker data). A final replaces it.
        guard (json["is_final"] as? Bool) == true else {
            return [.interim(transcript)]
        }

        // A final the model itself scores as a guess is committed forever and
        // read back by the LLM as fact. Reported as "duplicating recognition of
        // speech" — the low-confidence mishearing of a sentence landed next to
        // the confident transcription of the same sentence. Absent confidence
        // commits: dropping speech needs positive evidence, not a missing key.
        if let confidence = alternative["confidence"] as? Double,
           confidence < finalConfidenceFloor {
            return [.clearInterim]
        }

        var events: [DeepgramEvent] = []
        // Without diarization (or word data), emit the whole utterance as-is.
        if diarize, let words = alternative["words"] as? [[String: Any]], !words.isEmpty {
            // Split into contiguous same-speaker runs so crosstalk is attributed
            // per speaker, not all to the first word's speaker.
            var runs: [(speaker: Int?, tokens: [String])] = []
            for word in words {
                let speaker = word["speaker"] as? Int
                let token = (word["punctuated_word"] as? String) ?? (word["word"] as? String) ?? ""
                guard !token.isEmpty else { continue }
                if runs.isEmpty || runs[runs.count - 1].speaker != speaker {
                    runs.append((speaker, [token]))
                } else {
                    runs[runs.count - 1].tokens.append(token)
                }
            }
            for run in mergeSpeakerIslands(runs) {
                events.append(.result(text: run.tokens.joined(separator: " "), speaker: run.speaker))
            }
        } else {
            events.append(.result(text: transcript, speaker: nil))
        }
        // Final always clears the provisional line last (matches the old defer).
        events.append(.clearInterim)
        return events
    }

    /// Below this, a final is treated as noise. Deepgram scores real speech
    /// well above it; hallucinated segments from keyboard clatter and music
    /// score far below. Deliberately permissive — the cost of a false drop is
    /// lost dialogue.
    static let finalConfidenceFloor = 0.35

    /// Collapse one-word speaker islands: a single word attributed to B in the
    /// middle of A's sentence is diarization noise, not crosstalk — a real
    /// interjection arrives with silence around it, not spliced mid-clause.
    /// Only an island BETWEEN two runs of the same speaker is collapsed; at an
    /// utterance edge a short run is a genuine handover ("Agreed." — "So we
    /// ship."). Reported as "duplicating speaker name all the time": every
    /// island became its own gutter line.
    static func mergeSpeakerIslands(
        _ runs: [(speaker: Int?, tokens: [String])]
    ) -> [(speaker: Int?, tokens: [String])] {
        var merged: [(speaker: Int?, tokens: [String])] = []
        var index = 0
        while index < runs.count {
            let run = runs[index]
            let isIsland = run.tokens.count == 1
                && index > 0 && index + 1 < runs.count
                && runs[index - 1].speaker == runs[index + 1].speaker
                && runs[index - 1].speaker != run.speaker
            if isIsland, var previous = merged.popLast() {
                // Reattribute the island word, then absorb the following run —
                // it is the same speaker continuing the same sentence.
                previous.tokens.append(contentsOf: run.tokens)
                previous.tokens.append(contentsOf: runs[index + 1].tokens)
                merged.append(previous)
                index += 2
            } else {
                merged.append(run)
                index += 1
            }
        }
        return merged
    }

    // MARK: Control + keepalive

    private func sendControl(_ payload: [String: Any], on socket: URLSessionWebSocketTask?) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(string)) { _ in }
    }

    private func startKeepAlive() {
        let alive = Task { [weak self] in
            while !(self?.isClosed ?? true) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !self.isClosed else { return }
                // Read the live socket through a synchronous helper — taking the
                // NSLock directly inside this async task is a Swift 6 error.
                if let socket = self.openSocketForKeepAlive() {
                    self.sendControl(["type": "KeepAlive"], on: socket)
                }
            }
        }
        lock.lock()
        keepAlive = alive
        lock.unlock()
    }

    /// The current socket iff open — synchronous so the lock is never held
    /// across an await.
    private func openSocketForKeepAlive() -> URLSessionWebSocketTask? {
        lock.lock(); defer { lock.unlock() }
        return state == .open ? task : nil
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .closed
    }
}
