import Foundation

/// The client half of the StoreKit receipt bridge (M11b-3a): POST a SIGNED
/// StoreKit transaction (JWS) to `/api/billing/storekit`, which re-verifies it
/// against Apple's root server-side and activates the entitlement — the same end
/// state the Stripe webhook produces. Isolated from the StoreKit-native purchase
/// flow so this network seam is unit-testable with a stubbed session; the caller
/// (`StoreKitPurchaser`) supplies the bearer token and the JWS.
///
/// Nothing is granted on the client's word: the server owns verification and this
/// call only reports back what the server decided.
enum StoreKitBridge {
    enum Outcome: Equatable {
        /// A subscription was activated (or was already active — a replayed
        /// transaction, `idempotent == true`).
        case activated(tier: Tier, planId: String, idempotent: Bool)
        /// A verified consumable was durably added to this billing period. The
        /// server owns the enforced pool and returns the catalog quantity/unit.
        case addOnGranted(addOnId: String, quantity: Int, unit: String, idempotent: Bool)
        /// Recognized consumable whose durable grant rail is not complete.
        case notGrantable(String)
        case failed(String)
    }

    static func submit(signedTransaction: String,
                       baseURL: String = Config.backendBaseURL,
                       token: String,
                       session: URLSession = BackendPinning.shared) async -> Outcome {
        let signed = signedTransaction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signed.isEmpty else { return .failed("Missing purchase receipt.") }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return .failed("No backend is configured.") }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: root + "/api/billing/storekit") else {
            return .failed("Purchase failed: bad backend URL.")
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return .failed("Sign in to complete your purchase.") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["signedTransaction": signed])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("Purchase failed: no response.") }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            if (200...299).contains(http.statusCode),
               (object["ok"] as? Bool) == true,
               (object["kind"] as? String) == "subscription",
               let planId = object["planId"] as? String,
               let tierName = object["tier"] as? String,
               let tier = Tier(rawValue: tierName) {
                let idempotent = (object["idempotent"] as? Bool) == true
                return .activated(tier: tier, planId: planId, idempotent: idempotent)
            }

            if (200...299).contains(http.statusCode),
               (object["ok"] as? Bool) == true,
               (object["kind"] as? String) == "addon",
               let addOnId = object["addOnId"] as? String,
               let quantity = object["quantity"] as? Int,
               let unit = object["unit"] as? String,
               quantity > 0, !unit.isEmpty {
                return .addOnGranted(
                    addOnId: addOnId,
                    quantity: quantity,
                    unit: unit,
                    idempotent: (object["idempotent"] as? Bool) == true)
            }

            // A recognized but unsupported consumable must stay explicit.
            if (object["kind"] as? String) == "addon" {
                return .notGrantable(object["error"] as? String ?? "This item can't be granted yet.")
            }

            let message = (object["error"] as? String) ?? "Purchase failed (\(http.statusCode))."
            return .failed(message)
        } catch {
            return .failed("Purchase failed: \(error.localizedDescription)")
        }
    }
}
