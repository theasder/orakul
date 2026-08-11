import AuthenticationServices
import AppKit
import CryptoKit
import Foundation

enum AppleAccountAuthError: LocalizedError {
    case cancelled
    case unavailable
    case noIdentityToken
    case badToken

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign in with Apple was cancelled."
        case .unavailable: return "Sign in with Apple isn't available on this Mac."
        case .noIdentityToken: return "Apple didn't return an identity token."
        case .badToken: return "Apple returned an unreadable identity token."
        }
    }
}

/// Result of a native Sign in with Apple presentation.
struct AppleSignInResult: Sendable {
    let idToken: String
    /// Raw nonce sent to Apple (backend verifies against the id_token claim).
    let nonce: String
    let email: String?
    let fullName: PersonNameComponents?
}

/// Native Sign in with Apple via AuthenticationServices (macOS 13+).
/// Distinct from MCP OAuth and from the Google Calendar connector.
@MainActor
final class AppleAccountAuth: NSObject {
    static let shared = AppleAccountAuth()

    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var rawNonce: String = ""

    func signIn() async throws -> AppleSignInResult {
        guard continuation == nil else { throw AppleAccountAuthError.unavailable }
        let nonce = Self.randomNonce()
        rawNonce = nonce
        let hashed = Self.sha256(nonce)

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashed

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            controller.performRequests()
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            result.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension AppleAccountAuth: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil }
        guard let cont = continuation else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8), !idToken.isEmpty else {
            cont.resume(throwing: AppleAccountAuthError.noIdentityToken)
            return
        }
        cont.resume(returning: AppleSignInResult(
            idToken: idToken,
            nonce: rawNonce,
            email: credential.email,
            fullName: credential.fullName))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        defer { continuation = nil }
        guard let cont = continuation else { return }
        let ns = error as NSError
        if ns.domain == ASAuthorizationError.errorDomain,
           ns.code == ASAuthorizationError.canceled.rawValue {
            cont.resume(throwing: AppleAccountAuthError.cancelled)
        } else {
            cont.resume(throwing: error)
        }
    }
}

extension AppleAccountAuth: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
    }
}
