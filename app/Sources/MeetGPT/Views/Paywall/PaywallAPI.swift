import Foundation

/// A tariff option from the backend's billing catalog (regionally priced).
struct PaywallPlan: Identifiable, Decodable {
    struct Allowances: Decodable, Equatable {
        let copilotHours: Int
        let computeCredits: Int
        let groundedCycles: Int
    }

    let id: String
    let name: String
    let tier: String
    let interval: String
    let priceCents: Int
    let currency: String
    let offer: Bool
    let offerEndsAt: Date?
    let purchasable: Bool
    let allowances: Allowances
    let features: [String]

    var priceLabel: String {
        let dollars = Double(priceCents) / 100
        let per = interval == "year" ? "yr" : "mo"
        return String(format: "$%.0f/%@", dollars, per)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tier, interval, priceCents, currency, offer, offerEndsAt
        case purchasable, allowances, features
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tier = try c.decode(String.self, forKey: .tier)
        interval = try c.decode(String.self, forKey: .interval)
        priceCents = try c.decode(Int.self, forKey: .priceCents)
        currency = try c.decode(String.self, forKey: .currency)
        offer = try c.decode(Bool.self, forKey: .offer)
        purchasable = try c.decodeIfPresent(Bool.self, forKey: .purchasable) ?? (tier != "free")
        allowances = try c.decodeIfPresent(Allowances.self, forKey: .allowances)
            ?? Self.fallbackAllowances(tier: tier)
        features = try c.decode([String].self, forKey: .features)
        if let iso = try c.decodeIfPresent(String.self, forKey: .offerEndsAt) {
            offerEndsAt = ISO8601DateFormatter().date(from: iso)
        } else {
            offerEndsAt = nil
        }
    }

    private static func fallbackAllowances(tier: String) -> Allowances {
        let mapped = TariffAllowance.forTier(Tier(rawValue: tier) ?? .free)
        return Allowances(copilotHours: mapped.copilotHours,
                          computeCredits: mapped.computeCredits,
                          groundedCycles: mapped.groundedCycles)
    }
}

struct PaywallAddOn: Identifiable, Decodable {
    let id: String
    let category: String
    let name: String
    let priceCents: Int
    let quantity: Int
    let unit: String
    let interval: String?

    var priceLabel: String {
        let base = String(format: "$%.0f", Double(priceCents) / 100)
        return interval == "month" ? base + "/mo" : base
    }
}

struct PaywallCatalog {
    let plans: [PaywallPlan]
    let addOns: [PaywallAddOn]
}

struct PaywallUsage: Decodable {
    struct CreditFrame: Decodable { let computeCredits: Int }
    let tier: String
    let allowances: PaywallPlan.Allowances
    let used: CreditFrame
    let remaining: CreditFrame
    let periodStart: String
}

/// Thin client for the backend billing endpoints.
enum PaywallAPI {
    private static var root: String {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    /// The user's region drives regional pricing (server applies multipliers).
    private static var region: String {
        Locale.current.region?.identifier ?? ""
    }

    /// Promo redemption is part of the live-call evidence contract. Keep its
    /// network trace body-free and code-free while still proving that the app,
    /// rather than a helper shell, reached the real billing route.
    private static func promoData(
        for request: URLRequest, path: String
    ) async throws -> (Data, URLResponse) {
        let requestID = UUID().uuidString
        let startedAt = Date()
        Log.network.info(
            "event=promo_redeem_start request_id=\(requestID, privacy: .public) method=POST path=\(path, privacy: .public) body_bytes=\(request.httpBody?.count ?? 0, privacy: .public)")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.network.info(
                "event=promo_redeem_response request_id=\(requestID, privacy: .public) status=\(status, privacy: .public)")
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            Log.network.info(
                "event=promo_redeem_complete request_id=\(requestID, privacy: .public) method=POST path=\(path, privacy: .public) status=\(status, privacy: .public) elapsed_ms=\(elapsed, privacy: .public) response_bytes=\(data.count, privacy: .public)")
            return (data, response)
        } catch {
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            Log.network.error(
                "event=promo_redeem_failed request_id=\(requestID, privacy: .public) method=POST path=\(path, privacy: .public) elapsed_ms=\(elapsed, privacy: .public) error_kind=transport")
            throw error
        }
    }

