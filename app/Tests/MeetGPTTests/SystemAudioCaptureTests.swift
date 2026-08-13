import Foundation
import Testing
import ScreenCaptureKit
@testable import MeetGPT

/// The system-audio capture surface (M8b). Locks the narrowing contract: audio
/// only, our own playback excluded, video kept to the 2×2 minimum with no cursor
/// — so a future edit can't silently widen what the sandboxed app captures.
@Suite("SystemAudioCapture config")
struct SystemAudioCaptureTests {
    @Test("the capture config is narrow: audio-only, own audio excluded, minimal video")
    func narrowCaptureSurface() {
        let c = SystemAudioCapture.makeStreamConfiguration()
        #expect(c.capturesAudio == true)
        #expect(c.excludesCurrentProcessAudio == true)   // no self-feedback
        #expect(c.sampleRate == 48_000)
        #expect(c.channelCount == 2)
        // Video is required by SCStream but we decode none — keep it minimal.
        #expect(c.width == 2)
        #expect(c.height == 2)
        #expect(c.showsCursor == false)
    }

    /// Обрыв потока посреди записи.
    ///
    /// Худший отказ этого продукта и до сих пор самый тихий: ScreenCaptureKit
    /// зовёт `stream(_:didStopWithError:)`, делегат писал строку в лог и
    /// возвращался. Запись продолжалась, индикатор горел, микрофон писался — а
    /// собеседников не было. Человек узнавал об этом из расшифровки, когда
    /// звонок уже кончился.
    ///
    /// Разрешение «Запись экрана» можно отозвать прямо во время звонка, а
    /// дисплей — отключить, так что это не экзотика.
    @Test("оборванный поток доходит до приложения, а не только до лога")
    @MainActor
    func lostStreamReachesTheApp() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        #expect(!state.systemAudioLostDuringRecording)

        state.noteSystemAudioLost()

        #expect(state.systemAudioLostDuringRecording,
                "поток оборвался, а приложение об этом не знает")
        let shown = try? #require(state.lastError)
        #expect(shown?.contains("Звук собеседников пропал") == true,
                "человеку не сказали, что пишется половина звонка")
        // Сказать «пропал» мало: нужно назвать обычную причину, иначе это
        // сообщение не превращается ни в какое действие.
        #expect(shown?.contains("Запись экрана") == true,
                "предупреждение не подсказывает, где искать причину")
    }

    @Test("после остановки записи обрыв уже не новость")
    @MainActor
    func stoppedRecordingRaisesNothing() {
        // `stop()` снимает обработчик до остановки потока, но делегат может
        // прийти и другим путём. Показать «связь оборвалась» после того, как
        // человек сам нажал «Стоп», — это ложная тревога, а их запоминают.
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: false)

        state.noteSystemAudioLost()

        #expect(!state.systemAudioLostDuringRecording)
        #expect(state.lastError == nil, "тревога после «Стоп» — ложная")
    }

    /// Сама проводка: обрыв потока обязан дойти до владельца.
    ///
    /// Тесты выше проверяли реакцию `AppState`, вызывая его напрямую, и потому
    /// проходили даже с вырезанным `onStopped?(error)` — то есть ровно с той
    /// поломкой, которая тут и была. Проверять надо связь, а не только оба её
    /// конца по отдельности.
    @Test("обрыв потока доходит до владельца захвата")
    func stoppedStreamNotifiesTheOwner() async throws {
        let capture = SystemAudioCapture()
        let box = LostBox()
        // `start()` в тесте не вызвать — он идёт в ScreenCaptureKit за
        // разрешением. Обработчик ставится тем же путём, что и в `start`.
        capture.setStoppedHandlerForTesting { error in box.record(error) }

        capture.handleStreamStopped(URLError(.networkConnectionLost))

        #expect(box.count == 1, "поток оборвался, а владелец захвата не узнал")
    }
    @Test("после остановки захвата обработчик уже не зовут")
    func stopClearsTheHandler() async {
        // Нормальное завершение записи ScreenCaptureKit тоже сообщает делегату.
        // Если обработчик при этом остался, каждый штатный «Стоп» показывал бы
        // «связь оборвалась» — ложная тревога после каждого звонка.
        let capture = SystemAudioCapture()
        let box = LostBox()
        capture.setStoppedHandlerForTesting { error in box.record(error) }

        await capture.stop()
        capture.handleStreamStopped(URLError(.cancelled))

        #expect(box.count == 0, "после «Стоп» обрыв всё ещё доходит наверх")
    }

    @Test("делегат ScreenCaptureKit ведёт в обработчик, а не в лог")
    func delegateForwardsToTheHandler() throws {
        // Единственная строка, которую нельзя выполнить в прогоне: делегату
        // нужен настоящий `SCStream`, а его не создать без разрешения на запись
        // экрана. Поэтому проверяется текст — структурно, и честно об этом.
        // Именно эта строка когда-то и отсутствовала.
        let source = try String(contentsOfFile: Self.sourcePath, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let delegate = try #require(
            code.range(of: "func stream(_ stream: SCStream, didStopWithError"),
            "делегат обрыва исчез из SystemAudioCapture")
        let body = code[delegate.lowerBound...].prefix(220)
        #expect(body.contains("handleStreamStopped"),
                "делегат снова никуда не ведёт — обрыв опять останется в логе")
    }

    /// Путь к исходнику: тест читает код, потому что выполнить его не может.
    static let sourcePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MeetGPT/Audio/SystemAudioCapture.swift").path
}

