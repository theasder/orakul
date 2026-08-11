import AppKit
import Darwin
import Foundation

/// Fresh, causal evidence for the one promo flow the installed-app suite is
/// allowed to drive. The receipt is armed only by a nonce-authorized command;
/// normal developer paywall use never creates one.
struct LiveTestPromoRedemptionReceipt: Encodable, Equatable, Sendable {
    enum Outcome: String, Encodable, Equatable, Sendable {
        case armed, inProgress, success, failure
    }

    let commandID: String
    let preparedAt: Double
    private(set) var exactCodeMatch: Bool?
    private(set) var startedAt: Double?
    private(set) var completedAt: Double?
    private(set) var outcome: Outcome
    private(set) var planID: String?
    private(set) var planName: String?
    private(set) var tier: String?
    private(set) var previewActive: Bool

    static func armed(commandID: String, at: Double, previewActive: Bool)
        -> LiveTestPromoRedemptionReceipt {
        LiveTestPromoRedemptionReceipt(
            commandID: commandID, preparedAt: at, exactCodeMatch: nil,
            startedAt: nil, completedAt: nil, outcome: .armed,
            planID: nil, planName: nil, tier: nil,
            previewActive: previewActive)
    }

    mutating func begin(code: String, exactCode: String, at: Double,
                        previewActive: Bool) {
        guard outcome == .armed else { return }
        exactCodeMatch = code == exactCode
        startedAt = at
        outcome = .inProgress
        self.previewActive = previewActive
    }

    mutating func succeed(planID: String, planName: String, tier: String,
                          at: Double, previewActive: Bool) {
        guard outcome == .inProgress else { return }
        completedAt = at
        outcome = .success
        self.planID = planID
        self.planName = planName
        self.tier = tier
        self.previewActive = previewActive
    }

    mutating func fail(at: Double, previewActive: Bool) {
        guard outcome == .inProgress else { return }
        completedAt = at
        outcome = .failure
        self.previewActive = previewActive
    }
}

/// Dev-build-only automation surface for the live-test driver
/// (`mac/livetest.sh`): the script exercises the REAL app — record, scripted
/// speech through the speakers, prompt buttons — and reads state snapshots
/// back, instead of brittle pixel/AX scripting.
///
/// Transport is DistributedNotificationCenter (local machine only). Gated by
/// a dev build plus a per-run launch nonce and owner-only artifact root. A
/// normal developer launch has neither value, so the hooks remain disabled.
///
/// Commands:
///   ai.cruxwing.livetest.toggleRecording
///   ai.cruxwing.livetest.runPrompt    userInfo["id"]   = QuickPrompt id
///   ai.cruxwing.livetest.cancelPrompt userInfo["exchangeID"] = exact active id
///   ai.cruxwing.livetest.dumpState    userInfo["path"] = output JSON path,
///                                     userInfo["requestID"] = acknowledgement id
///   ai.cruxwing.livetest.ask          userInfo["text"] = free-form composer ask
///   ai.cruxwing.livetest.injectLine   userInfo["text","source"("mic"|"system"),"speaker"?]
///   ai.cruxwing.livetest.latchQuota   userInfo["message"]? — simulate the 429 latch
///   ai.cruxwing.livetest.promptSurface userInfo["type"] = poll | mandatory | contextual
///   ai.cruxwing.livetest.clearPromptSurface
///   ai.cruxwing.livetest.newCall      — Start new call (resets per-call state)
///   ai.cruxwing.livetest.redeem       userInfo["code"]? — device-redeem a promo
///   ai.cruxwing.livetest.preparePromoRedemption userInfo["commandID"]
///   ai.cruxwing.livetest.openSettings  userInfo["tab"] = SettingsTab raw value
///   ai.cruxwing.livetest.closeSettings
///   ai.cruxwing.livetest.applySetting  userInfo["id","value"] — whitelisted only
///   ai.cruxwing.livetest.restoreSettings userInfo["finishRun"]? — restore
///       launch-time preferences; true also releases real-entitlement mode
///   ai.cruxwing.livetest.setSyntheticCallGoal userInfo["fixtureID","commandID"]
///   ai.cruxwing.livetest.refreshBlindSpot userInfo["fixtureID","commandID"]
///   ai.cruxwing.livetest.glossarySuggestions userInfo["action","commandID"]
///       action = generate | acceptFirst | rejectFirst (fixed synthetic data)
@MainActor
enum LiveTestHooks {
    static let toggleRecording = Notification.Name("ai.cruxwing.livetest.toggleRecording")
    static let runPrompt = Notification.Name("ai.cruxwing.livetest.runPrompt")
    static let cancelPrompt = Notification.Name("ai.cruxwing.livetest.cancelPrompt")
    /// Fixed, transcript-only prompt used to prove model snapshot semantics
    /// without spending connected-app grounding tokens in every live condition.
    nonisolated static let modelSnapshotPromptID = "livetest-model-snapshot"
    static let dumpState = Notification.Name("ai.cruxwing.livetest.dumpState")
    static let ask = Notification.Name("ai.cruxwing.livetest.ask")
    static let injectLine = Notification.Name("ai.cruxwing.livetest.injectLine")
    static let latchQuota = Notification.Name("ai.cruxwing.livetest.latchQuota")
    static let promptSurface = Notification.Name("ai.cruxwing.livetest.promptSurface")
    static let clearPromptSurface = Notification.Name("ai.cruxwing.livetest.clearPromptSurface")
    static let newCall = Notification.Name("ai.cruxwing.livetest.newCall")
    static let redeem = Notification.Name("ai.cruxwing.livetest.redeem")
    static let preparePromoRedemption = Notification.Name(
        "ai.cruxwing.livetest.preparePromoRedemption")
    static let openSettings = Notification.Name("ai.cruxwing.livetest.openSettings")
    static let closeSettings = Notification.Name("ai.cruxwing.livetest.closeSettings")
    static let applySetting = Notification.Name("ai.cruxwing.livetest.applySetting")
    static let restoreSettings = Notification.Name("ai.cruxwing.livetest.restoreSettings")
    static let setSyntheticCallGoal = Notification.Name(
        "ai.cruxwing.livetest.setSyntheticCallGoal")
    static let refreshBlindSpot = Notification.Name(
        "ai.cruxwing.livetest.refreshBlindSpot")
    static let glossarySuggestions = Notification.Name(
        "ai.cruxwing.livetest.glossarySuggestions")
    /// The local-only code the backend seeds for automated suites. Redeeming
    /// it entitles the APP's own session — a shell script holding a token does
    /// not help, because the app authenticates its own LLM calls.
    /// `nonisolated` so the notification handler's default-value autoclosure can
    /// read it off the main actor.
    nonisolated static let devPromoCode = "DEV-UNLIMITED-LOCAL"
    /// The notification accepts only this fixture identifier. The call goal is
    /// compiled into the dev hook rather than accepted as cross-process text,
    /// keeping this automation seam bounded and synthetic by construction.
    nonisolated static let syntheticBlindSpotFixtureID = "project-falcon"
    nonisolated static let syntheticBlindSpotGoal =
        "Identify the highest-impact missing decision, risk, or unsupported assumption in the Project Falcon rollout, then give one concrete next question."
    nonisolated static let maximumCommandIDBytes = 128
    private static var observers: [NSObjectProtocol] = []
    private static let expectedNonce =
        ProcessInfo.processInfo.environment["CRUXWING_LIVETEST_NONCE"] ?? ""
    private static let artifactRoot: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["CRUXWING_LIVETEST_ARTIFACT_ROOT"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }()
    private static let runStartedAt: Double? = {
        guard let raw = ProcessInfo.processInfo.environment["CRUXWING_LIVETEST_STARTED_AT"] else {
            return nil
        }
        return Double(raw)
    }()
    private static var activePollSurfaceID: String?
    private static var activePollClarificationID: UUID?
    private static var activeMandatorySurfaceID: String?
    private static var lastInjectedSurfaceID: String?
    private static var lastInjectedSurfaceType: String?
    private static var settingsOpener: (() -> Void)?
    private static var settingsWindowNumber: Int?
    private static var settingMutationRevision = 0
    private static var lastSettingMutationID: String?
    private static var lastSettingMutationAt: Double?
    private static var lastSyntheticGoalCommandID: String?
    private static var lastSyntheticGoalAppliedAt: Double?
    private static var lastBlindSpotRefreshCommandID: String?
    private static var lastBlindSpotRefreshRequestedAt: Double?
    private static var lastGlossarySuggestionCommandID: String?
    private static var lastGlossarySuggestionAction: String?
    private static var lastGlossarySuggestionAppliedAt: Double?
    private static var promoRedemptionReceipt: LiveTestPromoRedemptionReceipt?

