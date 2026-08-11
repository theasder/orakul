import SwiftUI

/// Reports that a surface was reached.
///
/// A modifier rather than an `onAppear` written out at each site, because the
/// value of this data depends entirely on it being applied consistently — a
/// funnel missing one panel does not look broken, it looks like nobody visits
/// that panel.
///
/// Fires once per appearance, not once per body evaluation: SwiftUI re-runs
/// `body` constantly, and a count that tracked re-renders would measure
/// invalidation rather than use.
struct SurfaceTracker: ViewModifier {
    let surface: AnalyticsEvent.Surface

    func body(content: Content) -> some View {
        content.onAppear { FunnelTracker.track(.surfaceOpened(surface)) }
    }
}

extension View {
    func trackSurface(_ surface: AnalyticsEvent.Surface) -> some View {
        modifier(SurfaceTracker(surface: surface))
    }
}
