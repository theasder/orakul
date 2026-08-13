import Foundation

/// Serializes tests that write the SAME `UserDefaults` key from different
/// suites.
///
/// `.serialized` orders tests within one suite; it says nothing about two
/// suites running at once. `Config` is backed by the process-wide standard
/// defaults, so a suite that sets `localWhisperModel` and reads it back races
/// any other suite doing the same — which is exactly how
/// `LocalWhisperModelTests` came to read the `"small"` that
/// `SettingsDuringCallTests` had just written. It failed roughly one full run
/// in ten and passed in isolation every time.
///
/// One lock rather than one per key: the set of shared keys is small, the
/// critical sections are microseconds, and a per-key registry is a lot of
/// machinery to make a test suite marginally more parallel.
///
/// **Почему актор, а не `NSLock`.** Был `NSLock`, и он закрывал только
/// синхронные тела. Оставшаяся гонка: `generateConnectedGlossarySuggestions`
/// читает `Config.transcriptionGlossary` внутри `await`, а
/// `SettingsDuringCallTests.glossarySnapshots` в это время пишет туда
/// «Falcon, Kubernetes». Термин-кандидат в том тесте — ровно «Falcon», и когда
/// он оказывался в глоссарии заранее, служба отбрасывала его как уже
/// известный: подсказок ноль, и тест падал сообщением «нечего принимать».
///
/// Держать `NSLock` через `await` нельзя: после возобновления код может
/// оказаться на другом потоке, а снимать `NSLock` обязан тот же поток, который
/// его поставил. Отсюда актор с очередью ожидающих — критическая секция
/// переживает `await`, и механизм остаётся один на синхронные и асинхронные
/// тела сразу. Два разных замка друг друга не исключали бы вовсе.
enum SharedDefaults {

    /// Мьютекс, переживающий `await`.
    ///
    /// Сам по себе актор взаимного исключения тут не даёт: он реентерабелен и
    /// на каждом `await` внутри секции впустил бы следующего. Поэтому занятость
    /// хранится явным флагом, а ожидающие стоят в очереди.
    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            while busy {
                await withCheckedContinuation { waiters.append($0) }
            }
            busy = true
        }

        func release() {
            busy = false
            // Ровно одного: будить всех значило бы отдать секцию тому, кто
            // проснулся первым, а остальным — ещё один холостой круг.
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
    }

    private static let gate = Gate()

    /// Run `body` with exclusive access to the shared defaults.
    ///
    /// Take this around the WHOLE set-then-assert, not just the write — the
    /// race is between one suite's write and another suite's read. That
    /// includes any `await` in between: the read that loses the race is often
    /// several frames deep inside the code under test rather than in the test.
    static func withExclusiveAccess<T>(_ body: () async throws -> T) async rethrows -> T {
        await gate.acquire()
        do {
            let value = try await body()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }
}
