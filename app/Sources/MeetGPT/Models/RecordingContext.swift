import AppKit
import Foundation
import ScreenCaptureKit

/// What the captured audio represents. A transcript can come from a meeting,
/// but it can just as legitimately be a tutorial, a YouTube video, or a
/// lecture. Keeping this explicit prevents meeting-only prompts from inventing
/// participants, decisions, and action items around ordinary playback.
enum RecordingContextKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case meeting
    case tutorial
    case lecture
    case interview
    case podcast
    case presentation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meeting: "Meeting"
        case .tutorial: "Tutorial"
        case .lecture: "Lecture"
        case .interview: "Interview"
        case .podcast: "Podcast"
        case .presentation: "Presentation / demo"
        }
    }

    /// То же самое, но для экрана.
    ///
    /// `label` выше остаётся английским нарочно: он подставляется в промпт
    /// («Recording type: \(kind.label)»), а промпты здесь модельные и
    /// английские. Из-за этого совмещения тип записи оставался английским на
    /// плашке записи, и заметить это удалось только одним способом — отрисовать
    /// экран в тесте и прочитать, что на нём написано.
    var displayLabel: String {
        switch self {
        case .meeting: "Звонок"
        case .tutorial: "Разбор"
        case .lecture: "Лекция"
        case .interview: "Интервью"
        case .podcast: "Подкаст"
        case .presentation: "Презентация или демо"
        }
    }

    var symbol: String {
        switch self {
        case .meeting: "person.2.wave.2"
        case .tutorial: "hammer"
        case .lecture: "graduationcap"
        case .interview: "person.2"
        case .podcast: "mic"
        case .presentation: "rectangle.on.rectangle"
        }
    }

    /// Compact model-facing orientation. This is deliberately behavioral,
    /// not a long taxonomy dump, so selecting a type saves tokens while
    /// preventing the most damaging category mistakes.
    var promptGuidance: String {
        switch self {
        case .meeting:
            "Treat the recording as a meeting: distinguish participants and ground decisions, owners, and follow-ups in what was actually said."
        case .tutorial:
            "Treat the recording as a tutorial: extract prerequisites, ordered implementation steps, commands, trade-offs, and pitfalls; connect them to the user's supplied project context. Do not invent meeting participants or decisions."
        case .lecture:
            "Treat the recording as a lecture: organize concepts, definitions, evidence, examples, and open questions. Do not invent meeting decisions or action owners."
        case .interview:
            "Treat the recording as an interview: distinguish questions from answers and attribute claims only when the transcript supports it."
        case .podcast:
            "Treat the recording as a podcast: distinguish hosts and guests when supported, summarize arguments and examples, and do not invent meeting action items."
        case .presentation:
            "Treat the recording as a presentation or demo: capture the proposed approach, demonstrated steps, evidence, constraints, and audience questions without inventing commitments."
        }
    }
}

/// Per-call user choice. `.automatic` is the default; a preset or custom label
/// is an explicit override and must win even if window-title inference changes
/// while recording.
struct RecordingContextSelection: Codable, Equatable, Sendable {
    enum Mode: String, CaseIterable, Codable, Sendable {
        case automatic
        case meeting
        case tutorial
        /// Retired. Kept so sessions saved before it was removed still decode —
        /// dropping the case would fail the whole session, not just this field.
        /// It is not offered any more and resolves to `.lecture`; see
        /// `RecordingContextKind`.
        case video
        case lecture
        case interview
        case podcast
        case presentation
        case custom

        var preset: RecordingContextKind? {
            if self == .video { return .lecture }
            return RecordingContextKind(rawValue: rawValue)
        }
    }

    static let maximumCustomLabelLength = 80
    static let automatic = RecordingContextSelection(mode: .automatic)

    var mode: Mode
    var customLabel: String?

    init(mode: Mode, customLabel: String? = nil) {
        self.mode = mode
        self.customLabel = Self.sanitizeCustomLabel(customLabel)
        if mode != .custom { self.customLabel = nil }
    }

    var isAutomatic: Bool { mode == .automatic }

    func resolvedKind(detected: RecordingContextKind) -> RecordingContextKind? {
        if mode == .automatic { return detected }
        return mode.preset
    }

    func resolvedLabel(detected: RecordingContextKind) -> String {
        if let kind = resolvedKind(detected: detected) { return kind.label }
        return Self.sanitizeCustomLabel(customLabel) ?? "Other recording"
    }

    /// Подпись для экрана. `resolvedLabel` остаётся английской: она уходит в
    /// промпт.
    func resolvedDisplayLabel(detected: RecordingContextKind) -> String {
        if let kind = resolvedKind(detected: detected) { return kind.displayLabel }
        return Self.sanitizeCustomLabel(customLabel) ?? "Другая запись"
    }

    func resolvedSymbol(detected: RecordingContextKind) -> String {
        resolvedKind(detected: detected)?.symbol ?? "tag"
    }

