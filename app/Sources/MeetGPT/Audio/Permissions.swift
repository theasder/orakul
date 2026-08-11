import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum Permission {
    case granted, denied, notDetermined
}

enum Permissions {
    // MARK: Screen Recording (needed for ScreenCaptureKit).

    /// Fast, synchronous hint. NOTE: `CGPreflightScreenCaptureAccess()` caches
    /// its answer for the process lifetime and frequently reports `.denied`
    /// even when the permission is actually granted (e.g. it was toggled while
    /// the app was running). Use it only to decide whether to *prompt* — never
    /// as the authoritative gate. For that, use `screenRecordingAuthorized()`.
    static var screenRecording: Permission {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Authoritative check for ScreenCaptureKit access: if we can enumerate
    /// shareable content, the app effectively has Screen Recording permission,
    /// regardless of what the cached preflight value claims.
    static func screenRecordingAuthorized() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false,
                                                                     onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Triggers the system prompt the first time only. After a prior deny,
    /// this returns `.denied` — the user must toggle in System Settings and
    /// relaunch the app.
    @discardableResult
    static func requestScreenRecording() -> Permission {
        _ = CGRequestScreenCaptureAccess()
        return screenRecording
    }

    // MARK: Microphone.

    static var microphone: Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:                     return .granted
        case .denied, .restricted:            return .denied
        case .notDetermined:                  return .notDetermined
        @unknown default:                     return .denied
        }
    }

    static func requestMicrophone() async -> Permission {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }
}