    static func catalog() async throws -> PaywallCatalog {
        guard let url = URL(string: "\(root)/api/billing/plans?region=\(region)") else {
            return PaywallCatalog(plans: [], addOns: [])
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Response: Decodable {
            let plans: [PaywallPlan]
            let addOns: [PaywallAddOn]?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return PaywallCatalog(plans: decoded.plans, addOns: decoded.addOns ?? [])
    }

    static func plans() async throws -> [PaywallPlan] { try await catalog().plans }

    /// Developer tier preview, sent so the credits rail reports the SAME plan the
    /// model picker is gating on. Without it Settings previews Pro while the rail
    /// keeps showing the real entitlement. nil outside dev builds, and the server
    /// ignores it unless explicitly enabled and not in production.
    static func applyDevTierPreview(to request: inout URLRequest) {
        guard let preview = Config.devTierOverride else { return }
        request.setValue(preview.rawValue, forHTTPHeaderField: "X-Dev-Tier")
    }

    static func usage() async throws -> PaywallUsage? {
        guard let token = await WheesprAuth.validAccessToken(),
              let url = URL(string: "\(root)/api/billing/usage") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        applyDevTierPreview(to: &request)
        let (data, response) = try await BackendPinning.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return try JSONDecoder().decode(PaywallUsage.self, from: data)
    }

    static func checkout(planID: String) async throws -> URL {
        guard let url = URL(string: "\(root)/api/billing/checkout") else {
            throw LLMError.badResponse("Billing")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await WheesprAuth.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["planId": planID, "region": region])
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Billing", http.statusCode, (object?["error"] as? String) ?? "")
        }
        guard let raw = object?["url"] as? String, let checkoutURL = URL(string: raw) else {
            throw LLMError.badResponse("Billing")
        }
        return checkoutURL
    }

    /// Outcome of redeeming a promo code.
    struct PromoRedemption {
        let planID: String
        let planName: String
        let tier: Tier
    }

    /// Redeem a promo code: validate it (`/api/promo`), activate the plan it
    /// grants (`/api/subscribe`), then refresh the entitlement so the new tier
    /// takes effect immediately. Requires sign-in.
    static func redeemPromo(code: String) async throws -> PromoRedemption {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.http("Promo", 400, "Enter a code.") }
        guard let token = await WheesprAuth.validAccessToken() else {
            throw LLMError.http("Promo", 401, "Sign in to redeem a code.")
        }

        // 1) Validate — resolve the code to the plan it grants.
        guard let promoURL = URL(string: "\(root)/api/promo") else { throw LLMError.badResponse("Promo") }
        var validate = URLRequest(url: promoURL)
        validate.httpMethod = "POST"
        validate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        validate.httpBody = try JSONSerialization.data(withJSONObject: ["code": trimmed])
        let (vData, _) = try await promoData(for: validate, path: "/api/promo")
        let vObj = (try? JSONSerialization.jsonObject(with: vData)) as? [String: Any]
        guard (vObj?["valid"] as? Bool) == true, let planID = vObj?["planId"] as? String else {
            throw LLMError.http("Promo", 400, "That code isn’t valid or has expired.")
        }
        let planName = ((vObj?["plan"] as? [String: Any])?["name"] as? String) ?? "your plan"

        // 2) Redeem — activate the plan for this account.
        guard let subURL = URL(string: "\(root)/api/subscribe") else { throw LLMError.badResponse("Promo") }
        var subscribe = URLRequest(url: subURL)
        subscribe.httpMethod = "POST"
        subscribe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        subscribe.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        subscribe.httpBody = try JSONSerialization.data(withJSONObject: ["planId": planID, "promoCode": trimmed])
        let (sData, sResp) = try await promoData(for: subscribe, path: "/api/subscribe")
        let sObj = (try? JSONSerialization.jsonObject(with: sData)) as? [String: Any]
        if let http = sResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Promo", http.statusCode, (sObj?["error"] as? String) ?? "Redemption failed.")
        }