    func promptGuidance(detected: RecordingContextKind) -> String {
        if let kind = resolvedKind(detected: detected) {
            return "Recording type: \(kind.label). \(kind.promptGuidance)"
        }
        let label = resolvedLabel(detected: detected)
        return "Recording type (set by the user): \(label). Interpret the transcript according to that type; do not assume it is a meeting unless the transcript says so."
    }

    static func sanitizeCustomLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumCustomLabelLength))
    }
}

/// Pure, deterministic inference used by both the live app and tests. Media
/// host markers take precedence over meeting words: a YouTube tutorial titled
/// "Zoom meeting setup" is still a tutorial, not a live Zoom call.
enum RecordingContextDetector {
    /// Best-effort live suggestion from visible window metadata. The manual
    /// selection remains authoritative; this function never changes it. A
    /// failure (including a permission race) preserves the meeting-compatible
    /// default instead of blocking recording startup.
    @MainActor
    static func inferVisibleContext(additionalTitles: [String] = []) async
        -> RecordingContextKind {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else {
            return infer(windowTitles: additionalTitles)
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let visible = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.bundleIdentifier != ownBundleID
        }
        let titles = additionalTitles + visible.compactMap(\.title)
        let bundleIDs = visible.compactMap { $0.owningApplication?.bundleIdentifier }
        let appNames = visible.compactMap { $0.owningApplication?.applicationName }
        return infer(
            windowTitles: titles,
            bundleIdentifiers: bundleIDs,
            applicationNames: appNames)
    }

    /// Seconds to wait before each re-probe after the first one. Detection is a
    /// snapshot, and the ordinary flow is "hit Record, *then* open the thing you
    /// are recording" — the lecture tab, the podcast, the call window. A single
    /// probe at t=0 therefore files a two-hour lecture as a meeting because the
    /// browser tab had not been opened yet.
    ///
    /// Deliberately bounded to the opening of a recording. A permanent watch
    /// would keep asking ScreenCaptureKit for the whole call to answer a
    /// question the user can settle with one click on the chip.
    static let visibleContextProbeDelays: [Int] = [8, 20, 40]

    /// `.meeting` is both a real answer and the "nothing recognised" fallback,
    /// so it is the only result that justifies looking again. Anything else was
    /// positively identified, and a manual choice outranks the detector
    /// entirely — in both cases the re-probing stops.
    static func shouldProbeAgain(
        after detected: RecordingContextKind,
        manualOverride: Bool
    ) -> Bool {
        !manualOverride && detected == .meeting
    }

    static func infer(
        windowTitles: [String],
        bundleIdentifiers: [String] = [],
        applicationNames: [String] = []
    ) -> RecordingContextKind {
        let titles = windowTitles.map { $0.lowercased() }
        let apps = (bundleIdentifiers + applicationNames).map { $0.lowercased() }
        let joinedTitles = titles.joined(separator: " \n ")
        let joinedApps = apps.joined(separator: " ")

        let mediaHost = containsAny(joinedTitles, [
            "youtube", "youtu.be", "vimeo", "udemy", "coursera",
            "pluralsight", "skillshare", "khan academy",
        ])
        if mediaHost {
            if containsAny(joinedTitles, tutorialMarkers) { return .tutorial }
            if containsAny(joinedTitles, podcastMarkers) { return .podcast }
            if containsAny(joinedTitles, interviewMarkers) { return .interview }
            if containsAny(joinedTitles, lectureMarkers) { return .lecture }
            if containsAny(joinedTitles, presentationMarkers) { return .presentation }
            // Was `.video`, which meant only "played in a browser" and became
            // the catch-all for every title without a marker word — most real
            // ones. `.lecture` at least says something about how to treat the
            // content: organise concepts and evidence, and do not invent
            // meeting decisions or owners.
            return .lecture
        }

        if containsAny(joinedTitles, podcastMarkers)
            || containsAny(joinedApps, ["com.apple.podcasts", "podcast"]) {
            return .podcast
        }
        if containsAny(joinedTitles, interviewMarkers) { return .interview }
        if containsAny(joinedTitles, lectureMarkers) { return .lecture }
        if containsAny(joinedTitles, tutorialMarkers) { return .tutorial }
        if containsAny(joinedTitles, presentationMarkers) { return .presentation }
        if containsAny(joinedApps, [
            "com.apple.quicktimeplayerx", "org.videolan.vlc",
            "com.colliderli.iina", "com.apple.tv",
        ]) {
            return .lecture
        }

        // Preserve the product's established behavior for Zoom/Meet/Teams and
        // for an unknown source: automatic used to mean "meeting" everywhere.
        return .meeting
    }

