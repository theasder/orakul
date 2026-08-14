import Foundation
import Testing
@testable import MeetGPT

/// What recall costs on a real history.
///
/// `DecisionRecallService.recall` embeds every recallable unit of every saved
/// session, for every question. That is fine against the handful of fixtures
/// the correctness tests use and potentially ruinous against a year of
/// meetings — and it runs on the ask path, where the user is waiting. The
/// production embedder serialises its CoreNLP calls behind a lock, so this
/// cost is not even parallelisable.
///
/// These tests fix a budget rather than describing the current number, so a
/// future change that makes recall quadratic fails here instead of in a
/// customer's afternoon.
///
/// Env-gated (`CRUXWING_PERF=1`) because a timing budget measured while 2,400
/// other tests saturate the machine measures the runner, not the product —
/// isolated 2.4 s becomes 4.3 s under full-suite load, which would make this
/// file a flake generator and train everyone to ignore it. Run deliberately:
///
///     CRUXWING_PERF=1 swift test --filter DecisionRecallPerformanceTests
@Suite("Decision recall — cost on a real history")
struct DecisionRecallPerformanceTests {

    /// Точные замеры — по требованию: на шумной машине один и тот же вызов
    /// давали 2.4 с и 4.6 с, и держать по такому числу узкий бюджет нельзя.
    ///
    /// Раньше это был `guard enabled else { return }` в теле, то есть
    /// пропущенный тест отчитывался как ПРОЙДЕННЫЙ. Шесть таких проверок
    /// молчали во всех прогонах и в CI, и «250 сессий укладываются в бюджет»
    /// означало ровно ничего. Трейт `.enabled(if:)` печатает «skipped» —
    /// разница между «проверено» и «не запускалось» снова видна.
    static var preciseRunEnabled: Bool {
        ProcessInfo.processInfo.environment["CRUXWING_PERF"] != nil
    }

