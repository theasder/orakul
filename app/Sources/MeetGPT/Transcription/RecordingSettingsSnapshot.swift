import Foundation

/// Settings captured before audio starts and shared by every transcription
/// backend. Language, AEC, model, and vocabulary remain immutable for the call;
/// an explicit engine selection is the one supported live handoff and replaces
/// only `engine` in the published snapshot after that handoff succeeds.
struct RecordingSettingsSnapshot: Equatable {
    let engine: TranscriptionEngine
    let language: String
    let localModel: String
    let microphoneNoiseSuppression: Bool
    let glossary: String
    let assemblyDiarization: Bool
    let localDiarization: Bool
    let localDiarizationRemoteSpeakerCount: Int

    init(
        engine: TranscriptionEngine,
        language: String,
        localModel: String,
        microphoneNoiseSuppression: Bool,
        glossary: String,
        assemblyDiarization: Bool,
        localDiarization: Bool = false,
        localDiarizationRemoteSpeakerCount: Int = 1
    ) {
        self.engine = engine
        self.language = language
        self.localModel = localModel
        self.microphoneNoiseSuppression = microphoneNoiseSuppression
        self.glossary = glossary
        self.assemblyDiarization = assemblyDiarization
        self.localDiarization = localDiarization
        self.localDiarizationRemoteSpeakerCount =
            LocalDiarization.normalizedRemoteSpeakerCount(
                localDiarizationRemoteSpeakerCount)
    }

    static func configured() -> RecordingSettingsSnapshot {
        RecordingSettingsSnapshot(
            engine: Config.transcriptionEngineValue,
            language: Config.transcriptionLanguage,
            localModel: Config.localWhisperModel,
            microphoneNoiseSuppression: Config.micNoiseSuppressionEnabled,
            glossary: Config.transcriptionGlossary,
            assemblyDiarization: Config.assemblyAIDiarizationEnabled,
            localDiarization: Config.localDiarizationEnabled,
            localDiarizationRemoteSpeakerCount:
                Config.localDiarizationRemoteSpeakerCount
        )
    }

    var glossaryTerms: [String] { Glossary.terms(from: glossary) }
    var glossaryHint: String { Glossary.promptHint(from: glossary) }

    func replacingEngine(with engine: TranscriptionEngine) -> RecordingSettingsSnapshot {
        RecordingSettingsSnapshot(
            engine: engine,
            language: language,
            localModel: localModel,
            microphoneNoiseSuppression: microphoneNoiseSuppression,
            glossary: glossary,
            assemblyDiarization: assemblyDiarization,
            localDiarization: localDiarization,
            localDiarizationRemoteSpeakerCount:
                localDiarizationRemoteSpeakerCount)
    }
}