    private static let tutorialMarkers = [
        "tutorial", "how to", "how-to", "walkthrough", "step by step",
        "course", "lesson", "codelab", "workshop", "implement",
    ]
    private static let podcastMarkers = ["podcast", "episode", "hosted by"]
    private static let interviewMarkers = ["interview", "q&a", "q & a"]
    private static let lectureMarkers = ["lecture", "classroom", "seminar", "webinar"]
    private static let presentationMarkers = ["presentation", "keynote", "product demo", "demo day"]

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

/// Makes built-in meeting shortcuts honest for recorded media. The explicit
/// context line still reaches every free-form request; this adapter prevents a
/// button itself from demanding fictional participants/action owners before
/// the model has a chance to follow that line.
enum RecordingPromptAdapter {
    static func adapt(_ prompt: QuickPrompt, kind: RecordingContextKind?) -> QuickPrompt {
        guard let kind, kind != .meeting, !prompt.isCustom else { return prompt }
        let label = kind.label.lowercased()
        let adapted: (title: String, tooltip: String, body: String)?
        switch prompt.id {
        case "summary":
            adapted = (
                "Summarize \(kind.label)",
                "Summarize ideas, steps, examples, and project relevance",
                "Summarize this \(label) so far. Return: TL;DR • Key ideas or claims • Ordered steps demonstrated • Technical terms and prerequisites • Examples/evidence • Pitfalls and trade-offs • Relevance to the attached project context • Practical implementation checklist • Open questions. Cite timestamps and speakers when available. Do not invent meeting decisions, owners, due dates, or a next meeting.")
        case "agenda":
            adapted = (
                "Learning Plan",
                "Turn the recording into a time-boxed learning and application plan",
                "Turn this \(label) into a time-boxed learning and application plan: sections to review, expected takeaway, hands-on exercise, project file or subsystem to inspect, validation step, and a parking lot of unanswered questions. Follow the source order and cite timestamps.")
        case "whattoask":
            adapted = (
                "Questions to Explore",
                "Surface unclear claims and implementation questions",
                "From this \(label) and the attached project context, give the highest-leverage questions to investigate next. Group them as Clarify the source • Implementation gap • Project fit • Pressure-test. Each question must cite a timestamp or context file when possible and explain why it matters. Do not address imaginary meeting participants.")
        case "answer":
            adapted = (
                "Explain Last Point",
                "Explain the latest question or concept in the recording",
                "Find the latest explicit question or unresolved concept in this \(label). Answer it directly using the recording and attached project context. If no question is present, explain the latest substantive point and state what evidence is missing.")
        case "advice":
            adapted = (
                "Apply to Project",
                "Turn the recording into project-specific recommendations",
                "Use this \(label) and the attached project context to propose the top three ways to apply the material. For each: project area, rationale, expected benefit, effort, first concrete change, validation, and rollback or risk. Distinguish what the source stated from your recommendation.")
        case "tasks":
            adapted = (
                "Implementation Steps",
                "Build a grounded implementation checklist",
                "Create an implementation checklist from this \(label) and the attached project context. For each step include prerequisite, target file/component when supported, exact change, validation, dependency, and risk. Mark anything not evidenced by the source or project files as NEEDS CONFIRMATION; do not invent owners or due dates.")
        case "logdecision":
            adapted = (
                "Capture Takeaway",
                "Capture the most useful project takeaway without filing a meeting decision",
                "Capture the most useful concrete takeaway from this \(label): the source claim or technique, supporting timestamp, where it may apply in the attached project, constraints, and the smallest verification experiment. Do not represent it as a team decision or write it to a decision ledger.")
        // Both of these asked a lecture who owns an action item. They were left
        // unadapted because the adapter grew one prompt at a time, and nothing
        // checked the whole matrix — see PromptMatrixTests, which now does.
        case "unresolved":
            adapted = (
                "Open Questions",
                "Collect what the source left unresolved",
                "List what this \(label) leaves unresolved: questions raised and never answered, claims asserted without evidence, and steps that depend on something not shown. Rank by how much each one blocks applying the material, and cite timestamps. Do not assign owners or target dates, and do not propose a follow-up meeting — nobody in this recording committed to anything.")
        case "risks":
            adapted = (
                "Risks in Applying This",
                "What could go wrong if you adopt the material",
                "From this \(label) and the attached project context, list the risks of adopting what was presented. For each: Axis (technical/operational/cost/security/fit) • Description • Likelihood, with the base rate or comparable it rests on • Impact • Early warning signal • Mitigation • First check to run. Separate risks the source itself acknowledged from ones you are raising. Do not assign owners or due dates.")
        case "commitments":
            adapted = (
                "Related Project Work",
                "Find existing project work related to the recording",
                "Compare this \(label) with the attached project context and connected trackers. List existing work that relates to the demonstrated approach, what matches or conflicts, and the next verification step. Mark unverifiable links as UNCONFIRMED; do not invent prior meeting commitments.")
        default:
            adapted = nil
        }
        guard let adapted else { return prompt }
        return QuickPrompt(
            id: prompt.id, icon: prompt.icon, title: adapted.title,
            tooltip: adapted.tooltip, prompt: adapted.body)
    }
}
