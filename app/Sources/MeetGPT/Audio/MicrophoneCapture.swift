import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio via AVAudioEngine.
///
/// Voice processing (kAudioUnitSubType_VoiceProcessingIO — echo cancellation +
/// noise suppression + AGC) is opt-in and enabled ROUTE-AWARE, not blanket:
///
///  - Built-in / external speakers → VP ON. Echo cancellation keeps the remote
///    participants (played through the speakers, and already captured cleanly
///    via ScreenCaptureKit) out of the mic track.
///  - Headphones (3.5mm jack, Bluetooth, AirPlay) → VP OFF. There is no
///    acoustic path from output to mic, so echo cancellation buys nothing —
///    but VP's costs remain: macOS ducks ALL other system audio while VPIO
///    runs (duckingLevel .min is the floor; there is no zero-duck API —
///    WWDC23 10235), plus an inherent output gain change Apple confirms is
///    expected (forums #733733). Skipping VP here removes both.
///  - Aggregate input devices → VP OFF (VP scrambles their channel layout —
///    forums #710151).
///
/// On speakers, system-audio attenuation while recording is Apple-inherent and
/// cannot be disabled — only minimized (.min). For that reason voice processing
/// defaults off; raw microphone capture never changes the user's playback level.
final class MicrophoneCapture {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private var onBuffer: BufferHandler?
    private var configChangeObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?

    /// Кого позвать, если микрофон замолчал и вернуть его не удалось.
    ///
    /// Здесь это уже случалось: комментарий у `scheduleRestartAfterConfigChange`
    /// описывает, как подавление уведомлений «оставило микрофон мёртвым на всю
    /// запись». Тот случай починили, но неудачу самого перезапуска по-прежнему
    /// писали в лог и возвращались — а это то же самое для человека: он
    /// говорит, индикатор горит, и его половины разговора в расшифровке нет.
    ///
    /// Повод обыденный: наушники отключились, USB-микрофон вынули, macOS
    /// переключила устройство. Не сбой, а вторник.
    private var onStopped: (@Sendable (Error) -> Void)?
    /// Snapshotted for the whole recording. A route-change restart must not
    /// silently adopt a Settings edit that was documented as "next recording".
    private var noiseSuppressionEnabledForRun = false
    /// Whether the CURRENT engine run has voice processing engaged — lets the
    /// caller pick the matching VAD gate for this source.
    private(set) var voiceProcessingActive = false

    func start(noiseSuppressionEnabled: Bool = Config.micNoiseSuppressionEnabled,
               onBuffer: @escaping BufferHandler,
               onStopped: (@Sendable (Error) -> Void)? = nil) throws {
        self.onBuffer = onBuffer
        self.onStopped = onStopped
        noiseSuppressionEnabledForRun = noiseSuppressionEnabled
        installConfigChangeObserver()
        do {
            try startEngine()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        // Первым делом: остановка по «Стоп» — не потеря микрофона. Без этой
        // строки любое штатное завершение записи могло прийти наверх как
        // «микрофон пропал», а тревога после каждого звонка перестаёт работать
        // тревогой. Ровно эта же ошибка была в SystemAudioCapture.
        onStopped = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onBuffer = nil
    }

    // MARK: - Engine lifecycle

    private func startEngine() throws {
        let input = engine.inputNode
        let wantVP = noiseSuppressionEnabledForRun && AudioRoute.voiceProcessingWorthwhile()

        // VP can only be toggled while the engine is stopped — this runs
        // before start() and again from the config-change restart path.
        if input.isVoiceProcessingEnabled != wantVP {
            do {
                try input.setVoiceProcessingEnabled(wantVP)
            } catch {
                Log.audio.error("Voice processing toggle(\(wantVP)) failed, using raw mic: \(error.localizedDescription, privacy: .public)")
            }
        }
        voiceProcessingActive = input.isVoiceProcessingEnabled

        if voiceProcessingActive {
            // Undocumented default — pin it and log what it was (forums have
            // reports of VP capture arriving muted).
            let wasMuted = input.isVoiceProcessingInputMuted
            input.isVoiceProcessingInputMuted = false
            if wasMuted { Log.audio.notice("VP input was muted at start — unmuted") }
            applyDuckingConfig(input)
        }

        // Install the tap BEFORE starting the engine. The tap is the input
        // node's render consumer; starting an otherwise unconnected graph and
        // adding the tap later leaves the engine running but produces zero mic
        // callbacks. `format: nil` lets AVAudioEngine negotiate the real output
        // format after VPIO has changed the node to its multi-channel shape.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        let format = input.outputFormat(forBus: 0)
        Log.audio.notice("Mic tap: \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch interleaved=\(format.isInterleaved) vp=\(self.voiceProcessingActive) route=\(AudioRoute.describeOutput(), privacy: .public)")
    }

    private func applyDuckingConfig(_ input: AVAudioInputNode) {
        guard #available(macOS 14.0, *) else {
            Log.audio.notice("VP ducking config unavailable (needs macOS 14+) — system audio will duck at the OS default level")
            return
        }
        // .min is the FLOOR, not "off" — macOS has no zero-duck API. Advanced
        // ducking stays off: it ducks harder whenever either side talks, which
        // in a meeting is nearly always.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min)
        let applied = input.voiceProcessingOtherAudioDuckingConfiguration
        Log.audio.notice("VP ducking config: advanced=\(applied.enableAdvancedDucking) level=\(String(describing: applied.duckingLevel), privacy: .public)")
    }

