import SwiftUI

/// Compact panel shown from the menu-bar item. Mirrors the essential session
/// controls (record/stop + live timer) and gives quick access to the main
/// window, settings, and quit — so the app is usable while its window is
/// hidden behind a meeting.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var mcp: MCPConnectionManager
    @EnvironmentObject private var overlay: OverlayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            statusLine
            Divider().overlay(Theme.hairline)
            controls
        }
        .padding(Space.l)
        .frame(width: 268)
        .background(Theme.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.s) {
            // The real app icon, not an SF Symbol standing in for it. This row is
            // the app's only brand moment while the main window is hidden behind a
            // meeting, and `brain.head.profile` is a generic glyph — it said "an AI
            // thing", not "orakul".
            //
            // Read from the bundle rather than bundling an SVG: SwiftUI cannot load
            // SVG without a rasterisation step, and AppIcon.icns is already shipped
            // and already the mark. Falls back to the old glyph if the icon is
            // missing, which happens in a test host with no bundled resources.
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
            }
            Text("orakul")
                .font(Typo.headline)
                .foregroundStyle(Theme.ink)
            Spacer()
            StatusDot(color: statusColor, live: state.isRecording)
        }
    }

    private var statusLine: some View {
        HStack(spacing: Space.s) {
            Text(statusTitle)
                .font(Typo.callout)
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            if state.isRecording {
                RecordingElapsedLabel(clock: state.recordingClock)
                    .font(Typo.mono)
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Space.s) {
            Button(action: state.toggleRecording) {
                HStack(spacing: Space.s) {
                    Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                    Text(recordLabel)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.isBusy)

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                menuRow(icon: "macwindow", title: "Open Cruxwing")
            }
            .buttonStyle(QuietButtonStyle())

            Button {
                overlay.toggle(state: state, mcp: mcp)
            } label: {
                menuRow(icon: "rectangle.inset.topright.filled",
                        title: overlay.isShown ? "Скрыть плашку" : "Show overlay")
            }
            .buttonStyle(QuietButtonStyle())
            .help("Floating co-pilot card that stays on top of your meeting")

            // Copy, never send: Cruxwing composes the week and a human decides
            // which window it lands in. The submenu is the audience choice —
            // they differ in what each is allowed to see, not in tone.
            Menu {
                ForEach(WeeklyDigest.Audience.allCases, id: \.self) { audience in
                    Button(audience.heading) { state.copyWeeklyDigest(audience: audience) }
                }
            } label: {
                menuRow(icon: "doc.on.clipboard", title: "Copy this week's digest")
            }
            .menuStyle(.borderlessButton)
            .help("Decisions and commitments from the last 7 days, ready to paste")

            if let notice = state.digestCopyNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, Space.m)
                    .transition(.opacity)
            }

            settingsButton

            Button { NSApp.terminate(nil) } label: {
                menuRow(icon: "power", title: "Quit")
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                menuRow(icon: "gearshape", title: "Settings…")
            }
            .buttonStyle(QuietButtonStyle())
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                menuRow(icon: "gearshape", title: "Settings…")
            }
            .buttonStyle(QuietButtonStyle())
        }
    }

    private func menuRow(icon: String, title: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).frame(width: 16)
            Text(title)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status mapping

    private var recordLabel: String {
        switch state.status {
        case .idle, .error: return "Start recording"
        case .starting:     return "Starting…"
        case .recording:    return "Stop recording"
        case .paused:       return "Stop recording"
        case .stopping:     return "Stopping…"
        }
    }

    private var statusTitle: String {
        switch state.status {
        case .idle:          return "Idle"
        case .starting:      return "Starting…"
        case .recording:     return "Recording"
        case .paused:        return "Paused"
        case .stopping:      return "Stopping…"
        case .error:         return "Error — open the app"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .recording:            return Theme.recordRed
        case .starting, .stopping:  return Theme.accent
        case .paused:               return Theme.amber
        case .error:                return Theme.recordRed
        case .idle:                 return Theme.inkTertiary
        }
    }
}
