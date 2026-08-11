import Foundation
import StoreKit

/// The StoreKit 2 purchase flow (M11b-3b). Fetches products by the ids the backend
/// catalog defines (`com.cruxwing.sub.*` / `.pack.*` — see functions/storeKit.js),
/// runs Apple's purchase sheet, and hands the SIGNED transaction (JWS) to
/// `StoreKitBridge.submit` → the server re-verifies it against Apple's root and
/// activates the plan. The client never grants entitlement itself.
///
/// The StoreKit-native calls (`Product.products`, `purchase`, `Transaction.finish`)
/// need real App Store Connect products and a signed-in sandbox tester to exercise,
/// so this path is DEVICE-tested (M11b-4 creates the products). The network seam it
/// depends on — `StoreKitBridge.submit` — is unit-tested (StoreKitBridgeTests).
enum StoreKitPurchaser {
    enum Result: Equatable {
        case activated(tier: Tier, planId: String)
        case addOnGranted(addOnId: String, quantity: Int, unit: String)
        case cancelled
        /// Ask-to-buy / SCA: Apple approves later and delivers via
        /// `Transaction.updates` — `syncUnfinished` submits it on the next launch.
        case pending
        case notGrantable(String)
        case failed(String)
    }

    /// Fetch StoreKit products for a set of catalog product ids so the paywall can
    /// display Apple's localized price + purchase them. Unknown ids are dropped by
    /// StoreKit; an empty/failed fetch returns [].
    static func products(for ids: [String]) async -> [Product] {
        let wanted = ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !wanted.isEmpty else { return [] }
        return (try? await Product.products(for: wanted)) ?? []
    }

    /// Purchase a product and, on a verified transaction, submit its JWS to the
    /// backend bridge. The transaction is only `finish()`ed once the server has
    /// durably recorded the entitlement (or explicitly can't grant it), so a
    /// transient submit failure is left unfinished and retried by `syncUnfinished`.
    static func purchase(_ product: Product, token: String) async -> Result {
        let purchaseResult: Product.PurchaseResult
        do {
            purchaseResult = try await product.purchase()
        } catch {
            return .failed("Purchase failed: \(error.localizedDescription)")
        }

        switch purchaseResult {
        case .success(let verification):
            return await grant(from: verification, token: token, finishOnFailure: false)
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .failed("Unknown purchase state.")
        }
    }

    /// Drain transactions that completed outside a live purchase (ask-to-buy
    /// approvals, renewals, purchases made on another device, or a submit that
    /// failed last time) and hand each to the bridge. Call once at launch.
    static func syncUnfinished(token: String) async {
        for await verification in Transaction.unfinished {
            _ = await grant(from: verification, token: token, finishOnFailure: false)
        }
    }

    // MARK: - Shared grant path

    private static func grant(from verification: VerificationResult<Transaction>,
                              token: String,
                              finishOnFailure: Bool) async -> Result {
        guard case .verified(let transaction) = verification else {
            // Apple couldn't verify its own signature — never trust it, and never
            // finish it (leave it for Apple/StoreKit to resolve).
            return .failed("Could not verify the purchase.")
        }

        let outcome = await StoreKitBridge.submit(
            signedTransaction: verification.jwsRepresentation, token: token)
        switch outcome {
        case .activated(let tier, let planId, _):
            await transaction.finish()   // server recorded it — stop replaying.
            FunnelTracker.track(.subscribeSuccess(tier: tier.rawValue, via: .iap))
            return .activated(tier: tier, planId: planId)
        case .addOnGranted(let addOnId, let quantity, let unit, _):
            await transaction.finish()   // server durably recorded the grant.
            FunnelTracker.track(.addOnGranted(addOn: addOnId, quantity: quantity, unit: unit))
            return .addOnGranted(addOnId: addOnId, quantity: quantity, unit: unit)
        case .notGrantable(let message):
            await transaction.finish()   // nothing to grant; don't retry forever.
            return .notGrantable(message)
        case .failed(let message):
            if finishOnFailure { await transaction.finish() }
            return .failed(message)      // leave UNfinished → retried next launch.
        }
    }
}
