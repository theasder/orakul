import AppKit

/// App light/dark theme preference. `.auto` follows the system appearance —
/// which itself switches at sunrise and sunset when macOS Appearance is set to
/// Auto.
enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:  return "Auto (sunrise / sunset)"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    /// The AppKit appearance to force, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the appearance preference to the whole app. Setting the shared
/// application's appearance flips every window at once — main, settings,
/// menu-bar popover, overlay — and `nil` clears the override so windows follow
/// the system, including its automatic sunrise/sunset switch.
enum AppearanceController {
    @MainActor static func apply(_ preference: AppAppearance) {
        NSApplication.shared.appearance = preference.nsAppearance
    }
}