    private struct SettingsBaseline {
        let selectedTab: SettingsTab
        let appearance: AppAppearance
        let callDetection: Bool
        let ignoreMedia: Bool
        let meetingReminders: Bool
        let reminderMinutes: Int
        let roleID: String?
        let recordingContext: RecordingContextSelection
        let brainstorm: Bool
        let agenda: Bool
        let factCheck: Bool
        let rhetoric: Bool
        let facilitation: Bool
        let engine: TranscriptionEngine
        let language: String
        let localModel: String
        let microphoneNoiseSuppression: Bool
        let adaptiveLocal: Bool
        let glossary: String
        let assemblyDiarization: Bool
        let firefliesEnhance: Bool
        let connectedAppsGrounding: Bool
        let selectedModelID: String
        let shareAnalytics: Bool
        let devTierOverride: Tier?
    }
    private static var settingsBaseline: SettingsBaseline?

    /// Registered from a tiny SwiftUI bridge so automation invokes the same
    /// `openSettings` environment action as SettingsLink on macOS 14+.
    static func registerSettingsOpener(_ opener: (() -> Void)?) {
        guard Config.isDevBuild else { return }
        settingsOpener = opener
    }

    nonisolated static func validCommandID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= maximumCommandIDBytes else {
            return nil
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    nonisolated static func syntheticGoal(for fixtureID: String?) -> String? {
        guard fixtureID == syntheticBlindSpotFixtureID else { return nil }
        return syntheticBlindSpotGoal
    }

    nonisolated static func validLiveTestNonce(_ nonce: String) -> Bool {
        guard (32...128).contains(nonce.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return nonce.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Both the launch configuration and every notification are checked. This
    /// prevents a dev build launched normally (or pointed at a group-readable
    /// directory) from accepting process-wide distributed notifications.
    nonisolated static func isOwnerOnlyArtifactRoot(
        _ root: URL?, currentUserID: UInt32 = getuid()
    ) -> Bool {
        guard let root, root.isFileURL else { return false }
        do {
            let values = try root.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return false
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  permissions & 0o077 == 0,
                  permissions & 0o700 == 0o700,
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
                  owner == currentUserID else { return false }
            return true
        } catch {
            return false
        }
    }

    nonisolated static func commandAuthorized(
        suppliedNonce: String?, expectedNonce: String,
        artifactRoot: URL?, isDevBuild: Bool
    ) -> Bool {
        guard isDevBuild, validLiveTestNonce(expectedNonce),
              suppliedNonce == expectedNonce else { return false }
        return isOwnerOnlyArtifactRoot(artifactRoot)
    }

    private static func authorized(_ note: Notification) -> Bool {
        commandAuthorized(
            suppliedNonce: note.userInfo?["nonce"] as? String,
            expectedNonce: expectedNonce,
            artifactRoot: artifactRoot,
            isDevBuild: Config.isDevBuild)
    }

    private static var secureRunActive: Bool {
        commandAuthorized(
            suppliedNonce: expectedNonce, expectedNonce: expectedNonce,
            artifactRoot: artifactRoot, isDevBuild: Config.isDevBuild)
    }

    /// Called by the production paywall action, but records only while an exact
    /// nonce-gated live command is armed. This connects real AX interaction to
    /// the state artifact without exposing a general promo automation seam.
    static func recordPromoRedemptionStarted(code: String) {
        guard secureRunActive, var receipt = promoRedemptionReceipt else { return }
        receipt.begin(
            code: code, exactCode: devPromoCode,
            at: Date().timeIntervalSince1970,
            previewActive: Config.devTierOverride != nil)
        promoRedemptionReceipt = receipt
    }

    static func recordPromoRedemptionSucceeded(_ redemption: PaywallAPI.PromoRedemption) {
        guard secureRunActive, var receipt = promoRedemptionReceipt else { return }
        receipt.succeed(
            planID: redemption.planID, planName: redemption.planName,
            tier: redemption.tier.rawValue, at: Date().timeIntervalSince1970,
            previewActive: Config.devTierOverride != nil)
        promoRedemptionReceipt = receipt
    }

    static func recordPromoRedemptionFailed() {
        guard secureRunActive, var receipt = promoRedemptionReceipt else { return }
        receipt.fail(
            at: Date().timeIntervalSince1970,
            previewActive: Config.devTierOverride != nil)
        promoRedemptionReceipt = receipt
    }

    static func confinedDumpURL(_ rawPath: String) -> URL? {
        confinedDumpURL(rawPath, under: artifactRoot)
    }

    static func confinedDumpURL(_ rawPath: String, under root: URL?) -> URL? {
        guard let root else { return nil }

        // Canonicalize the existing parent before appending the not-yet-created
        // file. On macOS an existing `/private/tmp/run` URL standardizes to
        // `/tmp/run`, while `/private/tmp/run/new.json` can remain unchanged
        // until `new.json` exists. Comparing those raw forms rejects a valid
        // owner-only destination. Rebuilding from the canonical parent keeps
        // the confinement check strict and makes both spellings equivalent.
        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard !candidate.lastPathComponent.isEmpty else { return nil }
        let canonicalRoot = root.standardizedFileURL
        let canonicalParent = candidate.deletingLastPathComponent().standardizedFileURL
        guard canonicalParent.path == canonicalRoot.path else { return nil }
        return canonicalParent
            .appendingPathComponent(candidate.lastPathComponent, isDirectory: false)
            .standardizedFileURL
    }

    private static func parsedBool(_ value: Any?) -> Bool? {
        guard let raw = value as? String else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func captureSettingsBaseline(_ state: AppState) -> SettingsBaseline {
        SettingsBaseline(
            selectedTab: state.selectedSettingsTab,
            appearance: Config.appAppearance,
            callDetection: Config.callDetectionEnabled,
            ignoreMedia: Config.ignoreMediaApps,
            meetingReminders: Config.meetingRemindersEnabled,
            reminderMinutes: Config.meetingReminderMinutes,
            roleID: state.userRoleID,
            recordingContext: state.recordingContextSelection,
            brainstorm: state.blindSpotsEnabled,
            agenda: state.agendaCheckingEnabled,
            factCheck: state.liveFactCheckingEnabled,
            rhetoric: state.rhetoricWatchEnabled,
            facilitation: state.facilitationWatchEnabled,
            engine: Config.transcriptionEngineValue,
            language: Config.transcriptionLanguage,
            localModel: Config.localWhisperModel,
            microphoneNoiseSuppression: Config.micNoiseSuppressionEnabled,
            adaptiveLocal: Config.adaptiveLocalWhisperEnabled,
            glossary: Config.transcriptionGlossary,
            assemblyDiarization: Config.assemblyAIDiarizationEnabled,
            firefliesEnhance: Config.firefliesTranscriptEnhanceEnabled,
            connectedAppsGrounding: state.useConnectedAppsInPrompts,
            selectedModelID: state.selectedModelID,
            shareAnalytics: !Config.funnelOptOut,
            devTierOverride: Config.devTierOverride)
    }

    private static func restoreSettingsBaseline(on state: AppState) {
        guard let baseline = settingsBaseline else { return }
        // Production setters are essential here: restoring while recording
        // must reconcile live tasks and active-time accounting too.
        state.setAppearance(baseline.appearance)
        Config.callDetectionEnabled = baseline.callDetection
        state.applyCallDetectionSettings()
        Config.ignoreMediaApps = baseline.ignoreMedia
        Config.meetingRemindersEnabled = baseline.meetingReminders
        Config.meetingReminderMinutes = baseline.reminderMinutes
        state.applyReminderSettings()
        state.userRoleID = baseline.roleID
        state.selectRecordingContext(
            baseline.recordingContext.mode,
            customLabel: baseline.recordingContext.customLabel)
        state.setBlindSpotsEnabled(baseline.brainstorm)
        state.setAgendaCheckingEnabled(baseline.agenda)
        state.setFactCheckDuringCallsEnabled(baseline.factCheck)
        state.setRhetoricDuringCallsEnabled(baseline.rhetoric)
        state.setFacilitationDuringCallsEnabled(baseline.facilitation)
        _ = state.selectTranscriptionEngine(baseline.engine)
        Config.transcriptionLanguage = baseline.language
        Config.localWhisperModel = baseline.localModel
        Config.micNoiseSuppressionEnabled = baseline.microphoneNoiseSuppression
        Config.adaptiveLocalWhisperEnabled = baseline.adaptiveLocal
        Config.transcriptionGlossary = baseline.glossary
        state.resetConnectedGlossarySuggestionReview()
        Config.assemblyAIDiarizationEnabled = baseline.assemblyDiarization
        Config.firefliesTranscriptEnhanceEnabled = baseline.firefliesEnhance
        state.useConnectedAppsInPrompts = baseline.connectedAppsGrounding
        state.selectedModelID = baseline.selectedModelID
        Config.funnelOptOut = !baseline.shareAnalytics
        state.setDevTierOverride(baseline.devTierOverride)
        state.selectedSettingsTab = baseline.selectedTab
        settingMutationRevision &+= 1
        lastSettingMutationID = "restore"
        lastSettingMutationAt = Date().timeIntervalSince1970
        lastGlossarySuggestionCommandID = nil
        lastGlossarySuggestionAction = nil
        lastGlossarySuggestionAppliedAt = nil
    }

    @discardableResult
    private static func applyWhitelistedSetting(id: String, value: String,
                                                to state: AppState) -> Bool {
        let bool = parsedBool(value)
        switch id {
        case "general.appearance":
            guard let appearance = AppAppearance(rawValue: value) else { return false }
            state.setAppearance(appearance)
        case "general.call-detection":
            guard let bool else { return false }
            Config.callDetectionEnabled = bool
            state.applyCallDetectionSettings()
        case "general.ignore-media":
            guard let bool else { return false }; Config.ignoreMediaApps = bool
        case "general.reminders":
            guard let bool else { return false }
            Config.meetingRemindersEnabled = bool
            state.applyReminderSettings()
        case "general.reminder-minutes":
            guard let minutes = Int(value), [1, 5, 10, 15, 30].contains(minutes) else {
                return false
            }
            Config.meetingReminderMinutes = minutes
            state.applyReminderSettings()
        case "general.role":
            if value == "none" {
                state.userRoleID = nil
            } else {
                guard RoleSkillMatrix.positions.contains(where: { $0.id == value }) else {
                    return false
                }
                state.userRoleID = value
            }
        case "recording.context":
            guard let mode = RecordingContextSelection.Mode(rawValue: value) else {
                return false
            }
            // Arbitrary cross-process custom strings stay forbidden; the fixed
            // live media fixtures exercise every preset while custom input is
            // covered through the real alert and bounded unit tests.
            guard mode != .custom else { return false }
            state.selectRecordingContext(mode)
        case "ai.brainstorm":
            guard let bool else { return false }; state.setBlindSpotsEnabled(bool)
        case "ai.agenda":
            guard let bool else { return false }; state.setAgendaCheckingEnabled(bool)
        case "ai.fact-check":
            guard let bool else { return false }; state.setFactCheckDuringCallsEnabled(bool)
        case "ai.rhetoric":
            guard let bool else { return false }; state.setRhetoricDuringCallsEnabled(bool)
        case "ai.facilitation":
            guard let bool else { return false }; state.setFacilitationDuringCallsEnabled(bool)
        case "transcription.aec":
            guard let bool else { return false }; Config.micNoiseSuppressionEnabled = bool
        case "transcription.adaptive":
            guard let bool else { return false }; Config.adaptiveLocalWhisperEnabled = bool
        case "transcription.language":
            guard Config.transcriptionLanguageOptions.contains(where: { $0.code == value })
            else { return false }
            Config.transcriptionLanguage = value
        case "transcription.engine":
            guard let engine = TranscriptionEngine(rawValue: value),
                  Config.engineAvailable(engine) else { return false }
            guard state.selectTranscriptionEngine(engine) else { return false }
        case "transcription.local-model":
            guard LocalWhisperModel.isKnown(value) else { return false }
            Config.localModelChosenByUser = true
            Config.localWhisperModel = value
        case "transcription.glossary-fixture":
            // Fixed non-sensitive fixture; arbitrary strings are intentionally
            // not accepted across the process-wide notification channel.
            guard value == "enabled" || value == "disabled" else { return false }
            Config.transcriptionGlossary = value == "enabled"
                ? "CruxwingLiveFixture, Falcon-SLA, Kubernetes, idempotent, Postgres, SLA"
                : ""
        case "transcription.assembly-diarization":
            guard let bool else { return false }; Config.assemblyAIDiarizationEnabled = bool
        case "transcription.fireflies-enhance":
            guard let bool else { return false }; Config.firefliesTranscriptEnhanceEnabled = bool
        case "connected-apps.grounding":
            guard let bool else { return false }; state.useConnectedAppsInPrompts = bool
        case "ai.model":
            guard LLMCatalog.model(id: value) != nil else { return false }
            state.selectedModelID = value
        case "privacy.analytics":
            guard let bool else { return false }; Config.funnelOptOut = !bool
        default:
            return false
        }
        settingMutationRevision &+= 1
        lastSettingMutationID = id
        lastSettingMutationAt = Date().timeIntervalSince1970
        return true
    }

    static func install(for state: AppState) {
        guard Config.isDevBuild, observers.isEmpty,
              validLiveTestNonce(expectedNonce),
              isOwnerOnlyArtifactRoot(artifactRoot) else {
            Log.general.notice("livetest: hooks disabled (missing secure run configuration)")
            return
        }
        settingsBaseline = captureSettingsBaseline(state)
        let center = DistributedNotificationCenter.default()

        observers.append(center.addObserver(
            forName: toggleRecording, object: nil, queue: .main
        ) { [weak state] note in
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                state?.toggleRecording()
                Log.general.notice("livetest: toggleRecording")
            }
        })

        observers.append(center.addObserver(
            forName: runPrompt, object: nil, queue: .main
        ) { [weak state] note in
            let id = (note.userInfo?["id"] as? String) ?? ""
            let surfaceID = note.userInfo?["surfaceID"] as? String
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                guard let state else { return }
                let prompt: QuickPrompt
                if id == modelSnapshotPromptID {
                    prompt = .custom(
                        id: modelSnapshotPromptID, icon: "checkmark",
                        title: "Model snapshot probe",
                        prompt: "Reply with one word: ready.")
                } else if let known = QuickPrompts.all.first(where: { $0.id == id }) {
                    prompt = known
                } else {
                    Log.general.error("livetest: unknown prompt id '\(id, privacy: .public)'")
                    return
                }
                lastInjectedSurfaceID = surfaceID
                lastInjectedSurfaceType = "quick"
                Log.general.notice("livetest: runPrompt \(id, privacy: .public)")
                state.runPrompt(prompt)
            }
        })

        observers.append(center.addObserver(
            forName: cancelPrompt, object: nil, queue: .main
        ) { [weak state] note in
            let exchangeID = (note.userInfo?["exchangeID"] as? String) ?? ""
            let modelID = (note.userInfo?["modelID"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                // When a model is supplied, mutate and cancel as one main-actor
                // transaction. A fast provider cannot terminalize between the
                // setting change and the exact-id cancellation, so the harness
                // never certifies a display-only snapshot by accident.
                if !modelID.isEmpty {
                    guard let state,
                          state.aiResponseID?.uuidString == exchangeID,
                          state.aiResponseStatus == .inProgress,
                          state.aiStreaming,
                          applyWhitelistedSetting(id: "ai.model", value: modelID,
                                                  to: state) else {
                        Log.general.error(
                            "livetest: cancelPrompt rejected model snapshot transaction")
                        return
                    }
                }
                guard state?.debugCancelAssistantPrompt(exchangeID: exchangeID) == true else {
                    Log.general.error("livetest: cancelPrompt rejected stale exchange")
                    return
                }
                Log.general.notice("livetest: cancelPrompt exact exchange")
            }
        })

        observers.append(center.addObserver(
            forName: dumpState, object: nil, queue: .main
        ) { [weak state] note in
            let path = (note.userInfo?["path"] as? String) ?? ""
            let requestID = (note.userInfo?["requestID"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard authorized(note), let state,
                      let destination = confinedDumpURL(path) else {
                    Log.general.error("livetest: rejected state dump")
                    return
                }
                let appliedAt = Date().timeIntervalSince1970
                let snapshot = snapshotJSON(
                    of: state, requestID: requestID, appliedAt: appliedAt)
                Task.detached(priority: .utility) {
                    do {
                        try snapshot.write(to: destination, options: .atomic)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
                        Log.general.notice(
                            "livetest: state dumped request=\(requestID, privacy: .public)")
                    } catch {
                        Log.general.error(
                            "livetest: state dump failed request=\(requestID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        })

        observers.append(center.addObserver(
            forName: ask, object: nil, queue: .main
        ) { [weak state] note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            let surfaceID = note.userInfo?["surfaceID"] as? String
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                lastInjectedSurfaceID = surfaceID
                lastInjectedSurfaceType = "freeform"
                Log.general.notice("livetest: ask (\(text.count, privacy: .public) chars)")
                state?.ask(text)
            }
        })

        observers.append(center.addObserver(
            forName: injectLine, object: nil, queue: .main
        ) { [weak state] note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            let source: TranscriptSource =
                (note.userInfo?["source"] as? String) == "mic" ? .mic : .system
            let speaker = note.userInfo?["speaker"] as? String
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                // Through the REAL ingestion path — trim, dedup, append — so
                // the driver's echo/duplicate scenarios exercise the code that
                // failed in the field, not a shortcut around it.
                state?.ingestStreamedLine(text: text, source: source, speaker: speaker)
            }
        })

        observers.append(center.addObserver(
            forName: latchQuota, object: nil, queue: .main
        ) { [weak state] note in
            let message = (note.userInfo?["message"] as? String)
                ?? "You need 2 compute credits, but only 0 remain this period — upgrade or add credits to continue."
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                Log.general.notice("livetest: latchQuota")
                state?.debugLatchQuota(message: message)
            }
        })

        observers.append(center.addObserver(
            forName: promptSurface, object: nil, queue: .main
        ) { [weak state] note in
            let type = (note.userInfo?["type"] as? String) ?? ""
            let surfaceID = (note.userInfo?["surfaceID"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard authorized(note), let state, !surfaceID.isEmpty else { return }
                switch type {
                case "poll":
                    // Never replace a genuine clarification. Ownership of the
                    // exact PendingClarification prevents a delayed clear for
                    // poll A from erasing a later poll B.
                    guard state.pendingClarification == nil,
                          activePollSurfaceID == nil else {
                        Log.general.error("livetest: poll surface collision")
                        return
                    }
                    let clarificationID = UUID()
                    state.pendingClarification = PendingClarification(
                        id: clarificationID,
                        prompt: "How should the Falcon rollout proceed?",
                        images: [],
                        questions: [ClarifyingQuestion(
                            question: "Which rollout constraint should the recommendation prioritize?",
                            header: "Priority",
                            options: [
                                .init(label: "SLA safety", detail: "Prefer the lowest operational risk."),
                                .init(label: "Delivery speed", detail: "Prefer the earliest viable launch."),
                                .init(label: "Unit economics", detail: "Prefer the lowest ongoing cost."),
                            ])])
                    activePollSurfaceID = surfaceID
                    activePollClarificationID = clarificationID
                case "mandatory":
                    guard activeMandatorySurfaceID == nil,
                          state.debugPresentMandatoryNotice(
                            id: surfaceID,
                            message: "Confirm the Falcon rollout assumptions before continuing.") else {
                        Log.general.error("livetest: mandatory surface collision")
                        return
                    }
                    activeMandatorySurfaceID = surfaceID
                case "contextual":
                    if let prompt = QuickPrompts.all.first(where: { $0.id == "whattoask" }) {
                        state.runPrompt(prompt)
                    }
                default:
                    Log.general.error("livetest: unknown prompt surface '\(type, privacy: .public)'")
                    return
                }
                lastInjectedSurfaceID = surfaceID
                lastInjectedSurfaceType = type
                Log.general.notice("livetest: promptSurface \(type, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: clearPromptSurface, object: nil, queue: .main
        ) { [weak state] note in
            let type = (note.userInfo?["type"] as? String) ?? "all"
            let surfaceID = (note.userInfo?["surfaceID"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                if type == "all" || type == "poll" {
                    if activePollSurfaceID == surfaceID,
                       state?.pendingClarification?.id == activePollClarificationID {
                        state?.pendingClarification = nil
                        activePollSurfaceID = nil
                        activePollClarificationID = nil
                    }
                }
                if type == "all" || type == "mandatory" {
                    if activeMandatorySurfaceID == surfaceID,
                       state?.debugClearMandatoryNotice(id: surfaceID) == true {
                        activeMandatorySurfaceID = nil
                    }
                }
                Log.general.notice(
                    "livetest: clearPromptSurface \(type, privacy: .public) instance=\(surfaceID, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: newCall, object: nil, queue: .main
        ) { [weak state] note in
            MainActor.assumeIsolated {
                guard authorized(note) else { return }
                Log.general.notice("livetest: newCall")
                if let id = activeMandatorySurfaceID {
                    _ = state?.debugClearMandatoryNotice(id: id)
                }
                if state?.pendingClarification?.id == activePollClarificationID {
                    state?.pendingClarification = nil
                }
                activePollSurfaceID = nil
                activePollClarificationID = nil
                activeMandatorySurfaceID = nil
                lastInjectedSurfaceID = nil
                lastInjectedSurfaceType = nil
                lastSyntheticGoalCommandID = nil
                lastSyntheticGoalAppliedAt = nil
                lastBlindSpotRefreshCommandID = nil
                lastBlindSpotRefreshRequestedAt = nil
                state?.startNewCall()
            }
        })

        observers.append(center.addObserver(
            forName: preparePromoRedemption, object: nil, queue: .main
        ) { [weak state] note in
            let commandID = validCommandID(note.userInfo?["commandID"] as? String)
            MainActor.assumeIsolated {
                guard authorized(note), let state, let commandID else { return }
                // A saved developer preview must not satisfy the entitlement
                // assertion. Suppress it process-locally before the real UI flow
                // starts, while preserving the preference for final cleanup.
                Config.setLiveTestRealEntitlementMode(true)
                state.refreshEntitlementAfterRedeem()
                promoRedemptionReceipt = .armed(
                    commandID: commandID, at: Date().timeIntervalSince1970,
                    previewActive: Config.devTierOverride != nil)
                Log.general.notice(
                    "livetest: promo redemption armed command=\(commandID, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: redeem, object: nil, queue: .main
        ) { [weak state] note in
            let code = (note.userInfo?["code"] as? String) ?? devPromoCode
            MainActor.assumeIsolated {
                guard authorized(note), let state else { return }
                Task { @MainActor in
                    do {
                        // Entitle the SIGNED-IN account when there is one.
                        //
                        // deviceRedeem mints an anonymous device-bound account
                        // and adopts its session. For an unattended suite that
                        // is right; for a developer it is actively wrong — the
                        // entitlement lands on a throwaway account while the
                        // real one, the one holding the Google/Notion/Asana
                        // connections, stays on Free and reports no credits.
                        // Redeeming against the current session keeps the plan
                        // and the connected apps on the same account.
                        if Config.wheesprSession != nil {
                            do {
                                _ = try await PaywallAPI.redeemPromo(code: code)
                                Log.general.notice("livetest: redeemed \(code, privacy: .public) on the signed-in account")
                            } catch LLMError.http(_, let status, _) where status == 401 {
                                // Integration suites may reset the local DB while
                                // Keychain still holds yesterday's now-revoked
                                // session. Only a definitive 401 may replace it;
                                // transient failures must never switch a real
                                // developer account to a device account.
                                Config.wheesprSession = nil
                                _ = try await PaywallAPI.deviceRedeem(code: code)
                                Log.general.notice("livetest: stale session replaced by device entitlement")
                            }
                        } else {
                            _ = try await PaywallAPI.deviceRedeem(code: code)
                            Log.general.notice("livetest: redeemed \(code, privacy: .public) as a device account")
                        }
                        // A developer may have a persisted plan preview. It is
                        // intentionally stronger than the purchased tier, but
                        // letting it mask this redemption would make the live
                        // suite compare a real Ultra account with a simulated
                        // Premium UI. Suppress it in memory only; the cleanup's
                        // final restore releases the scope and no crash can
                        // erase the saved preference.
                        Config.setLiveTestRealEntitlementMode(true)
                        state.refreshEntitlementAfterRedeem()
                    } catch {
                        state.lastError = "livetest redeem failed: \(error.localizedDescription)"
                        Log.general.error("livetest: redeem failed — \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        })

        observers.append(center.addObserver(
            forName: openSettings, object: nil, queue: .main
        ) { [weak state] note in
            let tabName = (note.userInfo?["tab"] as? String) ?? SettingsTab.general.rawValue
            MainActor.assumeIsolated {
                guard authorized(note), let state,
                      let tab = SettingsTab(rawValue: tabName),
                      let settingsOpener else { return }
                state.selectedSettingsTab = tab
                NSApp.activate(ignoringOtherApps: true)
                settingsOpener()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // Settings tabs are 520–560 pt wide; the main workspace is
                    // at least 1000 pt. Track the exact window instance so close
                    // can never hit the recording window.
                    let candidate = NSApp.windows.first(where: {
                        $0.isVisible && $0.frame.width >= 450 && $0.frame.width < 800
                    })
                    settingsWindowNumber = candidate?.windowNumber
                    candidate?.makeKeyAndOrderFront(nil)
                }
                Log.general.notice("livetest: openSettings tab=\(tab.rawValue, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: closeSettings, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard authorized(note), let number = settingsWindowNumber,
                      let window = NSApp.windows.first(where: {
                          $0.windowNumber == number && $0.frame.width < 800
                      }) else { return }
                window.performClose(nil)
                settingsWindowNumber = nil
                Log.general.notice("livetest: closeSettings")
            }
        })

        observers.append(center.addObserver(
            forName: applySetting, object: nil, queue: .main
        ) { [weak state] note in
            let id = (note.userInfo?["id"] as? String) ?? ""
            let value = (note.userInfo?["value"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard authorized(note), let state else { return }
                if applyWhitelistedSetting(id: id, value: value, to: state) {
                    Log.general.notice("livetest: applySetting id=\(id, privacy: .public)")
                } else {
                    Log.general.error("livetest: rejected setting id=\(id, privacy: .public)")
                }
            }
        })

        observers.append(center.addObserver(
            forName: restoreSettings, object: nil, queue: .main
        ) { [weak state] note in
            MainActor.assumeIsolated {
                guard authorized(note), let state else { return }
                let finishRun = parsedBool(note.userInfo?["finishRun"]) == true
                restoreSettingsBaseline(on: state)
                if finishRun {
                    Config.setLiveTestRealEntitlementMode(false)
                    state.refreshEntitlementAfterRedeem()
                }
                Log.general.notice(
                    "livetest: restoreSettings final=\(finishRun, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: setSyntheticCallGoal, object: nil, queue: .main
        ) { [weak state] note in
            let fixtureID = note.userInfo?["fixtureID"] as? String
            let commandID = validCommandID(note.userInfo?["commandID"] as? String)
            MainActor.assumeIsolated {
                guard authorized(note), let state, state.isRecording,
                      let goal = syntheticGoal(for: fixtureID),
                      let commandID,
                      commandID != lastSyntheticGoalCommandID else { return }
                state.callGoal = goal
                // Content-level Blind Spot evidence is armed only after this
                // nonce/root-authorized fixed-fixture command. A normal dev
                // launch and every production call remain metadata-only.
                state.beginSyntheticBlindSpotTraceCapture(goal: goal)
                lastSyntheticGoalCommandID = commandID
                lastSyntheticGoalAppliedAt = Date().timeIntervalSince1970
                Log.general.notice(
                    "livetest: synthetic goal applied fixture=\(fixtureID ?? "", privacy: .public) command=\(commandID, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: refreshBlindSpot, object: nil, queue: .main
        ) { [weak state] note in
            let fixtureID = note.userInfo?["fixtureID"] as? String
            let commandID = validCommandID(note.userInfo?["commandID"] as? String)
            MainActor.assumeIsolated {
                guard authorized(note), let state, state.isRecording,
                      let goal = syntheticGoal(for: fixtureID),
                      state.callGoal == goal,
                      CopilotTranscriptEligibility.canGenerateSuggestions(state.transcript),
                      let commandID,
                      commandID != lastBlindSpotRefreshCommandID else { return }
                state.requestBlindSpotRefresh()
                lastBlindSpotRefreshCommandID = commandID
                lastBlindSpotRefreshRequestedAt = Date().timeIntervalSince1970
                Log.general.notice(
                    "livetest: blind-spot refresh requested fixture=\(fixtureID ?? "", privacy: .public) command=\(commandID, privacy: .public)")
            }
        })

        observers.append(center.addObserver(
            forName: glossarySuggestions, object: nil, queue: .main
        ) { [weak state] note in
            let action = note.userInfo?["action"] as? String
            let commandID = validCommandID(note.userInfo?["commandID"] as? String)
            MainActor.assumeIsolated {
                guard authorized(note), let state, let action, let commandID,
                      commandID != lastGlossarySuggestionCommandID,
                      ["generate", "acceptFirst", "rejectFirst"].contains(action) else {
                    return
                }
                switch action {
                case "generate":
                    Task { @MainActor in
                        guard await state.debugLoadConnectedGlossaryFixture() else { return }
                        lastGlossarySuggestionCommandID = commandID
                        lastGlossarySuggestionAction = action
                        lastGlossarySuggestionAppliedAt = Date().timeIntervalSince1970
                    }
                case "acceptFirst":
                    guard let first = state.connectedGlossarySuggestions.first,
                          state.acceptConnectedGlossarySuggestion(id: first.id) else { return }
                    lastGlossarySuggestionCommandID = commandID
                    lastGlossarySuggestionAction = action
                    lastGlossarySuggestionAppliedAt = Date().timeIntervalSince1970
                case "rejectFirst":
                    guard let first = state.connectedGlossarySuggestions.first,
                          state.rejectConnectedGlossarySuggestion(id: first.id) else { return }
                    lastGlossarySuggestionCommandID = commandID
                    lastGlossarySuggestionAction = action
                    lastGlossarySuggestionAppliedAt = Date().timeIntervalSince1970
                default:
                    break
                }
            }
        })

        Log.general.notice("livetest: hooks installed (dev build)")
    }

    /// Everything the driver needs to assert on, as stable JSON.
    static func snapshotJSON(
        of state: AppState,
        requestID: String = "",
        appliedAt: Double = Date().timeIntervalSince1970
    ) -> Data {
        struct Snapshot: Encodable {
            /// Correlates a dump notification with the exact file the driver
            /// was waiting for. Delayed notifications can never satisfy a
            /// later checkpoint merely because they wrote non-empty JSON.
            let dumpRequestID: String
            let dumpAppliedAt: Double
            let status: String
            let isRecording: Bool
            let currentTier: String
            let tariffCopilotHours: Int
            let tariffComputeCredits: Int
            let tariffGroundedCycles: Int
            let copilotSecondsRemaining: Int
            let groundedCyclesRemaining: Int
            let callGoal: String
            let effectiveCallGoal: String
            let recordingContextSelection: String
            let detectedRecordingContext: String
            let effectiveRecordingContext: String
            let transcriptionEngine: String
            let transcriptCount: Int
            let transcriptTail: [String]
            let systemEntries: Int
            let micEntries: Int
            let aiStreaming: Bool
            let aiResponseChars: Int
            let aiResponseHead: String
            /// Full synthetic-test answers are retained in the artifact bundle
            /// so the response-quality scorer can grade more than a 400-char
            /// preview. This hook is absent from distribution builds.
            let aiResponseFull: String
            let aiResponseIsError: Bool
            let aiResponsePrompt: String
            let aiResponseID: String?
            let aiResponsePromptID: String?
            let aiResponseStartedAt: Double?
            let aiResponseCompletedAt: Double?
            let aiResponseStatus: String?
            let aiHistoryCount: Int
            let aiHistoryFull: [Exchange]
            let workflowStepsFull: [Workflow]
            /// Every terminal model-backed attempt, including blank cancelled
            /// and superseded runs that correctly do not appear in the dialog.
            let aiExchangeEvidenceFull: [Exchange]
            let suggestionsCount: Int
            let suggestionsFull: [SuggestionEvidence]
            let blindSpotAttempts: Int
            let blindSpotSuccesses: Int
            let blindSpotEmptyResults: Int
            let blindSpotFailures: Int
            let blindSpotLastSuccessAt: Double?
            let blindSpotLastFailureAt: Double?
            let blindSpotPaidProbeTick: Int
            let blindSpotLastAttemptID: String?
            let blindSpotLastBackendCorrelationID: String?
            let blindSpotLastProbeIDs: [String]
            let blindSpotLastStartedAt: Double?
            let blindSpotLastCompletedAt: Double?
            let blindSpotLastResultCount: Int?
            let blindSpotLastOutcome: String?
            let blindSpotLastGrounded: Bool
            let blindSpotLastProvider: String?
            let blindSpotLastModel: String?
            let blindSpotLastProviderLatencyMs: Int?
            let blindSpotLastChargedCredits: Int?
            let blindSpotLastCacheHit: Bool?
            let blindSpotLastProviderAttemptCount: Int?
            let blindSpotLastProviderAttempts: [BrainstormService.ExecutionTrace.ProviderAttempt]
            /// Exact fixed-fixture request and stage evidence. Populated only
            /// after an authorized synthetic-goal command; never for an
            /// arbitrary call merely because the binary is a dev build.
            let blindSpotSyntheticTrace: BlindSpotTrace?
            let blindSpotFailureMessage: String?
            let pendingClarificationCount: Int
            let lastError: String?
            let meetingTitle: String
            let copilotQuotaMessage: String?
            let liveTestMandatoryNoticeID: String?
            let liveTestMandatoryNoticeMessage: String?
            let liveTestActivePollSurfaceID: String?
            let liveTestLastSurfaceID: String?
            let liveTestLastSurfaceType: String?
            let liveTestSyntheticGoalCommandID: String?
            let liveTestSyntheticGoalAppliedAt: Double?
            let liveTestBlindSpotRefreshCommandID: String?
            let liveTestBlindSpotRefreshRequestedAt: Double?
            let liveTestPromoRedemptionReceipt: LiveTestPromoRedemptionReceipt?
            let devCallDiagnosticsEnabled: Bool
            let devCallDiagnosticsCallID: String?
            let devCallDiagnosticsSessionID: String?
            let devCallDiagnosticsRelativePath: String?
            let devCallDiagnosticsEventCount: Int
            let devCallDiagnosticsDroppedEventCount: Int
            let devCallDiagnosticsBytesWritten: Int
            let provisionalCount: Int
            let dialogChars: Int
            let microphonePermissionGranted: Bool
            let screenRecordingPermissionGranted: Bool
            let systemCaptureBufferCount: Int
            let systemCaptureRMSSampleCount: Int
            let systemCaptureRMSSum: Double
            let systemCaptureMaxRMS: Double
            let systemCaptureNonSilentSamples: Int
            let systemCaptureLastBufferAt: Double?
            let micCaptureBufferCount: Int
            let micCaptureRMSSampleCount: Int
            let micCaptureRMSSum: Double
            let micCaptureMaxRMS: Double
            let micCaptureNonSilentSamples: Int
            let micCaptureLastBufferAt: Double?
            let micVoiceProcessingActive: Bool
            let outputRoute: String
            let outputLevel: String
            // Settings semantics: configured values may change during a call;
            // active transcription values must remain the immutable start-time
            // snapshot, while live watch tasks reconcile immediately.
            let selectedSettingsTab: String
            let settingsWindowVisible: Bool
            let settingsWindowCount: Int
            let settingsWindowNumber: Int?
            let settingMutationRevision: Int
            let lastSettingMutationID: String?
            let lastSettingMutationAt: Double?
            let configuredAppearance: String
            let configuredCallDetection: Bool
            let configuredIgnoreMedia: Bool
            let configuredMeetingReminders: Bool
            let configuredReminderMinutes: Int
            let configuredRoleID: String?
            let availableRoleIDs: [String]
            let configuredTranscriptionEngine: String
            let availableTranscriptionEngines: [String]
            let activeTranscriptionEngine: String?
            let deepgramHandoffReadinessTimeoutSeconds: Double
            let configuredTranscriptionLanguage: String
            let activeTranscriptionLanguage: String?
            let configuredLocalModel: String
            let activeLocalModel: String?
            let configuredMicrophoneNoiseSuppression: Bool
            let activeMicrophoneNoiseSuppression: Bool?
            let configuredAdaptiveLocal: Bool
            let configuredGlossaryTermCount: Int
            let activeGlossaryTermCount: Int?
            let activeGlossaryMatchesConfigured: Bool?
            let connectedGlossarySuggestionStatus: String
            let connectedGlossarySuggestionTerms: [String]
            let connectedGlossarySuggestionSourceCount: Int?
            let connectedGlossarySuggestionGroundingChars: Int?
            let connectedGlossarySuggestionPromptChars: Int?
            let connectedGlossarySuggestionInputTokens: Int?
            let connectedGlossarySuggestionTranscriptCharsSent: Int?
            let connectedGlossarySuggestionModelID: String?
            let connectedGlossarySuggestionEstimatedCredits: Int?
            let connectedGlossarySuggestionRanking: String?
            let connectedGlossarySuggestionCached: Bool?
            let connectedGlossarySuggestionAcceptedCount: Int
            let connectedGlossarySuggestionRejectedCount: Int
            let liveTestGlossarySuggestionCommandID: String?
            let liveTestGlossarySuggestionAction: String?
            let liveTestGlossarySuggestionAppliedAt: Double?
            let configuredAssemblyDiarization: Bool
            let activeAssemblyDiarization: Bool?
            let pendingEngineChange: String?
            /// Geometric evidence from the real AppKit transcript viewport.
            /// This is independent of SwiftUI's private `@State` and proves the
            /// rendered tail remained visible through interim/final growth.
            let transcriptViewportAtLatest: Bool?
            let transcriptViewportScrollerValue: Double?
            let transcriptViewportRemainingPoints: Double?
            let transcriptRenderedCharacters: Int?
            let configuredFirefliesEnhance: Bool
            let connectedAppsGroundingEnabled: Bool
            let configuredAIModelID: String
            let availableAIModelIDs: [String]
            let activeAnswerModelID: String?
            let configuredShareAnalytics: Bool
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
            let copilotAccruedUnionSeconds: Int
            // Persistence: launch starts a FRESH session; the previous call
            // must be findable in the saved list, not in the live transcript.
            let savedSessionCount: Int
            let latestSessionTail: [String]
            /// Whole transcript with per-line attribution and timing — the
            /// scorer needs every line (WER over a 5-line tail measures
            /// nothing) plus the speaker label to score diarization.
            let transcriptFull: [Line]
            /// What the call detector would attribute a call to right now —
            /// checked against a real Zoom conference by the edge suite.
            let commAppAttribution: String?
            // Window focus — for the connectors-window-closing regression:
            // the front/key window must not change when the app is reopened.
            let keyWindowTitle: String
            let frontWindowTitle: String
            let windowTitles: [String]
            let mainWindowNumber: Int?
            let keyWindowNumber: Int?
            let frontWindowNumber: Int?
            let keyWindowWidth: Double?
            let keyWindowHeight: Double?
            let backingScaleFactor: Double?
            let accessibilityReduceMotion: Bool
            let accessibilityIncreaseContrast: Bool
            let accessibilityDifferentiateWithoutColor: Bool
            let accessibilityVoiceOverEnabled: Bool
        }

        struct Line: Encodable {
            let text: String
            let source: String
            let speaker: String
            let transcriptionEngine: String?
            let at: Double
        }
        struct Exchange: Encodable {
            let id: String
            let prompt: String
            let answer: String
            let at: Double
            let promptedAt: Double?
            let promptID: String?
            let completedAt: Double?
            let status: String
            let current: Bool
        }
        struct Workflow: Encodable {
            let id: Int
            let label: String
            let detail: String?
            let appID: String?
            let appName: String?
            let appConnectionKind: String?
            let tool: String?
            let status: String
            let done: Bool
        }
        struct SuggestionEvidence: Encodable {
            let id: String
            let title: String
            let detail: String
            let kind: String
            let evidence: String?
            let claim: String?
            let cheapTest: String?
            let costOfMissing: String?
        }
        struct ConnectorTrace: Encodable {
            let probeID: String
            let startedAt: Double
            let completedAt: Double
            let latencyMs: Int
            let outcome: String
            let resultCount: Int
            let sourceIDs: [String]
        }
        struct BlindSpotTrace: Encodable {
            let generation: Int
            let sessionID: String
            let preparedAt: Double
            let goal: String
            let transcript: String
            let priorTitles: [String]
            let guidance: String?
            let localContext: String?
            let context: String?
            let probe: String
            let theme: String
            let grounded: Bool
            let requestPayload: String?
            let tokenLookupStartedAt: Double?
            let tokenLookupCompletedAt: Double?
            let connectorStartedAt: Double?
            let connectorCompletedAt: Double?
            let connectorWorkflows: [ConnectorTrace]
            let groundedCycleConsumedAt: Double?
            let connectorPackStartedAt: Double?
            let connectorPackCompletedAt: Double?
            let providerStartedAt: Double?
            let providerCompletedAt: Double?
        }
        let visible = NSApp.windows.filter { $0.isVisible }
        let keyWindow = NSApp.keyWindow
        let frontWindow = NSApp.orderedWindows.first(where: { $0.isVisible })
        let mainWindow = visible.first(where: { $0.frame.width >= 900 })
        func firstTranscriptTextView(in view: NSView?) -> TranscriptTextView? {
            guard let view else { return nil }
            if let transcript = view as? TranscriptTextView { return transcript }
            for child in view.subviews {
                if let transcript = firstTranscriptTextView(in: child) { return transcript }
            }
            return nil
        }
        let transcriptTextView = firstTranscriptTextView(in: mainWindow?.contentView)
        let transcriptScrollView = transcriptTextView?.enclosingScrollView
        if let transcriptScrollView {
            transcriptScrollView.reflectScrolledClipView(transcriptScrollView.contentView)
        }
        let transcriptViewportDistance: CGFloat? = transcriptScrollView.map { scroll in
            LiveScrollPolicy.scrollableDistance(
                viewportHeight: scroll.contentView.bounds.height,
                knobProportion: CGFloat(scroll.verticalScroller?.knobProportion ?? 1),
                fallbackDocumentHeight: scroll.documentView?.bounds.height ?? 0)
        }
        let transcriptScrollerValue = transcriptScrollView.map {
            CGFloat($0.verticalScroller?.floatValue ?? 1)
        }
        let transcriptRemaining: CGFloat? = {
            guard let distance = transcriptViewportDistance,
                  let value = transcriptScrollerValue else { return nil }
            return (1 - min(1, max(0, value))) * max(0, distance)
        }()
        let audio = state.liveTestAudioDiagnostics()
        let transcription = state.liveTranscriptionConfiguration()
        let watches = state.liveWatchActivity()
        let blindSpots = state.blindSpotActivity()
        let devDiagnostics = DevCallDiagnostics.shared.snapshot()
        let blindSpotSyntheticTrace = state.syntheticBlindSpotTrace().map { trace in
            BlindSpotTrace(
                generation: trace.generation,
                sessionID: trace.sessionID,
                preparedAt: trace.preparedAt,
                goal: trace.goal,
                transcript: trace.transcript,
                priorTitles: trace.priorTitles,
                guidance: trace.guidance,
                localContext: trace.localContext,
                context: trace.context,
                probe: trace.probe,
                theme: trace.theme,
                grounded: trace.grounded,
                requestPayload: trace.requestPayload,
                tokenLookupStartedAt: trace.tokenLookupStartedAt,
                tokenLookupCompletedAt: trace.tokenLookupCompletedAt,
                connectorStartedAt: trace.connectorStartedAt,
                connectorCompletedAt: trace.connectorCompletedAt,
                connectorWorkflows: trace.connectorWorkflows.map {
                    ConnectorTrace(
                        probeID: $0.probeID,
                        startedAt: $0.startedAt,
                        completedAt: $0.completedAt,
                        latencyMs: $0.latencyMs,
                        outcome: $0.outcome,
                        resultCount: $0.resultCount,
                        sourceIDs: $0.sourceIDs)
                },
                groundedCycleConsumedAt: trace.groundedCycleConsumedAt,
                connectorPackStartedAt: trace.connectorPackStartedAt,
                connectorPackCompletedAt: trace.connectorPackCompletedAt,
                providerStartedAt: trace.providerStartedAt,
                providerCompletedAt: trace.providerCompletedAt)
        }
        let settingsWindows = visible.filter {
            if let number = settingsWindowNumber { return $0.windowNumber == number }
            return $0.frame.width >= 450 && $0.frame.width < 800
        }
        let tail = state.transcript.suffix(5).map { "[\($0.source.rawValue)] \($0.text)" }
        let exchangeSnapshot: (AIExchange, Bool) -> Exchange = {
            Exchange(id: $0.id.uuidString,
                     prompt: $0.prompt, answer: $0.answer,
                     at: $0.at.timeIntervalSince1970,
                     promptedAt: $0.promptedAt?.timeIntervalSince1970,
                     promptID: $0.promptID,
                     completedAt: $0.completedAt?.timeIntervalSince1970,
                     status: $0.status.rawValue,
                     current: $1)
        }
        let exchanges = state.aiHistory.map { exchangeSnapshot($0, false) }
        let evidence = state.aiExchangeEvidence.map { exchangeSnapshot($0, false) }
        let snapshot = Snapshot(
            dumpRequestID: requestID,
            dumpAppliedAt: appliedAt,
            status: String(describing: state.status),
            isRecording: state.isRecording,
            currentTier: state.currentTier.rawValue,
            tariffCopilotHours: state.tariffAllowance.copilotHours,
            tariffComputeCredits: state.tariffAllowance.computeCredits,
            tariffGroundedCycles: state.tariffAllowance.groundedCycles,
            copilotSecondsRemaining: state.copilotSecondsRemaining,
            groundedCyclesRemaining: state.groundedCyclesRemaining,
            callGoal: state.callGoal,
            effectiveCallGoal: state.effectiveCallGoal,
            recordingContextSelection: state.recordingContextSelection.mode.rawValue,
            detectedRecordingContext: state.detectedRecordingContext.rawValue,
            effectiveRecordingContext: state.effectiveRecordingContextLabel,
            transcriptionEngine: Config.transcriptionEngineValue.rawValue,
            transcriptCount: state.transcript.count,
            transcriptTail: Array(tail),
            systemEntries: state.transcript.filter { $0.source == .system }.count,
            micEntries: state.transcript.filter { $0.source == .mic }.count,
            aiStreaming: state.aiStreaming,
            aiResponseChars: state.aiResponse.count,
            aiResponseHead: String(state.aiResponse.prefix(400)),
            aiResponseFull: state.aiResponse,
            aiResponseIsError: state.aiResponse.hasPrefix("Error:"),
            aiResponsePrompt: state.aiResponsePrompt,
            aiResponseID: state.aiResponseID?.uuidString,
            aiResponsePromptID: state.aiResponsePromptID,
            aiResponseStartedAt: state.aiResponseStartedAt?.timeIntervalSince1970,
            aiResponseCompletedAt: state.aiResponseCompletedAt?.timeIntervalSince1970,
            aiResponseStatus: state.aiResponseStatus?.rawValue,
            aiHistoryCount: state.aiHistory.count,
            aiHistoryFull: exchanges,
            workflowStepsFull: state.workflowSteps.map {
                Workflow(
                    id: $0.id,
                    label: $0.label,
                    detail: $0.detail,
                    appID: $0.app?.id,
                    appName: $0.app?.name,
                    appConnectionKind: $0.app?.kind.rawValue,
                    tool: $0.tool,
                    status: $0.status.rawValue,
                    done: $0.done)
            },
            aiExchangeEvidenceFull: evidence,
            suggestionsCount: state.suggestions.count,
            suggestionsFull: state.suggestions.map {
                SuggestionEvidence(
                    id: $0.id.uuidString,
                    title: $0.title,
                    detail: $0.detail,
                    kind: $0.kind.rawValue,
                    evidence: $0.evidence,
                    claim: $0.claim,
                    cheapTest: $0.cheapTest,
                    costOfMissing: $0.costOfMissing)
            },
            blindSpotAttempts: blindSpots.attempts,
            blindSpotSuccesses: blindSpots.successes,
            blindSpotEmptyResults: blindSpots.emptyResults,
            blindSpotFailures: blindSpots.failures,
            blindSpotLastSuccessAt: blindSpots.lastSuccessAt,
            blindSpotLastFailureAt: blindSpots.lastFailureAt,
            blindSpotPaidProbeTick: blindSpots.paidProbeTick,
            blindSpotLastAttemptID: blindSpots.lastAttemptID,
            blindSpotLastBackendCorrelationID: blindSpots.lastBackendCorrelationID,
            blindSpotLastProbeIDs: blindSpots.lastProbeIDs,
            blindSpotLastStartedAt: blindSpots.lastStartedAt,
            blindSpotLastCompletedAt: blindSpots.lastCompletedAt,
            blindSpotLastResultCount: blindSpots.lastResultCount,
            blindSpotLastOutcome: blindSpots.lastOutcome,
            blindSpotLastGrounded: blindSpots.lastGrounded,
            blindSpotLastProvider: blindSpots.lastProvider,
            blindSpotLastModel: blindSpots.lastModel,
            blindSpotLastProviderLatencyMs: blindSpots.lastProviderLatencyMs,
            blindSpotLastChargedCredits: blindSpots.lastChargedCredits,
            blindSpotLastCacheHit: blindSpots.lastCacheHit,
            blindSpotLastProviderAttemptCount: blindSpots.lastProviderAttemptCount,
            blindSpotLastProviderAttempts: blindSpots.lastProviderAttempts,
            blindSpotSyntheticTrace: blindSpotSyntheticTrace,
            blindSpotFailureMessage: state.blindSpotFailureMessage,
            pendingClarificationCount: state.pendingClarification?.questions.count ?? 0,
            lastError: state.lastError,
            meetingTitle: state.meetingTitle,
            copilotQuotaMessage: state.copilotQuotaMessage,
            liveTestMandatoryNoticeID: state.liveTestMandatoryNotice?.id,
            liveTestMandatoryNoticeMessage: state.liveTestMandatoryNotice?.message,
            liveTestActivePollSurfaceID: activePollSurfaceID,
            liveTestLastSurfaceID: lastInjectedSurfaceID,
            liveTestLastSurfaceType: lastInjectedSurfaceType,
            liveTestSyntheticGoalCommandID: lastSyntheticGoalCommandID,
            liveTestSyntheticGoalAppliedAt: lastSyntheticGoalAppliedAt,
            liveTestBlindSpotRefreshCommandID: lastBlindSpotRefreshCommandID,
            liveTestBlindSpotRefreshRequestedAt: lastBlindSpotRefreshRequestedAt,
            liveTestPromoRedemptionReceipt: promoRedemptionReceipt,
            devCallDiagnosticsEnabled: devDiagnostics.enabled,
            devCallDiagnosticsCallID: devDiagnostics.callID,
            devCallDiagnosticsSessionID: devDiagnostics.sessionID,
            devCallDiagnosticsRelativePath: devDiagnostics.relativePath,
            devCallDiagnosticsEventCount: devDiagnostics.eventCount,
            devCallDiagnosticsDroppedEventCount: devDiagnostics.droppedEventCount,
            devCallDiagnosticsBytesWritten: devDiagnostics.bytesWritten,
            provisionalCount: state.provisionalLines.count,
            dialogChars: state.dialogClipboardText.count,
            microphonePermissionGranted: state.micGranted,
            screenRecordingPermissionGranted: state.screenRecordingGranted,
            systemCaptureBufferCount: audio.system.bufferCount,
            systemCaptureRMSSampleCount: audio.system.rmsSampleCount,
            systemCaptureRMSSum: audio.system.rmsSum,
            systemCaptureMaxRMS: audio.system.maxRMS,
            systemCaptureNonSilentSamples: audio.system.nonSilentSampleCount,
            systemCaptureLastBufferAt: audio.system.lastBufferAt,
            micCaptureBufferCount: audio.mic.bufferCount,
            micCaptureRMSSampleCount: audio.mic.rmsSampleCount,
            micCaptureRMSSum: audio.mic.rmsSum,
            micCaptureMaxRMS: audio.mic.maxRMS,
            micCaptureNonSilentSamples: audio.mic.nonSilentSampleCount,
            micCaptureLastBufferAt: audio.mic.lastBufferAt,
            micVoiceProcessingActive: audio.voiceProcessingActive,
            outputRoute: audio.outputRoute,
            outputLevel: audio.outputLevel,
            selectedSettingsTab: state.selectedSettingsTab.rawValue,
            settingsWindowVisible: !settingsWindows.isEmpty,
            settingsWindowCount: settingsWindows.count,
            settingsWindowNumber: settingsWindows.first?.windowNumber,
            settingMutationRevision: settingMutationRevision,
            lastSettingMutationID: lastSettingMutationID,
            lastSettingMutationAt: lastSettingMutationAt,
            configuredAppearance: Config.appAppearance.rawValue,
            configuredCallDetection: Config.callDetectionEnabled,
            configuredIgnoreMedia: Config.ignoreMediaApps,
            configuredMeetingReminders: Config.meetingRemindersEnabled,
            configuredReminderMinutes: Config.meetingReminderMinutes,
            configuredRoleID: state.userRoleID,
            availableRoleIDs: RoleSkillMatrix.positions.map(\.id),
            configuredTranscriptionEngine: transcription.configured.engine.rawValue,
            availableTranscriptionEngines: TranscriptionEngine.selectableCases
                .filter(Config.engineAvailable)
                .map(\.rawValue),
            activeTranscriptionEngine: transcription.active?.engine.rawValue,
            deepgramHandoffReadinessTimeoutSeconds:
                Double(DeepgramHandoffState.readinessTimeoutNanoseconds) / 1_000_000_000,
            configuredTranscriptionLanguage: transcription.configured.language,
            activeTranscriptionLanguage: transcription.active?.language,
            configuredLocalModel: transcription.configured.localModel,
            activeLocalModel: transcription.active?.localModel,
            configuredMicrophoneNoiseSuppression:
                transcription.configured.microphoneNoiseSuppression,
            activeMicrophoneNoiseSuppression:
                transcription.active?.microphoneNoiseSuppression,
            configuredAdaptiveLocal: Config.adaptiveLocalWhisperEnabled,
            configuredGlossaryTermCount: transcription.configured.glossaryTerms.count,
            activeGlossaryTermCount: transcription.active?.glossaryTerms.count,
            activeGlossaryMatchesConfigured: transcription.active.map {
                $0.glossaryTerms == transcription.configured.glossaryTerms
            },
            connectedGlossarySuggestionStatus:
                state.connectedGlossarySuggestionStatus.snapshotValue,
            connectedGlossarySuggestionTerms:
                state.connectedGlossarySuggestions.map(\.term),
            connectedGlossarySuggestionSourceCount:
                state.connectedGlossarySuggestionMetrics?.sourceCount,
            connectedGlossarySuggestionGroundingChars:
                state.connectedGlossarySuggestionMetrics?.groundingChars,
            connectedGlossarySuggestionPromptChars:
                state.connectedGlossarySuggestionMetrics?.promptChars,
            connectedGlossarySuggestionInputTokens:
                state.connectedGlossarySuggestionMetrics?.estimatedInputTokens,
            connectedGlossarySuggestionTranscriptCharsSent:
                state.connectedGlossarySuggestionMetrics?.transcriptCharsSent,
            connectedGlossarySuggestionModelID:
                state.connectedGlossarySuggestionMetrics?.modelID,
            connectedGlossarySuggestionEstimatedCredits:
                state.connectedGlossarySuggestionMetrics?.estimatedComputeCredits,
            connectedGlossarySuggestionRanking:
                state.connectedGlossarySuggestionMetrics?.ranking.rawValue,
            connectedGlossarySuggestionCached:
                state.connectedGlossarySuggestionMetrics?.cached,
            connectedGlossarySuggestionAcceptedCount: state.connectedGlossaryAcceptedCount,
            connectedGlossarySuggestionRejectedCount: state.connectedGlossaryRejectedCount,
            liveTestGlossarySuggestionCommandID: lastGlossarySuggestionCommandID,
            liveTestGlossarySuggestionAction: lastGlossarySuggestionAction,
            liveTestGlossarySuggestionAppliedAt: lastGlossarySuggestionAppliedAt,
            configuredAssemblyDiarization: transcription.configured.assemblyDiarization,
            activeAssemblyDiarization: transcription.active?.assemblyDiarization,
            pendingEngineChange: transcription.pendingEngine?.rawValue,
            transcriptViewportAtLatest: transcriptRemaining.map { _ in
                LiveScrollPolicy.isNearBottom(
                    scrollerValue: transcriptScrollerValue ?? 1,
                    scrollableDistance: transcriptViewportDistance ?? 0)
            },
            transcriptViewportScrollerValue: transcriptScrollerValue.map(Double.init),
            transcriptViewportRemainingPoints: transcriptRemaining.map(Double.init),
            transcriptRenderedCharacters: transcriptTextView?.string.count,
            configuredFirefliesEnhance: Config.firefliesTranscriptEnhanceEnabled,
            connectedAppsGroundingEnabled: state.useConnectedAppsInPrompts,
            configuredAIModelID: state.selectedModelID,
            availableAIModelIDs: LLMCatalog.available(for: state.currentTier).map(\.id),
            activeAnswerModelID: state.aiResponseModelID,
            configuredShareAnalytics: !Config.funnelOptOut,
            brainstormConfigured: watches.brainstormConfigured,
            brainstormTaskActive: watches.brainstormTaskActive,
            agendaConfigured: watches.agendaConfigured,
            agendaTaskActive: watches.agendaTaskActive,
            factCheckConfigured: watches.factCheckConfigured,
            factCheckTaskActive: watches.factCheckTaskActive,
            rhetoricConfigured: watches.rhetoricConfigured,
            rhetoricTaskActive: watches.rhetoricTaskActive,
            facilitationConfigured: watches.facilitationConfigured,
            facilitationTaskActive: watches.facilitationTaskActive,
            copilotAccruedUnionSeconds: watches.accruedUnionSeconds,
            savedSessionCount: state.savedSessions.count,
            // A relaunch assertion needs the synthetic call that this run just
            // persisted, never an unrelated call from the user's history.
            latestSessionTail: runStartedAt.flatMap { started in
                state.savedSessions.first(where: {
                    $0.startedAt.timeIntervalSince1970 >= started - 1
                }).map { $0.entries.suffix(5).map(\.text) }
            } ?? [],
            transcriptFull: state.transcript.map {
                Line(text: $0.text,
                     source: $0.source.rawValue,
                     speaker: $0.speaker ?? "",
                     transcriptionEngine: $0.transcriptionEngine?.rawValue,
                     at: $0.timestamp.timeIntervalSince1970)
            },
            commAppAttribution: CallDetector.currentCommAppLabel(),
            keyWindowTitle: keyWindow?.title ?? "",
            frontWindowTitle: frontWindow?.title ?? "",
            windowTitles: visible.map { $0.title },
            mainWindowNumber: mainWindow?.windowNumber,
            keyWindowNumber: keyWindow?.windowNumber,
            frontWindowNumber: frontWindow?.windowNumber,
            keyWindowWidth: keyWindow.map { Double($0.frame.width) },
            keyWindowHeight: keyWindow.map { Double($0.frame.height) },
            backingScaleFactor: keyWindow.map { Double($0.backingScaleFactor) },
            accessibilityReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            accessibilityIncreaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            accessibilityDifferentiateWithoutColor: NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor,
            accessibilityVoiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }
}
