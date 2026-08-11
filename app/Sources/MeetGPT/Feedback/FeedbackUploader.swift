import Foundation

/// Delivers queued feedback to `POST /api/feedback`.
///
/// Separate from ``FirstMeetingPrompt`` on purpose: recording an answer must
/// never depend on the network. The sheet appears the moment a call ends, which
/// is exactly when somebody may be on hotel wifi or about to shut the lid. So
/// the prompt writes to disk and returns, and this drains the queue afterwards
/// — on submit when it can, and on every launch until it succeeds.
///
/// There is at most one queued answer, ever, because the prompt only asks once.
/// That keeps this deliberately small: no batching, no backoff schedule, no
/// persistence of its own.
enum FeedbackUploader {

    /// Where an answer came from. Must match one of the server's enumerated
    /// sources — anything it does not recognise is stored as `app-other`, so
    /// adding a case here without adding it there silently loses the
    /// distinction rather than failing.
    static let source = "app-first-meeting"

    /// Send the queued answer, if there is one.
    ///
    /// Returns true only when the server accepted it. Safe to call on every
    /// launch: with nothing queued it makes no request at all.
    @discardableResult
    static func flush(session: URLSession = .shared) async -> Bool {
        guard let pending = FirstMeetingPrompt.unsent else { return false }
        guard let url = URL(string: "\(backendRoot)/api/feedback") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `at` is deliberately not sent. The server stamps its own clock, and
        // this queue survives restarts, sleep and timezone changes — so a device
        // timestamp would be wrong in exactly the cases where delivery is
        // delayed, which are the only cases where it would differ.
        var payload: [String: Any] = [
            "rating": pending.rating.rawValue,
            "source": source,
        ]
        if let note = pending.note { payload["note"] = note }
        if let email = pending.email { payload["email"] = email }
        if let version = appVersion { payload["appVersion"] = version }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        request.httpBody = body

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            // Offline, DNS failure, timeout. Stays queued and the next launch
            // retries. Not logged as an error: this is the expected path for
            // somebody who answered on a plane.
            return false
        }

        if (200...299).contains(http.statusCode) {
            FirstMeetingPrompt.markSent()
            return true
        }

        // A 4xx will not succeed on retry — a rejected rating stays rejected —
        // so retrying every launch forever is pure waste. Drop it from the queue
        // by marking it sent; the answer itself stays on disk regardless, so
        // nothing the user typed is lost. 429 is the exception: that is a "not
        // now", not a "never".
        if (400...499).contains(http.statusCode) && http.statusCode != 429 {
            // Status code only — never the note. Those are the user's own words
            // about their own meeting, and the unified log is readable by other
            // processes on the machine.
            Log.network.notice("feedback rejected (\(http.statusCode, privacy: .public)) — not retrying")
            FirstMeetingPrompt.markSent()
        }
        return false
    }

    private static var backendRoot: String {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    /// Which build the feedback came from — the difference between "the app is
    /// broken" and "that build was broken".
    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