        // 3) Reflect the new tier immediately (not gated on gateway mode).
        let tier = (try? await activePlanTier()) ?? .premium
        Config.purchasedTier = tier
        return PromoRedemption(planID: planID, planName: planName, tier: tier)
    }

    /// Redeem a code WITHOUT signing in: the backend mints a device-scoped account
    /// (bounded by the code's usage limit, idempotent per device) and returns a
    /// session, which we adopt so the granted tier is live immediately. No email.
    static func deviceRedeem(code: String) async throws -> PromoRedemption {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.http("Promo", 400, "Enter a code.") }
        guard let url = URL(string: "\(root)/api/promo/device-redeem") else { throw LLMError.badResponse("Promo") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": trimmed, "deviceId": Config.deviceId])
        let (data, resp) = try await promoData(
            for: request, path: "/api/promo/device-redeem")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Promo", http.statusCode, (obj["error"] as? String) ?? "Redemption failed.")
        }
        guard (obj["valid"] as? Bool) == true,
              let sessionObj = obj["session"] as? [String: Any],
              let access = sessionObj["access_token"] as? String, !access.isEmpty,
              let refresh = sessionObj["refresh_token"] as? String, !refresh.isEmpty else {
            throw LLMError.http("Promo", 400, "That code isn’t valid or has expired.")
        }

        // Adopt the device session so entitlement is live (metered per device).
        let expiresIn = (sessionObj["expires_in"] as? Double) ?? 900
        let userObj = sessionObj["user"] as? [String: Any]
        Config.wheesprSession = WheesprSession(
            accessToken: access,
            refreshToken: refresh,
            accessExpiry: Date().addingTimeInterval(expiresIn),
            email: (userObj?["email"] as? String) ?? "",
            displayName: userObj?["displayName"] as? String)
        if let session = Config.wheesprSession {
            WheesprSessionNotifications.postAdopted(session)
        }

        let tier: Tier
        if let name = obj["tier"] as? String, let t = Tier(rawValue: name) {
            tier = t
        } else {
            tier = (try? await activePlanTier()) ?? .premium
        }
        Config.purchasedTier = tier
        let planName = ((obj["plan"] as? [String: Any])?["name"] as? String) ?? "your plan"
        let planID = (obj["planId"] as? String) ?? ""
        return PromoRedemption(planID: planID, planName: planName, tier: tier)
    }

    /// Claim the codeless device trial: a one-off grant with no sign-in.
    ///
    /// Same shape as `deviceRedeem` minus the code, and deliberately SILENT —
    /// it runs on first launch, and a first-run user should see a credit balance
    /// rather than a dialog about one. Every failure path returns false and
    /// leaves the app exactly as it was: signed out, with unlimited on-device
    /// transcription still working, which is the state it already renders.
    ///
    /// Not called when a session already exists — adopting a trial over a real
    /// account would downgrade a signed-in user to a one-off plan.
    @discardableResult
    static func claimDeviceTrial() async -> Bool {
        guard Config.wheesprSession == nil else { return false }
        guard let url = URL(string: "\(root)/api/trial/device-claim") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceId": Config.deviceId])

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }

        // `claimed: false` is a normal answer, not an error: the daily ceiling is
        // reached. The server deliberately returns 200 so this does not retry.
        guard (obj["claimed"] as? Bool) == true,
              let sessionObj = obj["session"] as? [String: Any],
              let access = sessionObj["access_token"] as? String, !access.isEmpty,
              let refresh = sessionObj["refresh_token"] as? String, !refresh.isEmpty
        else { return false }

        let expiresIn = (sessionObj["expires_in"] as? Double) ?? 900
        let userObj = sessionObj["user"] as? [String: Any]
        Config.wheesprSession = WheesprSession(
            accessToken: access,
            refreshToken: refresh,
            accessExpiry: Date().addingTimeInterval(expiresIn),
            email: (userObj?["email"] as? String) ?? "",
            displayName: userObj?["displayName"] as? String)
        if let session = Config.wheesprSession {
            WheesprSessionNotifications.postAdopted(session)
        }
        // The trial rides on a `free`-tier account; only the plan's allowances
        // differ, and those are metered server-side.
        Config.purchasedTier = (try? await activePlanTier()) ?? .free
        return true
    }

    /// The active plan's tier from the profile, or nil when no plan is active.
    static func activePlanTier() async throws -> Tier? {
        guard let token = await WheesprAuth.validAccessToken(),
              let url = URL(string: "\(root)/auth/profile") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let user = object?["user"] as? [String: Any],
              let plan = user["plan"] as? [String: Any],
              (plan["status"] as? String) == "active" || (plan["unlimited"] as? Bool) == true else {
            Config.billingPeriodAnchor = nil
            return nil
        }
        if let activatedAt = plan["activatedAt"] as? String {
            Config.billingPeriodAnchor = ISO8601DateFormatter().date(from: activatedAt)
        }
        let tierName = ((plan["metadata"] as? [String: Any])?["tier"] as? String) ?? "premium"
        return Tier(rawValue: tierName) ?? .premium
    }

    /// M2d — the server is the tier truth when the backend serves LLM: refresh
    /// the purchased tier at launch so cancellations downgrade and purchases
    /// made on another device arrive. Semantics: signed out → keep the cached
    /// tier (re-checked on next sign-in); signed in + no active plan → clear
    /// it; network failure → leave the cache untouched.
    static func refreshEntitlement() async {
        guard Config.llmViaBackend else { return }
        guard await WheesprAuth.validAccessToken() != nil else { return }
        do {
            Config.purchasedTier = try await activePlanTier()
        } catch {
            // Offline / backend down: the cached entitlement stands.
        }
    }
}
