import AVFoundation
import Foundation
import Testing
@testable import MeetGPT

private final class InertDeepgramTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private var requests: [URLRequest] = []
    private var starts = 0
    private var receives = 0
    private var sends = 0

    var overrides: DeepgramTransportOverrides {
        DeepgramTransportOverrides(
            makeSocket: { [self] request in
                let socket = session.webSocketTask(with: request)
                lock.lock()
                requests.append(request)
                lock.unlock()
                return socket
            },
            startSocket: { [self] _ in
                lock.lock()
                starts += 1
                lock.unlock()
            },
            beginReceiving: { [self] _ in
                lock.lock()
                receives += 1
                lock.unlock()
            },
            sendMessage: { [self] _, _ in
                lock.withLock { sends += 1 }
            })
    }

    func snapshot() -> (requests: [URLRequest], starts: Int, receives: Int, sends: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, starts, receives, sends)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func read() -> Int { lock.withLock { value } }
}

private final class StreamerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeepgramStreamer] = []

    func append(_ streamer: DeepgramStreamer) {
        lock.lock(); defer { lock.unlock() }
        values.append(streamer)
    }

    func snapshot() -> [DeepgramStreamer] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private actor HandoffTranscriber: TranscriptionService {
    private(set) var transcriptions = 0
    private(set) var shutdowns = 0
    private(set) var cancelledBefore: [Int] = []
    let text: String

    init(text: String) { self.text = text }

    func transcribe(wav: Data) async throws -> String {
        transcriptions += 1
        return text
    }

    func shutdown() async { shutdowns += 1 }

    func cancelPendingTranscriptions(beforeGeneration generation: Int) async {
        cancelledBefore.append(generation)
    }

    func snapshot() -> (transcriptions: Int, shutdowns: Int, cancelledBefore: [Int]) {
        (transcriptions, shutdowns, cancelledBefore)
    }
}

private actor DelayedHandoffTranscriber: TranscriptionService {
    private var continuations: [(Int, CheckedContinuation<String, Never>)] = []
    private(set) var transcriptions = 0
    private(set) var shutdowns = 0
    private(set) var cancelledBefore: [Int] = []

    func transcribe(wav: Data) async throws -> String {
        transcriptions += 1
        let ordinal = transcriptions
        return await withCheckedContinuation { continuation in
            continuations.append((ordinal, continuation))
        }
    }

    /// Отдаёт заготовленные ответы ожидающим расшифровкам.
    ///
    /// Ответов может не хватить, и это не гипотеза: под полной нагрузкой к
    /// моменту вызова успевает встать в очередь третья расшифровка, а сценарий
    /// написан на две. `answers[ordinal - 1]` тогда выходил за границы и ронял
    /// весь прогон — «Index out of range» без имени теста, потому что падает
    /// процесс целиком, а не одна проверка. Ловилось примерно в двух прогонах
    /// из трёх.
    ///
    /// Лишние продолжения получают заметную строку вместо обрыва: тест, который
    /// её дождался, упадёт на своей проверке и назовёт себя. Ровно так уже
    /// сделано в `ScriptedHandoffTranscriber` ниже.
    func release(_ answers: [String]) {
        let pending = continuations
        continuations.removeAll()
        for (ordinal, continuation) in pending {
            let answer = answers.indices.contains(ordinal - 1)
                ? answers[ordinal - 1]
                : "unscripted delayed release \(ordinal)"
            continuation.resume(returning: answer)
        }
    }

    func shutdown() async { shutdowns += 1 }

    func cancelPendingTranscriptions(beforeGeneration generation: Int) async {
        cancelledBefore.append(generation)
    }

    func snapshot() -> (transcriptions: Int, shutdowns: Int, cancelledBefore: [Int]) {
        (transcriptions, shutdowns, cancelledBefore)
    }
}

private actor ScriptedHandoffTranscriber: TranscriptionService {
    private let answers: [String]
    private(set) var transcriptions = 0
    private(set) var shutdowns = 0

    init(answers: [String]) {
        self.answers = answers
    }

    func transcribe(wav: Data) async throws -> String {
        transcriptions += 1
        guard answers.indices.contains(transcriptions - 1) else {
            return "unexpected rollback replay \(transcriptions)"
        }
        return answers[transcriptions - 1]
    }

    func shutdown() async { shutdowns += 1 }

    func snapshot() -> (transcriptions: Int, shutdowns: Int) {
        (transcriptions, shutdowns)
    }
}