    /// Тихая ли машина настолько, чтобы число что-то значило.
    ///
    /// Бюджет 2.5 с при замере 2.24 с — запас в одиннадцать процентов. Под
    /// нагрузкой он не выдерживает: 14 августа `CRUXWING_PERF=1 swift test
    /// --filter Performance` упал и тут же прошёл на той же сборке, при
    /// средней нагрузке 11.6 на десяти ядрах. Такой замер меряет соседей по
    /// процессору, а не наш код, и красный от него учит не смотреть на красное.
    ///
    /// Поэтому проверка не запускается на загруженной машине — и печатает
    /// почему. Молчаливого «пройдено» здесь нет: Swift Testing показывает
    /// «skipped», а причина уходит в вывод.
    static var machineIsQuiet: Bool {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return true }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        guard loads[0] < cores else {
            print(String(format:
                "пропуск замера: средняя нагрузка %.1f при %.0f ядрах — число мерило бы соседей",
                loads[0], cores))
            return false
        }
        return true
    }

    /// Best of N, because a developer machine is never quiet: measured on this
    /// one during a notarization run the same call took 2.4 s and 4.6 s. The
    /// minimum is the least-contended sample and the only figure worth holding
    /// a budget against — an average here would mostly measure whatever else
    /// was compiling at the time.
    private func fastest(_ runs: Int = 3, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<runs {
            let began = Date()
            body()
            best = min(best, Date().timeIntervalSince(began))
        }
        return best
    }

    /// A year of meetings for somebody who records most of them.
    private static let sessionCount = 250
    /// The ask path is interactive: past roughly this, the answer stops feeling
    /// like recall and starts feeling like a search job.
    private static let budgetSeconds = 2.5

    private func populatedStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)

        let topics = ["pricing", "hiring", "the migration", "onboarding", "the vendor contract"]
        for index in 0..<Self.sessionCount {
            let started = Date().addingTimeInterval(-Double(index) * 86_400)
            let topic = topics[index % topics.count]
            // A realistic session: a couple of digest paragraphs and a
            // transcript long enough to window several times.
            let transcript = (0..<40).map { line in
                TranscriptEntry(id: UUID(), source: .system,
                                text: "Line \(line) of the discussion about \(topic) and what it means for the quarter.",
                                timestamp: started.addingTimeInterval(Double(line) * 20),
                                speaker: nil)
            }
            try store.save(SavedSession(
                id: UUID(), title: "Sync \(index)", startedAt: started, savedAt: started,
                goal: "", entries: transcript, aiResponse: "",
                digest: "Decided to move forward on \(topic).\n\nOpen question about \(topic) budget."))
        }
        return store
    }

    /// Всегда включён, в отличие от точных замеров выше.
    ///
    /// Ловит не «медленнее на 20%», а возврат катастрофы: в командной строке
    /// такая же ошибка — таблицы словаря перестраивались на каждое слово —
    /// превратила поиск по 20 звонкам в 118 секунд, а по 200 не заканчивался
    /// вовсе. Все тесты при этом были зелёными: в них по две-три фразы.
    ///
    /// Бюджет намеренно в десять раз выше настоящего времени (≈2.3 с), чтобы
    /// шум загруженной машины не ронял прогон. Узкий бюджет — в точной
    /// проверке под `CRUXWING_PERF`.
    @Test("recall over a year of meetings never collapses into minutes")
    func recallDoesNotCollapse() throws {
        let store = try populatedStore()
        let began = Date()
        let hits = DecisionRecallService.recall(query: "what did we decide about pricing",
                                                store: store,
                                                embedder: RecallEmbedder.production)
        let elapsed = Date().timeIntervalSince(began)

        #expect(!hits.isEmpty, "recall found nothing — the measurement was of empty work")
        let report = "recall over \(Self.sessionCount) sessions took "
            + String(format: "%.1f", elapsed) + "s — something rebuilds per token again"
        #expect(elapsed < 25, "\(report)")
    }

    @Test("a year of meetings still answers inside the interactive budget",
          .enabled(if: Self.preciseRunEnabled && Self.machineIsQuiet))
    func recallStaysInteractive() throws {
        let store = try populatedStore()
        var hits: [DecisionRecallService.RecallHit] = []
        let elapsed = fastest {
            hits = DecisionRecallService.recall(query: "what did we decide about pricing",
                                                store: store,
                                                embedder: RecallEmbedder.production)
        }
        print(String(format: "recall over %d sessions: %.2fs (best of 3)", Self.sessionCount, elapsed))

        #expect(!hits.isEmpty)
        #expect(elapsed < Self.budgetSeconds,
                "recall over \(Self.sessionCount) sessions took \(elapsed)s — the ask path blocks on this")
    }

    @Test("the two-stage shortlist still returns the right meeting",
          .enabled(if: Self.preciseRunEnabled))
    func shortlistDoesNotLoseTheAnswer() throws {
        // The speed fix only engages ABOVE the session cap, so at this size the
        // behaviour is NOT the same as scoring everything — the cheap first
        // pass decides which twelve meetings the good embedder ever sees. If
        // the answer does not survive that cut, recall is fast and wrong, which
        // is worse than slow and right.
        let store = try populatedStore()
        let needle = Date().addingTimeInterval(-3 * 86_400)
        let target = UUID()
        try store.save(SavedSession(
            id: target, title: "Board prep", startedAt: needle, savedAt: needle,
            goal: "", entries: [], aiResponse: "",
            digest: "Decided to raise the Series B at a 90 million post-money valuation."))

        for (label, query) in [
            ("verbatim", "what did we decide about the Series B valuation"),
            ("paraphrased", "what did we land on for the raise and post-money"),
            ("partial", "Series B post-money"),
        ] {
            let hits = DecisionRecallService.recall(query: query, store: store,
                                                    embedder: RecallEmbedder.production)
            let rank = hits.firstIndex { $0.sessionID == target }
            print("recall \(label): rank \(rank.map(String.init) ?? "absent") of \(hits.count)")
            #expect(rank == 0, "\(label) query did not put the right meeting first")
        }
    }

    @Test("hit@1 across a spread of real-shaped questions",
          .enabled(if: Self.preciseRunEnabled))
    func hitRateAcrossManyTargets() throws {
        // One target with three phrasings is the same thin evidence that made
        // the diarization threshold look solved at n=3. Ten distinct meetings,
        // each asked about the way somebody actually would.
        let store = try populatedStore()
        let cases: [(digest: String, query: String)] = [
            ("Decided to raise the Series B at a 90 million post-money valuation.",
             "what did we decide about the Series B valuation"),
            ("Agreed to sunset the Fabric API and move partners to GraphQL in June.",
             "when are we sunsetting the Fabric API"),
            ("Decided to hire a staff SRE before expanding the Frankfurt region.",
             "did we agree to hire an SRE before Frankfurt"),
            ("Agreed the Northwind renewal moves to annual billing at a 12 percent uplift.",
             "what did we land on for the Northwind renewal"),
            ("Decided to drop the Kotlin rewrite and keep the Swift client.",
             "what did we decide about the Kotlin rewrite"),
            ("Agreed to cap trial accounts at 40 compute credits after the abuse report.",
             "what cap did we agree for trial accounts"),
            ("Decided to move the Lisbon offsite to March and cut the budget by half.",
             "what did we decide about the Lisbon offsite"),
            ("Agreed to require SOC 2 evidence from Kestrel before signing.",
             "what did we decide about Kestrel and SOC 2"),
            ("Decided to deprecate the legacy CSV import once Snowflake sync ships.",
             "when do we deprecate the CSV import"),
            ("Agreed to pause the Bolivia pilot until the payments licence clears.",
             "what did we decide about the Bolivia pilot"),
        ]

        var ids: [UUID] = []
        for (index, testCase) in cases.enumerated() {
            let id = UUID()
            ids.append(id)
            let when = Date().addingTimeInterval(-Double(index + 2) * 86_400)
            try store.save(SavedSession(id: id, title: "Session \(index)", startedAt: when,
                                        savedAt: when, goal: "", entries: [], aiResponse: "",
                                        digest: testCase.digest))
        }

        var firsts = 0
        var found = 0
        for (index, testCase) in cases.enumerated() {
            let hits = DecisionRecallService.recall(query: testCase.query, store: store,
                                                    embedder: RecallEmbedder.production)
            let rank = hits.firstIndex { $0.sessionID == ids[index] }
            if rank == 0 { firsts += 1 }
            if rank != nil { found += 1 }
            if rank != 0 { print("  miss: \(testCase.query) -> rank \(rank.map(String.init) ?? "absent")") }
        }
        print("recall hit@1: \(firsts)/\(cases.count), present anywhere: \(found)/\(cases.count)")

        // The bar: the right meeting is the first answer nearly every time. A
        // recall that is usually second is a recall nobody trusts twice.
        #expect(firsts >= 9)
        #expect(found == cases.count)
    }

    @Test("the brief's two builders are cheap enough to run before every meeting",
          .enabled(if: Self.preciseRunEnabled && Self.machineIsQuiet))
    func briefSourcesStayCheap() throws {
        let store = try populatedStore()
        let meeting = UpcomingMeeting(id: "evt", title: "Sync 7",
                                      start: Date().addingTimeInterval(600))
        let elapsed = fastest {
            _ = BriefRecallSources.build(for: meeting, store: store)
            _ = BriefRecallSources.commitments(for: meeting, store: store)
            _ = BriefRecallSources.repeatedPromises(for: meeting, store: store)
        }
        print(String(format: "brief sources over %d sessions: %.2fs (best of 3)", Self.sessionCount, elapsed))
        #expect(elapsed < Self.budgetSeconds * 2,
                "the brief runs on a timer before a call — it must not spin the fans")
    }
}
