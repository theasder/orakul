import Foundation

/// Which account providers the sign-in sheet offers.
///
/// Apple and Google used to share one switch — `Config.socialAccountLoginEnabled`
/// — whose reason for being off is App Store Connect verification for Sign in
/// with Apple. Google has no part in that, so a fully configured Google provider
/// stayed invisible because of a blocker that did not apply to it.
///
/// Each provider is judged on its own readiness now, and the rule lives here
/// rather than inline in the view so it can be stated once and tested.
enum SocialSignIn {
    /// Apple keeps its gate: it genuinely needs the App Store Connect work.
    static func showsApple(flagEnabled: Bool = Config.socialAccountLoginEnabled) -> Bool {
        flagEnabled
    }

    /// Google needs one thing — a client to talk to. `Config.googleSignInClientID`
    /// falls back to the connector client, so this is true wherever Google is
    /// configured at all. Independent of Apple's flag, on purpose.
    static func showsGoogle(hasClient: Bool, appleFlagEnabled: Bool = false) -> Bool {
        hasClient
    }

    /// The "or" rule between the social buttons and the email/password form.
    static func showsDivider(apple: Bool, google: Bool) -> Bool {
        apple || google
    }
}
