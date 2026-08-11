import CryptoKit
import Foundation

/// Optional TLS certificate pinning for the backend host. **No-op** unless
/// `BACKEND_CERT_PINS` is set in mac/.env (comma-separated base64 SHA-256 of the
/// backend server's LEAF certificate, DER-encoded). When set, a connection to
/// the backend host is accepted only if it (a) still chains to a system-trusted
/// root AND (b) presents a leaf whose hash matches a pin — narrowing trust from
/// "any CA" to "our cert" on the token-carrying backend channel, as defense
/// against a compromised/rogue CA. Every other host keeps standard system trust.
///
/// Pins are public (a hash of a public certificate), so they are safe to bake
/// into the binary. Rotate them in lockstep with the server certificate.
/// Compute a pin for a deployed endpoint:
///   echo | openssl s_client -connect HOST:443 -servername HOST 2>/dev/null \
///     | openssl x509 -outform der | openssl dgst -sha256 -binary | base64
final class CertPinningDelegate: NSObject, URLSessionDelegate {
    private let pins: Set<String>
    private let pinnedHost: String

    init(pins: Set<String>, pinnedHost: String) {
        self.pins = pins
        self.pinnedHost = pinnedHost
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only intercept server-trust challenges for the pinned host; every
        // other host (OAuth providers, MCP servers, …) uses default trust.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == pinnedHost,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 1) Standard chain validation must still pass — pinning tightens, never loosens.
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // 2) The leaf cert's DER SHA-256 must match one of the configured pins.
        guard let leaf = Self.leaf(of: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)).base64EncodedString()
        completionHandler(pins.contains(hash) ? .useCredential : .cancelAuthenticationChallenge,
                          pins.contains(hash) ? URLCredential(trust: trust) : nil)
    }

    private static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }
}

/// The URLSession backend/auth calls should use: pinned when `BACKEND_CERT_PINS`
/// is configured, otherwise the plain shared session (zero behavior change).
enum BackendPinning {
    static let shared: URLSession = make()

    private static func make() -> URLSession {
        let pins = Set(Secrets.backendCertPins
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !pins.isEmpty, let host = URL(string: Config.backendBaseURL)?.host else {
            return .shared   // unconfigured → identical to today
        }
        return URLSession(configuration: .default,
                          delegate: CertPinningDelegate(pins: pins, pinnedHost: host),
                          delegateQueue: nil)
    }
}
