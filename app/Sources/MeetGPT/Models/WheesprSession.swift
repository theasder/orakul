import Foundation

/// A signed-in wheespr backend session: the RS256 access token (short-lived,
/// ~15 min), the opaque refresh token (long-lived, ~7 days), when the access
/// token expires, and who it belongs to.
struct WheesprSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessExpiry: Date
    var email: String
    var displayName: String?

    /// The domain the backend mints codeless device-trial accounts under
    /// (`trialClaim.js`). Never a real address — nobody receives mail here.
    static let deviceTrialDomain = "@device.cruxwing.local"

    /// An anonymous device trial rather than an account someone signed up for.
    ///
    /// The server cannot answer this for us: a trial reports `tier: "free"` and
    /// overrides only the allowances, which is exactly what makes it a one-off
    /// grant rather than a renewing plan. The synthetic email is the one thing
    /// that distinguishes the two.
    var isDeviceTrial: Bool {
        email.lowercased().hasSuffix(Self.deviceTrialDomain)
    }

    /// Treat as expired a minute early to absorb clock skew + request latency.
    var isAccessExpired: Bool { Date() >= accessExpiry.addingTimeInterval(-60) }
}