/// Микрофон: та же поломка, зеркально.
///
/// Системный звук — половина собеседников, микрофон — своя. Пропажа второй
/// встречается чаще: наушники отключились, USB-микрофон вынули, macOS сменила
/// устройство ввода. `MicrophoneCapture` это умеет переживать — перезапускает
/// движок, — но НЕУДАЧУ перезапуска писал в лог и возвращался. Человек
/// продолжал говорить в тишину.
@Suite("Потеря микрофона")
struct MicrophoneLossTests {

    @Test("неудачный перезапуск доходит до владельца, а не только до лога")
    func failedRestartNotifiesTheOwner() {
        let capture = MicrophoneCapture()
        let box = LostBox()
        // `start()` в прогоне не вызвать: он идёт к настоящему микрофону.
        capture.setStoppedHandlerForTesting { error in box.record(error) }

        capture.handleRestartFailure(URLError(.cannotConnectToHost))

        #expect(box.count == 1, "микрофон не вернулся, а приложение не знает")
    }

    @Test("после «Стоп» пропажа микрофона уже не новость")
    func stopClearsTheHandler() {
        // Иначе каждое штатное завершение записи выглядело бы как потеря
        // микрофона — ровно та ошибка, что была в SystemAudioCapture.
        let capture = MicrophoneCapture()
        let box = LostBox()
        capture.setStoppedHandlerForTesting { error in box.record(error) }

        capture.stop()
        capture.handleRestartFailure(URLError(.cancelled))

        #expect(box.count == 0, "после «Стоп» пропажа всё ещё доходит наверх")
    }

    @Test("приложение объясняет, какая половина звонка пропала")
    @MainActor
    func appExplainsWhichHalfIsMissing() {
        // «Проблема со звуком» бесполезно: действия разные. Пропал микрофон —
        // проверь наушники; пропали собеседники — проверь разрешение.
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)

        state.noteMicrophoneLost()

        #expect(state.microphoneLostDuringRecording)
        let shown = state.lastError ?? ""
        #expect(shown.contains("Микрофон пропал"), "не сказано, что пропала своя половина")
        #expect(shown.contains("наушники"), "не названа обычная причина")
        // И это не должно выглядеть как потеря собеседников.
        #expect(!state.systemAudioLostDuringRecording,
                "потеря микрофона выставила флаг потери собеседников")
    }

    @Test("перезапуск после смены устройства ведёт в обработчик, а не в лог")
    func restartCatchForwardsToTheHandler() throws {
        // Выполнить этот путь в прогоне нельзя: нужен настоящий микрофон и
        // настоящее отключение устройства. Поэтому проверяется текст —
        // структурно, и честно об этом. Именно эта строка и отсутствовала:
        // `catch` писал в лог и возвращался.
        let source = try String(contentsOfFile: Self.sourcePath, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let restart = try #require(
            code.range(of: "private func restartAfterConfigChangeIfNeeded"),
            "перезапуск после смены устройства исчез")
        let body = code[restart.lowerBound...].prefix(400)
        #expect(body.contains("handleRestartFailure"),
                "неудачный перезапуск снова никуда не ведёт — микрофон умрёт молча")
    }

    /// Путь к исходнику: тест читает код, потому что выполнить его не может.
    static let sourcePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MeetGPT/Audio/MicrophoneCapture.swift").path

    @Test("после остановки записи тревоги нет")
    @MainActor
    func silentWhenNotRecording() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: false)

        state.noteMicrophoneLost()

        #expect(!state.microphoneLostDuringRecording)
        #expect(state.lastError == nil)
    }
}

/// Счётчик для замыкания, которое зовут не с главного потока.
private final class LostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ error: Error) { lock.lock(); value += 1; lock.unlock() }
}
