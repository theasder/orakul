import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
@Suite("Settings accessibility inventory", .serialized)
struct SettingsAccessibilityInventoryTests {
    private func inspected(tab: SettingsTab) throws -> InspectableView<ViewType.ClassifiedView> {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.selectedSettingsTab = tab
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        return try SettingsView()
            .environmentObject(state)
            .environmentObject(manager)
            .inspect()
    }

    private func require(_ ids: [String], in view: InspectableView<ViewType.ClassifiedView>) {
        for id in ids {
            #expect(throws: Never.self, "missing Settings accessibility id: \(id)") {
                _ = try view.find(viewWithAccessibilityIdentifier: id)
            }
        }
    }

    @Test("every always-visible General control has a stable automation identity")
    func generalControls() throws {
        require([
            "settings.general.theme", "settings.general.role",
            "settings.general.call-detection", "settings.general.ignore-media",
            "settings.general.reminders", "settings.general.reminder-lead-time",
        ], in: try inspected(tab: .general))
    }

    @Test("the conditional custom-role editor has a stable automation identity")
    func customRoleControl() throws {
        let savedRole = Config.userRoleID
        defer { Config.userRoleID = savedRole }
        let state = AppState(credentialStore: InMemoryKeychain())
        state.selectedSettingsTab = .general
        state.userRoleID = RoleSkillMatrix.customRoleID
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        let rendered = try SettingsView()
            .environmentObject(state)
            .environmentObject(manager)
            .inspect()
        require(["settings.general.custom-role"], in: rendered)
    }

    @Test("every always-visible Transcription control has a stable automation identity")
    func transcriptionControls() throws {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        // Local-only model controls deliberately disappear when Instant is
        // selected; inspect the Local branch explicitly here.
        Config.transcriptionEngineValue = .local
        var ids = [
            "settings.transcription.language", "settings.transcription.aec",
            "settings.transcription.fireflies-enhance", "settings.transcription.local-model",
            "settings.transcription.adaptive", "settings.transcription.glossary",
            "settings.transcription.glossary-suggestions.enabled",
            "settings.transcription.glossary-suggestions.generate",
        ]
        ids += TranscriptionEngine.selectableCases.map {
            "settings.transcription.engine.\($0.rawValue)"
        }
        require(ids, in: try inspected(tab: .transcription))
    }

    @Test("AI model and every live co-pilot switch have stable identities")
    func aiControls() throws {
        require([
            "settings.ai.provider", "settings.ai.manage-plan",
            "settings.ai.brainstorm", "settings.ai.agenda", "settings.ai.fact-check",
            "settings.ai.rhetoric", "settings.ai.facilitation",
        ], in: try inspected(tab: .ai))

        let savedProvider = Config.selectedProvider
        let savedVersion = Config.selectedVersion
        defer {
            Config.selectedProvider = savedProvider
            Config.selectedVersion = savedVersion
        }
        Config.selectedProvider = LLMProvider.openAI.rawValue
        require(["settings.ai.model-version"], in: try inspected(tab: .ai))
    }

    @Test("Connected Apps exposes searchable provider and granular Google controls")
    func connectedControls() throws {
        var ids = [
            "settings.connected.search", "settings.connected.add-custom",
            "settings.connected.google.connect",
        ]
        ids += GoogleService.requestable.map {
            "settings.connected.google.service.\($0.rawValue)"
        }
        ids += MCPCatalog.builtIn.map { "settings.connected.provider.\($0.id)" }
        require(ids, in: try inspected(tab: .connectedApps))
    }

    @Test("a withdrawn Google service is not offered as a toggle")
    func withdrawnServicesAreNotOffered() throws {
        // Drive (drive.readonly) is withdrawn while the restricted-scope
        // submission is deferred. A toggle for it would ask for consent the
        // client no longer requests — the user would tick it and get nothing.
        let view = try inspected(tab: .connectedApps)
        let withdrawn = Set(GoogleService.allCases).subtracting(GoogleService.requestable)
        for service in withdrawn {
            #expect(throws: (any Error).self, "withdrawn service still has a toggle: \(service.rawValue)") {
                _ = try view.find(viewWithAccessibilityIdentifier:
                    "settings.connected.google.service.\(service.rawValue)")
            }
        }
    }

    @Test("Account and Privacy exposes the reversible analytics control")
    func privacyControls() throws {
        require(["settings.privacy.analytics"],
                in: try inspected(tab: .accountPrivacy))
    }

    @Test("live co-pilot Settings survive all 16 accessibility overlaps")
    func liveControlsSurviveAccessibilityProduct() throws {
        var fingerprints: Set<String> = []
        for largeText in [false, true] {
            for rightToLeft in [false, true] {
                for boldText in [false, true] {
                    for dark in [false, true] {
                        let state = AppState(credentialStore: InMemoryKeychain())
                        state.selectedSettingsTab = .ai
                        let manager = MCPConnectionManager(
                            tokenStore: InMemoryKeychain(),
                            notificationCenter: NotificationCenter())
                        let view = SettingsView()
                            .environmentObject(state)
                            .environmentObject(manager)
                            .environment(\.dynamicTypeSize,
                                         largeText ? .accessibility5 : .medium)
                            .environment(\.layoutDirection,
                                         rightToLeft ? .rightToLeft : .leftToRight)
                            .environment(\.legibilityWeight, boldText ? .bold : nil)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let rendered = try view.inspect()
                        require([
                            "settings.ai.brainstorm", "settings.ai.agenda",
                            "settings.ai.fact-check", "settings.ai.rhetoric",
                            "settings.ai.facilitation",
                        ], in: rendered)
                        fingerprints.insert(
                            "large=\(largeText) rtl=\(rightToLeft) bold=\(boldText) dark=\(dark)")
                    }
                }
            }
        }
        #expect(fingerprints.count == 16)
    }
}