    /// Device/format changes (headphones plugged/unplugged, default device
    /// switched) stop the engine. Restart it — re-evaluating the VP decision
    /// for the NEW route (that's the whole point of route-aware VP).
    private func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRestartAfterConfigChange() }
        }
    }

    /// VoiceProcessingIO and real device changes can stop AVAudioEngine before
    /// posting this notification. Coalesce the burst, let the new route settle,
    /// then restart whenever the engine really is down. The former one-second
    /// suppression discarded the only notification and left the mic dead for
    /// the entire recording.
    private func scheduleRestartAfterConfigChange() {
        guard onBuffer != nil else { return }
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restartAfterConfigChangeIfNeeded()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Что делать, когда микрофон вернуть не удалось.
    ///
    /// Отдельным методом, потому что настоящий отказ `AVAudioEngine` в прогоне
    /// не воспроизвести: нужен реальный микрофон и реальное отключение
    /// устройства. Проверять же нужно именно эту связь — раньше её и не было.
    func handleRestartFailure(_ error: Error) {
        Log.audio.error("Mic restart after route change failed: \(error.localizedDescription, privacy: .public)")
        onStopped?(error)
    }

#if DEBUG
    /// Поставить обработчик без запуска движка — `start()` требует настоящего
    /// микрофона, которого в прогоне нет.
    func setStoppedHandlerForTesting(_ handler: @escaping @Sendable (Error) -> Void) {
        onStopped = handler
    }
#endif

    private func restartAfterConfigChangeIfNeeded() {
        restartWorkItem = nil
        guard onBuffer != nil, !engine.isRunning else { return }
        Log.audio.notice("Audio route changed — restarting mic capture")
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine()
        } catch {
            handleRestartFailure(error)
        }
    }
}

// MARK: - Output-route detection

/// Answers one question via CoreAudio: is voice processing worth its cost on
/// the current route? Headphones → no (no echo path). Aggregate input → no
/// (VP breaks it). Anything else / query failure → yes (safe default:
/// speakers are the case echo cancellation exists for).
enum AudioRoute {
    static func voiceProcessingWorthwhile() -> Bool {
        if let t = transportType(of: defaultDevice(input: false)) {
            // No acoustic echo path — VP would only buy ducking + gain loss.
            if t == kAudioDeviceTransportTypeBluetooth
                || t == kAudioDeviceTransportTypeBluetoothLE
                || t == kAudioDeviceTransportTypeAirPlay { return false }
            if t == kAudioDeviceTransportTypeBuiltIn, isBuiltInHeadphoneJack() { return false }
        }
        if let t = transportType(of: defaultDevice(input: true)),
           t == kAudioDeviceTransportTypeAggregate { return false }
        return true
    }

    static func describeOutput() -> String {
        guard let t = transportType(of: defaultDevice(input: false)) else { return "unknown" }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn:
            return isBuiltInHeadphoneJack() ? "builtin-headphones" : "builtin-speakers"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        default: return "other"
        }
    }

    private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// The system output's mute flag and volume, as a loggable string.
    ///
    /// Exists because "I could not hear anything during the recording" is
    /// otherwise undiagnosable after the fact: the capture stack does not
    /// change playback, so the interesting question is whether the OUTPUT
    /// device was muted or turned down while we recorded, and by the time
    /// anyone looks the state is gone. Logged at start and stop so a report
    /// comes with the two readings that separate "we silenced it" from "it was
    /// already silent".
    static func describeOutputLevel() -> String {
        guard let device = defaultDevice(input: false) else { return "output=unknown" }
        var muted = UInt32(0)
        var mutedSize = UInt32(MemoryLayout<UInt32>.size)
        var mutedAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let mutedStatus = AudioObjectGetPropertyData(
            device, &mutedAddress, 0, nil, &mutedSize, &muted)

        var volume = Float32(0)
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let volumeStatus = AudioObjectGetPropertyData(
            device, &volumeAddress, 0, nil, &volumeSize, &volume)

        let mutedText = mutedStatus == noErr ? (muted != 0 ? "yes" : "no") : "?"
        let volumeText = volumeStatus == noErr ? String(format: "%.2f", volume) : "?"
        return "output=\(describeOutput()) muted=\(mutedText) volume=\(volumeText)"
    }

    private static func transportType(of device: AudioDeviceID?) -> UInt32? {
        guard let device else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    /// The 3.5mm jack reports as a BuiltIn-transport device too; its active
    /// data source distinguishes headphones ('hdpn') from internal speakers.
    private static func isBuiltInHeadphoneJack() -> Bool {
        guard let device = defaultDevice(input: false) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source)
        return status == noErr && source == 0x6864_706E  // 'hdpn'
    }
}
