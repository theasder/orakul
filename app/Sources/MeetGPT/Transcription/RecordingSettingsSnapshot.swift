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

    static func configured() -> RecordingSettingsSnapshot {
        RecordingSettingsSnapshot(
            engine: Config.transcriptionEngineValue,
            language: Config.transcriptionLanguage,
            localModel: Config.localWhisperModel,
            microphoneNoiseSuppression: Config.micNoiseSuppressionEnabled,
            glossary: Config.transcriptionGlossary,
            assemblyDiarization: Config.assemblyAIDiarizationEnabled
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
            assemblyDiarization: assemblyDiarization)
    }
}