private func handoffSnapshot(_ engine: TranscriptionEngine) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
        engine: engine,
        language: "en",
        localModel: "base",
        microphoneNoiseSuppression: false,
        glossary: "Falcon-SLA, Kubernetes",
        assemblyDiarization: false)
}

@MainActor
/// Wall-clock bounded, not iteration bounded.
///
/// Sixty seconds is a CEILING, not a delay: a passing run never waits, and the
/// whole suite finishes in under a second alone. It is set this high because
/// these waits are for MainActor work, and when 2,400 other tests are running
/// the wait is for a scheduling slice rather than for the product. Measured on
/// this machine: green in ~50 s per full run, and the one red run took 235 s
/// because a release notarization was building at the same time. If it fails
/// again, check what else was on the CPU before touching the product.
///
/// The old version polled 3,000 times with a 1 ms sleep and called that three
/// seconds. Each iteration also costs an actor hop and a scheduling slice, so
/// under a full parallel run the loop expired long before the work it waited on
/// could land — this suite failed on every full run and passed in isolation,
/// which is the signature of a harness measuring the machine rather than the
/// product. A deadline gives the work a real budget and still returns the
/// instant the condition holds.
/// Wait for a MainActor condition without competing with the work that has to
/// satisfy it.
///
/// The condition is MainActor-isolated and so is the product work being waited
/// on, which makes the poll interval load-bearing rather than cosmetic. At 2ms
/// this loop re-acquired the MainActor about thirty thousand times per minute,
/// taking the actor away from the very task that had to run for the condition
/// to become true. Alone that is invisible; in a full parallel run — where
/// thousands of MainActor-isolated tests already contend for it — the loop
/// starved its own subject and then reported the timeout as a product failure.
/// Five expectations in this suite failed that way, on behaviour that was
/// correct.
///
/// Backing off hands the actor back in useful slices: a satisfied condition is
/// still seen within a few milliseconds, while a slow one is checked ~25 times
/// a second instead of 500. The deadline is a hang backstop, not a measurement.
/// Let everything already queued on the MainActor run.
///
/// Unstructured `Task { @MainActor in ... }` work has no handle to await, but it
/// does have an order: a task enqueued later runs after tasks enqueued earlier
/// at the same priority. So when the product has already created its delivery
/// tasks, awaiting a task created afterwards is a deterministic barrier — no
/// deadline, no polling, no competing for the actor it is waiting on.

/// Отодвигает таймер отката за пределы любого прогона.
///
/// `startDeepgram` заводит задачу, которая через двенадцать секунд объявляет
/// передачу несостоявшейся и вызывает `drainForRollback`. Это настоящие
/// двенадцать секунд стенных часов, и в полном прогоне они идут параллельно с
/// 2668 другими тестами. Под нагрузкой тест не успевал дойти от старта до
/// отметки готовности, откат срабатывал первым, `commitSuccessful` возвращал
/// пустой массив — и падало на «в транскрипте нет результата», в месте, которое
/// про таймер ничего не говорит. В одиночку двенадцати секунд хватало всегда,
/// поэтому тест выглядел «плавающим».
///
/// Эти тесты проверяют маршрут, а не таймаут. Час вместо двенадцати секунд
/// убирает часы из условия.
private func withUnhurriedReadiness<T>(_ body: () async throws -> T) async rethrows -> T {
    try await DeepgramHandoffState.$readinessTimeoutNanoseconds
        .withValue(3_600_000_000_000) { try await body() }
}

private func drainMainActor() async {
    await Task { @MainActor in }.value
}

private func waitFor(
    timeout: TimeInterval = 60,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var interval: UInt64 = 2_000_000          // 2ms, for the common instant case
    let ceiling: UInt64 = 40_000_000          // 40ms once it is clearly not instant
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: interval)
        interval = min(interval * 2, ceiling)
    }
    return await condition()
}

@Suite("Deepgram socket lifecycle without network", .serialized)
struct DeepgramSocketLifecycleTests {
    @Test("terminal setup wires authorization and readiness exactly once")
    func setupAndReadiness() async {
        let transport = InertDeepgramTransport()
        let streamer = DeepgramStreamer(
            auth: .key("unit-key"), diarize: true, language: "en",
            keyterms: ["Kubernetes"], transportOverrides: transport.overrides)
        let readyCount = LockedCounter()
        streamer.onReady = { readyCount.increment() }

        streamer.start()
        let opened = transport.snapshot()
        #expect(opened.requests.count == 1)
        #expect(opened.starts == 1)
        #expect(opened.receives == 1)
        #expect(opened.requests.first?.value(forHTTPHeaderField: "Authorization")
                == "Token unit-key")

