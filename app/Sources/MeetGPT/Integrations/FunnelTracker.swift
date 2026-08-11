import Foundation

/// Client half of the first-party, cookieless funnel telemetry (M15b). Fire-and-
/// forget POSTs a funnel stage to `/api/funnel` using the anonymous device id — no
/// account, no PII, no cross-app identifier — consistent with the landing emitter
/// and the privacy policy's no-tracking claim. Opt-out honored (Config.funnelOptOut).
/// Telemetry must never surface an error to the user, so every failure is silent.
enum FunnelTracker {
    /// The only way the app emits analytics.
    ///
    /// Takes an `AnalyticsEvent` rather than a stage string and a `[String: Any]`
    /// bag, which is what makes "no meeting content in any payload" a property
    /// of the code instead of a rule reviewers have to enforce: no event case
    /// accepts free text, so there is nothing to pass it to.
    static func track(_ event: AnalyticsEvent) {
        guard !Config.funnelOptOut else { return }
        let (stage, props) = (event.name, event.wireProperties)
        Task.detached(priority: .background) { _ = await send(stage: stage, props: props) }
    }

    /// A once-per-device activation stage (first_recording, first_ai_action):
    /// records a local flag so it fires exactly once per install.
    static func trackOnce(_ event: AnalyticsEvent) {
        // Checked before the flag is set: opting out must not consume the
        // one-shot, or re-enabling later would silently never report it.
        guard !Config.funnelOptOut else { return }
        let key = "funnel.fired.\(event.name)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        track(event)
    }

    /// The transport. Injectable base/anon/session so it's unit-testable; returns
    /// whether the event was accepted (2xx). Never throws.
    @discardableResult
    static func send(stage: String,
                     props: [String: Any] = [:],
                     baseURL: String = Config.backendBaseURL,
                     anonId: String = Config.deviceId,
                     session: URLSession = BackendPinning.shared) async -> Bool {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: root + "/api/funnel") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["stage": stage, "anonId": anonId, "props": props])

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}
