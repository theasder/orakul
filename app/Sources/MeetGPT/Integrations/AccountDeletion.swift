import Foundation

/// The account-deletion HTTP call (`DELETE /auth/account`), isolated from AppState
/// so the App-Review-required "delete my account" flow is unit-testable with a
/// stubbed session. AppState.deleteAccount() supplies the bearer token and, on a
/// `.deleted` outcome, signs out locally + clears the cached entitlement.
enum AccountDeletion {
    enum Outcome: Equatable {
        case deleted
        case failed(String)
    }

    static func perform(baseURL: String,
                        token: String,
                        session: URLSession = BackendPinning.shared) async -> Outcome {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return .failed("No backend is configured.") }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: root + "/auth/account") else {
            return .failed("Account deletion failed: bad backend URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failed("Account deletion failed (\(status)): \(String(body.prefix(120)))")
            }
            return .deleted
        } catch {
            return .failed("Account deletion failed: \(error.localizedDescription)")
        }
    }
}