        #expect(streamer.markCurrentSocketHealthyForTesting(),
                "первый вызов должен перевести сокет в готовность")
        // Второй раз готовность уже не наступает — и метод теперь об этом
        // честно сообщает, а не отвечает «да» за то, что сокет просто есть.
        #expect(!streamer.markCurrentSocketHealthyForTesting(),
                "повторная отметка не должна вызывать onReady второй раз")
        #expect(readyCount.read() == 1)

        streamer.send([1, 2, 3, 4])
        #expect(await waitFor { transport.snapshot().sends == 1 })
        streamer.finish()
    }
}

@MainActor
@Suite("Production live engine handoff without hardware", .serialized)
struct DeepgramHandoffIntegrationTests {
    private func makeState(
        auth: DeepgramAuth,
        previous: HandoffTranscriber,
        placeholder: HandoffTranscriber,
        nextLocal: HandoffTranscriber,
        transport: InertDeepgramTransport,
        streamers: StreamerCapture
    ) -> AppState {
        var localFactoryCalls = 0
        return AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionServiceFactory: { engine, _, _, _, _ in
                switch engine {
                case .local:
                    defer { localFactoryCalls += 1 }
                    return localFactoryCalls == 0 ? previous : nextLocal
                case .deepgram:
                    return placeholder
                case .server, .whisper:
                    return placeholder
                }
            },
            deepgramStreamerFactory: { auth, diarize, language, keyterms in
                let streamer = DeepgramStreamer(
                    auth: auth, diarize: diarize, language: language,
                    keyterms: keyterms, transportOverrides: transport.overrides)
                streamers.append(streamer)
                return streamer
            },
            transcriptionEngineAvailability: { _ in true },
            deepgramAuthOverride: auth)
    }

    @Test("real Local to Instant switch starts both routes, then returns to Local")
    func successfulSwitchExecutesProductionRoutes() async throws {
        try await withUnhurriedReadiness {
            let savedEngine = Config.transcriptionEngineValue
            defer { Config.transcriptionEngineValue = savedEngine }
            Config.transcriptionEngineValue = .local

            let previous = HandoffTranscriber(text: "old engine")
            let placeholder = HandoffTranscriber(text: "unused placeholder")
            let nextLocal = HandoffTranscriber(text: "new local engine")
            let transport = InertDeepgramTransport()
            let streamers = StreamerCapture()
            let state = makeState(
                auth: .grant { "unit-grant" }, previous: previous,
                placeholder: placeholder, nextLocal: nextLocal,
                transport: transport, streamers: streamers)
            let systemChunker = AudioChunkBuffer(chunkSeconds: 0.02, overlapSeconds: 0) { _, _ in }
            let micChunker = AudioChunkBuffer(chunkSeconds: 0.02, overlapSeconds: 0) { _, _ in }
            state.installTestLiveTranscriptionRuntime(
                settings: handoffSnapshot(.local), systemChunker: systemChunker,
                micChunker: micChunker, generation: 40)

            #expect(state.selectTranscriptionEngine(.deepgram))
            let pair = streamers.snapshot()
            // Требование, а не ожидание. Под нагрузкой оба потока успевают
            // зарегистрироваться не всегда, и `#expect` лишь записывал промах —
            // выполнение шло дальше на `pair[0]` и валило ВЕСЬ прогон с «Index out
            // of range». Одна флака по таймингу уносила 2612 тестов; `#require`
            // останавливает этот тест и оставляет остальные.
            try #require(pair.count == 2)
            #expect(await waitFor { transport.snapshot().requests.count == 2 })
            #expect(state.liveTranscriptionConfiguration().active?.engine == .deepgram)

            // The actual sample handlers installed by startDeepgram reach the
            // stream transports; no AVAudioEngine or server is involved.
            systemChunker.onSamples?([1, 2, 3])
            micChunker.onSamples?([4, 5, 6])
            #expect(await waitFor { transport.snapshot().sends == 2 })

            pair[0].onError?("temporary system notice")
            pair[1].onError?("temporary microphone notice")
            pair[0].onInterim?("system partial")
            pair[1].onInterim?("microphone partial")
            pair[0].onResult?("Instant system result", 0)
            pair[1].onResult?("Instant microphone result", nil)
            await Task.yield()
            #expect(!state.transcript.contains(where: { $0.text == "Instant system result" }))
            #expect(!state.transcript.contains(where: { $0.text == "Instant microphone result" }))

            #expect(pair[0].markCurrentSocketHealthyForTesting())
            #expect(pair[1].markCurrentSocketHealthyForTesting())
            // Marking the sockets healthy runs the readiness path synchronously, so
            // by the time those calls return, the buffered results have already been
            // ENQUEUED on the MainActor by deliverResult. Draining the queue is
            // therefore deterministic: a MainActor task enqueued now runs after the
            // ones enqueued before it, so when this returns, delivery has happened.
            //
            // Polling for it instead made the test race every other MainActor test
            // in the suite for the actor that had to run the delivery — 60 seconds
            // of deadline, five failed expectations, and a correct product.
            await drainMainActor()
            #expect(state.transcript.contains(where: { $0.text == "Instant system result" }))
            #expect(state.transcript.contains(where: { $0.text == "Instant microphone result" }))
            #expect(state.transcript.first(where: { $0.text == "Instant system result" })?
                .transcriptionEngine == .deepgram)
            #expect(state.transcript.first(where: { $0.text == "Instant microphone result" })?
                .transcriptionEngine == .deepgram)

            let previousStopped = await waitFor {
                let snapshot = await previous.snapshot()
                return snapshot.shutdowns == 1 && snapshot.cancelledBefore.isEmpty
            }
            let previousLifecycle = await previous.snapshot()
            #expect(previousStopped, "lifecycle was \(previousLifecycle)")

            // Once both sockets proved ready, a terminal stream error takes the
            // established stream through its normal on-device degrade route (not
            // the pre-ready rollback).
            pair[0].onTerminalFailure?("test post-ready disconnect")
            #expect(await waitFor {
                state.liveTranscriptionConfiguration().active?.engine == .local
            })
            pair[0].onFallback?("late test compute cap")
            systemChunker.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.05))
            micChunker.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.05))
            #expect(await waitFor { await nextLocal.snapshot().transcriptions > 0 })

            // Selecting the already-active fallback is an idempotent settings write.
            #expect(state.selectTranscriptionEngine(.local))
            // Exercise the chunked-engine branch after the live-stream fallback;
            // this uses the same retained routes rather than installing new taps.
            #expect(state.selectTranscriptionEngine(.whisper))
            #expect(state.liveTranscriptionConfiguration().active?.engine == .whisper)
            #expect(state.selectTranscriptionEngine(.local))
            #expect(state.liveTranscriptionConfiguration().active?.engine == .local)
            #expect(state.selectedTranscriptionEngine == .local)
        }
    }

    @Test("an unavailable engine is rejected before any live route changes")
    func unavailableEngineStopsAtAvailabilityGate() {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local
        let initial = HandoffTranscriber(text: "initial")
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionServiceFactory: { _, _, _, _, _ in initial },
            transcriptionEngineAvailability: { $0 == .local })

        #expect(!state.selectTranscriptionEngine(.deepgram))
        #expect(state.selectedTranscriptionEngine == .local)
        #expect(state.lastError?.contains("недоступно") == true)
    }

    @Test("delayed Local chunks and the partial accumulator survive a Local to Instant handoff once")
    func delayedLocalDrainSurvivesInstantHandoff() async throws {
        try await withUnhurriedReadiness {
            let savedEngine = Config.transcriptionEngineValue
            defer { Config.transcriptionEngineValue = savedEngine }
            Config.transcriptionEngineValue = .local

            let previous = DelayedHandoffTranscriber()
            let placeholder = HandoffTranscriber(text: "unused placeholder")
            let transport = InertDeepgramTransport()
            let streamers = StreamerCapture()
            let state = AppState(
                credentialStore: InMemoryKeychain(),
                transcriptionServiceFactory: { engine, _, _, _, _ -> TranscriptionService in
                    if engine == .local { return previous }
                    return placeholder
                },
                deepgramStreamerFactory: { auth, diarize, language, keyterms in
                    let streamer = DeepgramStreamer(
                        auth: auth, diarize: diarize, language: language,
                        keyterms: keyterms, transportOverrides: transport.overrides)
                    streamers.append(streamer)
                    return streamer
                },
                transcriptionEngineAvailability: { _ in true },
                deepgramAuthOverride: .key("unit-key"))
            let systemChunker = AudioChunkBuffer(chunkSeconds: 0.5, overlapSeconds: 0) { _, _ in }
            let micChunker = AudioChunkBuffer(chunkSeconds: 0.5, overlapSeconds: 0) { _, _ in }
            state.installTestLiveTranscriptionRuntime(
                settings: handoffSnapshot(.local), systemChunker: systemChunker,
                micChunker: micChunker, generation: 90)

            // One full Local chunk is decoding; a second voiced fragment remains
            // below the chunk boundary when Settings switches engines.
            systemChunker.append(
                AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.55))
            systemChunker.append(
                AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.25))
            #expect(await waitFor { await previous.snapshot().transcriptions == 1 })

            #expect(state.selectTranscriptionEngine(.deepgram))
            let pair = streamers.snapshot()
            // Требование, а не ожидание. Под нагрузкой оба потока успевают
            // зарегистрироваться не всегда, и `#expect` лишь записывал промах —
            // выполнение шло дальше на `pair[0]` и валило ВЕСЬ прогон с «Index out
            // of range». Одна флака по таймингу уносила 2612 тестов; `#require`
            // останавливает этот тест и оставляет остальные.
            try #require(pair.count == 2)
            #expect(await waitFor { await previous.snapshot().transcriptions == 2 })

            // Future capture is sent only to Instant, never back through Local.
            systemChunker.append(
                AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.6))
            #expect(await waitFor { transport.snapshot().sends > 0 })
            #expect(await previous.snapshot().transcriptions == 2)

            pair[0].onResult?("future instant words", 0)
            await Task.yield()
            #expect(!state.transcript.contains(where: { $0.text == "future instant words" }))
            #expect(pair[0].markCurrentSocketHealthyForTesting())
            #expect(pair[1].markCurrentSocketHealthyForTesting())
            #expect(await waitFor {
                state.transcript.contains(where: { $0.text == "future instant words" })
            })
            #expect(await previous.snapshot().shutdowns == 0,
                    "the old model must remain alive while emitted chunks are pending")

            await previous.release(["local full boundary", "local partial boundary"])
            #expect(await waitFor {
                let text = state.transcript.map(\.text)
                return text.contains("local full boundary")
                    && text.contains("local partial boundary")
                    && text.contains("future instant words")
            })
            #expect(await waitFor { await previous.snapshot().shutdowns == 1 })

            let text = state.transcript.map(\.text)
            #expect(text.filter { $0 == "local full boundary" }.count == 1)
            #expect(text.filter { $0 == "local partial boundary" }.count == 1)
            // Та же причина, что и у `pair.count` выше: если ожидание выше не
            // дождалось, этих строк в транскрипте нет, и восклицательный знак
            // ронял процесс целиком вместо одного теста.
            let instantWords = try #require(text.firstIndex(of: "future instant words"))
            #expect(try #require(text.firstIndex(of: "local full boundary")) < instantWords)
            #expect(try #require(text.firstIndex(of: "local partial boundary")) < instantWords)
            #expect(await previous.snapshot().cancelledBefore.isEmpty)
            pair.forEach { $0.finish() }
        }
    }

    @Test("switching away from Instant keeps its trailing pre-switch final and routes future chunks onward")
    func instantTailSurvivesChunkedHandoff() async throws {
        try await withUnhurriedReadiness {
            let savedEngine = Config.transcriptionEngineValue
            defer { Config.transcriptionEngineValue = savedEngine }
            Config.transcriptionEngineValue = .local

            let previous = HandoffTranscriber(text: "old local")
            let chunked = HandoffTranscriber(text: "future chunked words")
            let nextLocal = HandoffTranscriber(text: "unused local")
            let transport = InertDeepgramTransport()
            let streamers = StreamerCapture()
            let state = makeState(
                auth: .key("unit-key"), previous: previous, placeholder: chunked,
                nextLocal: nextLocal, transport: transport, streamers: streamers)
            let systemChunker = AudioChunkBuffer(chunkSeconds: 0.02, overlapSeconds: 0) { _, _ in }
            let micChunker = AudioChunkBuffer(chunkSeconds: 0.02, overlapSeconds: 0) { _, _ in }
            state.installTestLiveTranscriptionRuntime(
                settings: handoffSnapshot(.local), systemChunker: systemChunker,
                micChunker: micChunker, generation: 110)

            #expect(state.selectTranscriptionEngine(.deepgram))
            let pair = streamers.snapshot()
            // Требование, а не ожидание. Под нагрузкой оба потока успевают
            // зарегистрироваться не всегда, и `#expect` лишь записывал промах —
            // выполнение шло дальше на `pair[0]` и валило ВЕСЬ прогон с «Index out
            // of range». Одна флака по таймингу уносила 2612 тестов; `#require`
            // останавливает этот тест и оставляет остальные.
            try #require(pair.count == 2)
            #expect(pair[0].markCurrentSocketHealthyForTesting())
            #expect(pair[1].markCurrentSocketHealthyForTesting())
            #expect(state.selectTranscriptionEngine(.whisper))

            // CloseStream finals describe audio captured before the route changed;
            // they remain part of this recording even when they ARRIVE after a
            // newer chunked result. Capture-time order must win arrival-time order.
            systemChunker.append(
                AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.05))
            #expect(await waitFor {
                state.transcript.contains(where: { $0.text == "future chunked words" })
            })
            pair[0].onResult?("trailing instant final", 0)
            #expect(await waitFor {
                let text = state.transcript.map(\.text)
                return text.contains("trailing instant final")
                    && text.contains("future chunked words")
            })
            #expect(state.transcript.first(where: { $0.text == "trailing instant final" })?
                .transcriptionEngine == .deepgram)
            #expect(state.transcript.first(where: { $0.text == "future chunked words" })?
                .transcriptionEngine == .whisper)
            let ordered = state.transcript.map(\.text)
            #expect(try #require(ordered.firstIndex(of: "trailing instant final"))
                    < #require(ordered.firstIndex(of: "future chunked words")))
        }
    }

    @Test("pre-ready Instant failure restores the prior transcriber and routes")
    func preReadyFailureExecutesProductionRollback() async throws {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local

        let previous = HandoffTranscriber(text: "restored local words")
        let placeholder = HandoffTranscriber(text: "unused placeholder")
        let nextLocal = HandoffTranscriber(text: "unused next local")
        let transport = InertDeepgramTransport()
        let streamers = StreamerCapture()
        let state = makeState(
            auth: .grant { "unit-grant" }, previous: previous,
            placeholder: placeholder, nextLocal: nextLocal,
            transport: transport, streamers: streamers)
        let systemChunker = AudioChunkBuffer(chunkSeconds: 0.02, overlapSeconds: 0) { _, _ in }
        let micChunker = AudioChunkBuffer(chunkSeconds: 0.02, overlapSeconds: 0) { _, _ in }
        state.installTestLiveTranscriptionRuntime(
            settings: handoffSnapshot(.local), systemChunker: systemChunker,
            micChunker: micChunker, generation: 70)

        #expect(state.selectTranscriptionEngine(.deepgram))
        let pair = streamers.snapshot()
        // Требование, а не ожидание. Под нагрузкой оба потока успевают
        // зарегистрироваться не всегда, и `#expect` лишь записывал промах —
        // выполнение шло дальше на `pair[0]` и валило ВЕСЬ прогон с «Index out
        // of range». Одна флака по таймингу уносила 2612 тестов; `#require`
        // останавливает этот тест и оставляет остальные.
        try #require(pair.count == 2)
        #expect(pair.allSatisfy { $0.usageReporter != nil && $0.onFallback != nil })

        pair[0].onError?("setup warning")
        pair[1].onError?("microphone setup warning")
        pair[0].onInterim?("doomed system partial")
        pair[1].onInterim?("doomed microphone partial")
        pair[0].onResult?("pre-failure system result", 1)
        pair[1].onResult?("pre-failure microphone result", nil)
        pair[0].onTerminalFailure?("invalid test grant")

        // Сообщение об откате собирается из названия движка, поэтому проверка
        // держится за него. Перевод названий это и поймал: тест ждал
        // «Continued with Private» шестьдесят секунд и падал — единственный
        // способ заметить, что сообщение стало наполовину английским.
        #expect(await waitFor {
            state.liveTranscriptionConfiguration().active?.engine == .local
                && state.lastError?.contains("Продолжаем на «Приватно") == true
        })
        #expect(state.selectedTranscriptionEngine == .local)
        #expect(state.pendingEngineChange == nil)

        // The rollback's real liveChunkHandler must now call the exact prior
        // transcriber; this distinguishes route restoration from UI-only state.
        systemChunker.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.05))
        micChunker.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.05))
        #expect(await waitFor {
            await previous.snapshot().transcriptions > 0
                && state.transcript.contains(where: { $0.text == "restored local words" })
        })

        // The losing track and the metered fallback can race after rollback;
        // both must be harmless because the one-shot handoff state was claimed.
        pair[1].onTerminalFailure?("late microphone failure")
        pair[0].onFallback?("late credit cap")
        pair[0].onReady?()
        pair[1].onReady?()
        await Task.yield()
        #expect(state.liveTranscriptionConfiguration().active?.engine == .local)
    }

    @Test("simultaneous pre-ready failures replay full and partial PCM exactly once")
    func simultaneousPreReadyFailuresReplayStartupAudioExactlyOnce() async throws {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local

        let previous = ScriptedHandoffTranscriber(
            answers: ["rollback buffered full", "rollback buffered partial"])
        let placeholder = HandoffTranscriber(text: "unused Instant placeholder")
        let erroneousFallback = HandoffTranscriber(text: "wrong fallback instance")
        let transport = InertDeepgramTransport()
        let streamers = StreamerCapture()
        var localFactoryCalls = 0
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionServiceFactory: { engine, _, _, _, _ -> TranscriptionService in
                switch engine {
                case .local:
                    defer { localFactoryCalls += 1 }
                    return localFactoryCalls == 0 ? previous : erroneousFallback
                case .deepgram, .server, .whisper:
                    return placeholder
                }
            },
            deepgramStreamerFactory: { auth, diarize, language, keyterms in
                let streamer = DeepgramStreamer(
                    auth: auth, diarize: diarize, language: language,
                    keyterms: keyterms, transportOverrides: transport.overrides)
                streamers.append(streamer)
                return streamer
            },
            transcriptionEngineAvailability: { _ in true },
            deepgramAuthOverride: .key("unit-key"))
        let systemChunker = AudioChunkBuffer(chunkSeconds: 0.5, overlapSeconds: 0) { _, _ in }
        let micChunker = AudioChunkBuffer(chunkSeconds: 0.5, overlapSeconds: 0) { _, _ in }
        state.installTestLiveTranscriptionRuntime(
            settings: handoffSnapshot(.local), systemChunker: systemChunker,
            micChunker: micChunker, generation: 130)

        #expect(state.selectTranscriptionEngine(.deepgram))
        let pair = streamers.snapshot()
        // Требование, а не ожидание. Под нагрузкой оба потока успевают
        // зарегистрироваться не всегда, и `#expect` лишь записывал промах —
        // выполнение шло дальше на `pair[0]` и валило ВЕСЬ прогон с «Index out
        // of range». Одна флака по таймингу уносила 2612 тестов; `#require`
        // останавливает этот тест и оставляет остальные.
        try #require(pair.count == 2)

        // This creates one fixed chunk plus a voiced 300 ms accumulator. Both
        // now belong to the pending handoff, not the inactive degrade route.
        systemChunker.append(
            AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.8))
        pair[0].onResult?("doomed provider final", 0)

        // The two sockets report failure in the same callback turn. Exactly
        // one may claim rollback; the loser must not start a fresh degrade.
        pair[0].onTerminalFailure?("system failed before ready")
        pair[1].onTerminalFailure?("microphone failed before ready")

        #expect(await waitFor {
            let transcript = state.transcript.map(\.text)
            return state.liveTranscriptionConfiguration().active?.engine == .local
                && transcript.contains("rollback buffered full")
                && transcript.contains("rollback buffered partial")
        })

        let transcript = state.transcript.map(\.text)
        #expect(transcript.filter { $0 == "rollback buffered full" }.count == 1)
        #expect(transcript.filter { $0 == "rollback buffered partial" }.count == 1)
        #expect(!transcript.contains("doomed provider final"))
        #expect(!transcript.contains(where: { $0.hasPrefix("unexpected rollback replay") }))
        #expect(await previous.snapshot().transcriptions == 2)
        #expect(await erroneousFallback.snapshot().transcriptions == 0)
        #expect(state.selectedTranscriptionEngine == .local)
    }
}
