import AVFoundation
import Foundation
import OrakulCore

/// Запись с микрофона — единственная часть, которую нельзя проверить тестом.
///
/// Живёт в исполняемой цели, а не в ядре: `OrakulCore` не знает про AVFoundation
/// именно затем, чтобы порт на Windows заменял этот файл, а не переписывал
/// продукт. Всё, что можно решить без микрофона, решено в `AudioAccumulator` и
/// покрыто тестами; здесь остался тонкий слой поверх системного API.
///
/// Системный звук — то, что говорят собеседники, — сюда пока не входит: он идёт
/// через ScreenCaptureKit и требует отдельного разрешения. Это следующий шаг.
enum MicrophoneRecorder {

    enum RecordingError: Error, CustomStringConvertible {
        case permissionDenied
        case engineFailed(String)
        case converterUnavailable

        var description: String {
            switch self {
            case .permissionDenied:
                return """
                Нет доступа к микрофону. macOS спрашивает разрешение один раз, и \
                если его отклонили, включать надо руками:
                Системные настройки → Конфиденциальность и безопасность → Микрофон.
                """
            case .engineFailed(let message):
                return "Не смог запустить запись: \(message)"
            case .converterUnavailable:
                return "Не смог привести звук микрофона к 16 кГц моно."
            }
        }
    }

    /// Спросить разрешение и дождаться ответа.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    /// Записать с микрофона указанное число секунд.
    ///
    /// Возвращает сэмплы в 16 кГц моно — ровно то, что ждёт движок. Пересчёт
    /// делает системный конвертер: свой ресемплер был бы худшим местом для
    /// самодеятельности.
    static func record(seconds: Double,
                       progress: @escaping (Double) -> Void = { _ in }) async throws -> [Float] {
        guard await requestPermission() else { throw RecordingError.permissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(WAVFile.sampleRate),
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecordingError.converterUnavailable
        }

        let collected = Collected(limitSeconds: seconds)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: target,
                                                   frameCapacity: capacity) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0] else { return }
            collected.append(Array(UnsafeBufferPointer(start: channel,
                                                       count: Int(converted.frameLength))))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.engineFailed(error.localizedDescription)
        }

        // Опрашиваем накопленное, а не спим ровно N секунд: если микрофон молчит
        // по техническим причинам, лучше выйти по времени, чем ждать буферов,
        // которых не будет.
        let deadline = Date().addingTimeInterval(seconds + 2)
        while collected.seconds < seconds && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            progress(collected.seconds)
        }

        engine.stop()
        input.removeTap(onBus: 0)
        return collected.samples
    }

    /// Буфер под замком: обработчик микрофона зовут с аудиопотока.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulator: AudioAccumulator

        init(limitSeconds: Double) {
            accumulator = AudioAccumulator(limitSeconds: limitSeconds)
        }

        func append(_ samples: [Float]) {
            lock.lock(); defer { lock.unlock() }
            accumulator.append(samples)
        }

        var seconds: Double {
            lock.lock(); defer { lock.unlock() }
            return accumulator.seconds
        }

        var samples: [Float] {
            lock.lock(); defer { lock.unlock() }
            return accumulator.samples
        }
    }
}
