import AppKit
import CoreAudio
import Foundation
import ScreenCaptureKit

/// Notices when a meeting is likely underway by watching which app the user
/// activates. It is intentionally a lightweight, process-based heuristic — no
/// private "is the mic in use" APIs. When a known meeting app comes to the
/// foreground, it calls `onCallDetected` (debounced), which AppState turns into
/// a "start recording?" notification.
///
/// A future audio-based recognizer (and video-frame recognizer — see README
/// backlog) can replace this without changing the callback contract.
@MainActor
final class CallDetector {
    /// Fired when a meeting app becomes active and a call seems to be starting.
    var onCallDetected: ((String) -> Void)?

    /// Bundle IDs we treat as "you're in a call".
    nonisolated static let meetingApps: Set<String> = [
        "us.zoom.xos",                       // Zoom
        "com.microsoft.teams",               // Teams (classic)
        "com.microsoft.teams2",              // Teams (new)
        "com.webex.meetingmanager",          // Webex
        "com.cisco.webexmeetingsapp",        // Webex Meetings
        "com.hnc.Discord",                   // Discord
        "com.tinyspeck.slackmacgap",         // Slack (huddles/calls)
        "com.apple.FaceTime"                 // FaceTime
    ]

    /// Communication apps for the ACOUSTIC detector: spontaneous voice/video
    /// calls in these (even in the background, no calendar entry, no visible
    /// window pattern) are caught by correlating "microphone in use by some
    /// process" with one of them running.
    private static let commApps: Set<String> = meetingApps.union([
        "net.whatsapp.WhatsApp",             // WhatsApp
        "ru.keepcoder.Telegram",             // Telegram
        "com.tdesktop.Telegram",             // Telegram Desktop
        "org.whispersystems.signal-desktop", // Signal
        "com.viber.osx",                     // Viber
        "com.skype.skype"                    // Skype
    ])

    /// Bundle IDs we treat as music/video playback — used to suppress false
    /// positives when "Ignore music / video" is on.
    private static let mediaApps: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.TV",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc",
        "com.colliderli.iina", "com.apple.podcasts"
    ]

    /// Window-title fragments that mean "a call UI is on screen". This is the
    /// screen-content recognizer: it reads on-screen window metadata through
    /// the ScreenCaptureKit stack (Screen Recording is already granted for
    /// audio capture), so it also catches BROWSER calls (Google Meet in
    /// Chrome/Safari) and calls running behind other windows — both invisible
    /// to the frontmost-app heuristic. Patterns are precision-first.
    nonisolated static let callWindowTitleFragments: [(fragment: String, label: String)] = [
        ("google meet", "Google Meet"),
        ("meet.google.com", "Google Meet"),
        ("zoom meeting", "Zoom"),
        ("webex meeting", "Webex"),
        ("microsoft teams meeting", "Microsoft Teams"),
        ("whereby", "Whereby"),
        ("jitsi meet", "Jitsi"),
    ]
    private static let windowScanInterval: TimeInterval = 20

    /// Which meeting service, if any, a window title belongs to.
    ///
    /// This is the BROWSER call detector — a Google Meet tab in Chrome, a Jitsi
    /// room, a Whereby link — none of which is a running "meeting app", so the
    /// frontmost-app heuristic never sees them. Pure and separate from the
    /// ScreenCaptureKit scan so the matching itself is directly testable: a
    /// false positive interrupts someone reading a blog post about Zoom, and a
    /// miss means the browser call is never offered at all.
    ///
    /// Case-insensitive because window titles carry the page title verbatim,
    /// whatever capitalisation the site chose.
    nonisolated static func callLabel(forWindowTitle title: String) -> (fragment: String, label: String)? {
        let haystack = title.lowercased()
        return callWindowTitleFragments.first { haystack.contains($0.fragment) }
    }

    /// Apps that can actually HOST a call: a meeting client, or a browser
    /// running one. Everything else showing a meeting name is showing content
    /// ABOUT a meeting.
    nonisolated static let browserApps: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary",
        "com.apple.safari", "com.apple.safaritechnologypreview",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "company.thebrowser.browser",
        "com.brave.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera",
    ]

    /// Notetakers, recorders and workspace apps that LIST meetings by name.
    ///
    /// The reported bug: the Fireflies desktop app was running, showing its
    /// meeting list, and a row titled "… Zoom Meeting" matched the window-title
    /// recognizer. Nobody was in a call. These apps are the opposite of
    /// evidence — a notetaker showing a meeting title usually means the meeting
    /// is over.
    nonisolated static let meetingListingApps: Set<String> = [
        "ai.fireflies.desktop", "ai.fireflies.fireflies", "com.fireflies.app",
        "ai.otter.otter", "com.otter.desktop",
        "ai.fathom.app", "com.granola.granola", "tv.tldv.app", "ai.read.read",
        "com.tinyspeck.slackmacgap", "notion.id", "com.notion.desktop",
        "com.apple.iCal", "com.flexibits.fantastical2.mac",
        "com.microsoft.Outlook", "com.readdle.smartemail-Mac",
    ]

    /// Whether a window-title match should be trusted, given who owns the
    /// window.
    ///
    /// A title alone is not evidence. "Zoom Meeting" appears in a Fireflies
    /// row, a calendar entry, a Slack message and a blog post, and only one of
    /// those means a call is happening. An unknown owner is rejected rather
    /// than allowed: a false prompt during focused work costs more than a
    /// missed offer, and the acoustic and activation detectors still cover
    /// real calls this turns away.
    nonisolated static func windowOwnerCanHostCall(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let identifier = bundleID.lowercased()
        if meetingListingApps.contains(where: { $0.lowercased() == identifier }) { return false }
        if browserApps.contains(identifier) { return true }
        return meetingApps.contains(where: { $0.lowercased() == identifier })
    }

    /// Title match AND a plausible owner.
    nonisolated static func callLabel(forWindowTitle title: String,
                                      ownerBundleID: String?) -> (fragment: String, label: String)? {
        guard windowOwnerCanHostCall(bundleID: ownerBundleID) else { return nil }
        return callLabel(forWindowTitle: title)
    }

    private var observer: NSObjectProtocol?
    private var windowScanTask: Task<Void, Never>?
    /// Debounce so re-activating the same call app doesn't re-notify constantly.
    private var lastNotified: [String: Date] = [:]
    private static let debounce: TimeInterval = 300  // 5 min per app

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleActivation(note)
            }
        }
        startWindowScan()
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        windowScanTask?.cancel()
        windowScanTask = nil
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        windowScanTask?.cancel()
    }

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              Self.meetingApps.contains(bundleID) else { return }

        // Respect "Ignore music / video": if a media app is currently playing
        // in the background, assume the user is watching, not meeting.
        if Config.ignoreMediaApps, isMediaAppRunning() { return }

        // Debounce on the same canonical label as the window recognizer, so
        // one call seen by both paths yields ONE prompt, not two.
        let key = Self.canonicalLabel(forBundleID: bundleID) ?? app.localizedName ?? bundleID
        let now = Date()
        if let last = lastNotified[key], now.timeIntervalSince(last) < Self.debounce { return }
        lastNotified[key] = now

        onCallDetected?(app.localizedName ?? key)
    }

    /// Bundle ID → the label the window recognizer uses for the same service.
    /// Stable display name per app. Covers the messengers too, so a detected
    /// call is named the same on a Russian or German system — `localizedName`
    /// is whatever the vendor shipped for that locale, and the label ends up in
    /// the meeting title.
    private static func canonicalLabel(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "us.zoom.xos":                                  return "Zoom"
        case "com.microsoft.teams", "com.microsoft.teams2":  return "Microsoft Teams"
        case "com.webex.meetingmanager",
             "com.cisco.webexmeetingsapp":                   return "Webex"
        case "com.hnc.Discord":                              return "Discord"
        case "com.tinyspeck.slackmacgap":                    return "Slack"
        case "com.apple.FaceTime":                           return "FaceTime"
        case "ru.keepcoder.Telegram",
             "com.tdesktop.Telegram":                        return "Telegram"
        case "net.whatsapp.WhatsApp":                        return "WhatsApp"
        case "org.whispersystems.signal-desktop":            return "Signal"
        case "com.viber.osx":                                return "Viber"
        case "com.skype.skype":                              return "Skype"
        default:                                             return nil
        }
    }

    private func isMediaAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.mediaApps.contains(id) && !app.isTerminated
        }
    }

    // MARK: - Screen-content recognizer (window titles via ScreenCaptureKit)

    private func startWindowScan() {
        windowScanTask?.cancel()
        windowScanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanWindows()
                try? await Task.sleep(nanoseconds: UInt64(Self.windowScanInterval * 1_000_000_000))
            }
        }
    }

    private func scanWindows() async {
        // Acoustic first: it catches calls with no matching window title at
        // all (WhatsApp/Telegram voice calls, proprietary VoIP).
        scanAudioSignals()

        // Quietly skip when shareable content isn't available (permission
        // races at launch); the activation heuristic still covers app calls.
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        if Config.ignoreMediaApps, isMediaAppRunning() { return }

        for window in content.windows {
            guard let title = window.title, !title.isEmpty else { continue }
            // The owner matters as much as the title: a Fireflies row or a
            // calendar entry named "… Zoom Meeting" is not a call.
            guard let match = Self.callLabel(
                forWindowTitle: title,
                ownerBundleID: window.owningApplication?.bundleIdentifier) else { continue }

            // Debounced match (e.g. a leftover Meet tab) must NOT abort the
            // scan — later windows may hold a brand-new call.
            let now = Date()
            if let last = lastNotified[match.label], now.timeIntervalSince(last) < Self.debounce { continue }
            lastNotified[match.label] = now
            onCallDetected?(match.label)
            return   // one prompt per scan is plenty
        }
    }

    // MARK: - Acoustic detector (mic-in-use system signal)

    /// Detects spontaneous calls with no calendar entry and no recognizable
    /// window: CoreAudio reports whether the default input device is in use by
    /// ANY process (`DeviceIsRunningSomewhere` — device state only, no audio
    /// content is read, so no additional permission or monitoring consent is
    /// needed). Correlated with a running communication app to keep precision:
    /// dictation or voice memos alone won't trip it unless a comm app is open.
    private func scanAudioSignals() {
        guard Self.isMicInUseByAnyProcess() else { return }
        if Config.ignoreMediaApps, isMediaAppRunning() { return }
        guard let app = runningCommApp() else { return }

        let key = "audio:\(app)"
        let now = Date()
        if let last = lastNotified[key], now.timeIntervalSince(last) < Self.debounce { return }
        lastNotified[key] = now
        onCallDetected?(app)
    }

    /// A comm app as the ranker sees it. Plain values so the choice is testable
    /// without a running desktop.
    struct CommAppCandidate: Equatable {
        let bundleID: String
        let localizedName: String?
        /// Frontmost — the app the user is actually looking at.
        let isActive: Bool
    }

    /// Pick which running comm app the call belongs to.
    ///
    /// This used to return the FIRST match in `runningApplications`, whose order
    /// is arbitrary. Messengers — Telegram, WhatsApp, Signal — are launched at
    /// login and run all day, so the mic going live during a Zoom conference
    /// routinely reported "Telegram": the notification named the wrong app and
    /// the meeting was filed against it.
    ///
    /// Ranked instead, most decisive signal first:
    ///   · frontmost wins — you are looking at the call you are in;
    ///   · a DEDICATED meeting app outranks a messenger, because Zoom being
    ///     open is itself evidence of a meeting while Telegram being open is
    ///     the resting state of the machine;
    ///   · ties break on bundle id, so the answer is stable rather than
    ///     dependent on process-list order.
    static func rankedCommApp(from candidates: [CommAppCandidate]) -> CommAppCandidate? {
        func score(_ candidate: CommAppCandidate) -> Int {
            var score = 0
            if candidate.isActive { score += 100 }
            if meetingApps.contains(candidate.bundleID) { score += 50 }
            return score
        }
        return candidates
            .filter { commApps.contains($0.bundleID) }
            .max { lhs, rhs in
                let (left, right) = (score(lhs), score(rhs))
                if left != right { return left < right }
                return lhs.bundleID > rhs.bundleID   // stable, arbitrary but fixed
            }
    }

    static func label(for candidate: CommAppCandidate) -> String {
        canonicalLabel(forBundleID: candidate.bundleID)
            ?? candidate.localizedName
            ?? candidate.bundleID
    }

    /// What the acoustic detector would attribute a call to RIGHT NOW, from the
    /// live process list. Exposed so the end-to-end suite can check attribution
    /// against a real Zoom conference — the unit tests pin the ranking, this
    /// confirms the bundle ids match what Zoom actually ships.
    static func currentCommAppLabel() -> String? {
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> CommAppCandidate? in
            guard let id = app.bundleIdentifier, !app.isTerminated else { return nil }
            return CommAppCandidate(bundleID: id,
                                    localizedName: app.localizedName,
                                    isActive: app.isActive)
        }
        return rankedCommApp(from: candidates).map(label(for:))
    }

    private func runningCommApp() -> String? { Self.currentCommAppLabel() }

    /// True when some process is capturing from the default input device.
    /// (When MeetGPT itself records, AppState already suppresses prompts.)
    private static func isMicInUseByAnyProcess() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return false }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &runningSize, &running)
        return status == noErr && running != 0
    }
}
