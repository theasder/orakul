import SwiftUI

/// The paywall flow: intro (benefits) → pricing (tariffs from the backend,
/// regionally priced, monthly/annual, limited-time offers) → sign-in if needed
/// → Stripe Checkout in the browser → processing (polls plan activation) →
/// confirmation / error. Shown at launch until the user subscribes or
/// explicitly continues on Free.
struct PaywallView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Stage { case intro, pricing, signIn, processing, done, error(String) }

    @State private var stage: Stage = .intro
    @State private var plans: [PaywallPlan] = []
    @State private var addOns: [PaywallAddOn] = []
    @State private var interval = "month"
    @State private var chosenPlanID: String?
    @State private var usingFree = false
    @State private var loadingPlans = false
    // Inline email-OTP sign-in
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var signingIn = false
    @State private var signInError: String?
    // Promo / access code
    @State private var promoCode = ""
    @State private var redeeming = false
    @State private var promoError: String?

    init(initialStage: Stage = .intro) {
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                switch stage {
                case .intro:      intro
                case .pricing:    pricing
                case .signIn:     signIn
                case .processing: processing
                case .done:       done
                case .error(let message): errorView(message)
                }
            }
            .padding(Space.xl)
        }
        .frame(width: 560)
        .frame(maxHeight: 720)
        .background(Theme.canvas)
        .task { await loadPlans() }
        .onAppear { FunnelTracker.track(.paywallView) }
    }

    // MARK: - Stages

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Тарифы orakul", systemImage: "sparkles")
                .font(Typo.title).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: Space.s) {
                benefit("waveform", "Every meeting transcribed — any app, even offline")
                benefit("lightbulb", "Bounded live co-pilot hours — no hidden unlimited burn")
                benefit("globe", "Cost-weighted credits for frontier models")
                benefit("person.2.wave.2", "Councils are explicit, on-demand actions")
            }
            HStack {
                Button("Остаться на бесплатном") {
                    Task { await continueWithFree() }
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("See plans") { stage = .pricing }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("paywall.see-plans")
            }
        }
    }

    private var pricing: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Выберите тариф", systemImage: "creditcard")
                .font(Typo.title).foregroundStyle(Theme.ink)

            if let offer = Self.featuredOffer(plans) {
                OfferBanner(plan: offer) { subscribe(offer) }
            }

            Picker("", selection: $interval) {
                Text("Ежемесячно").tag("month")
                Text("Год · два месяца в подарок").tag("year")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Период оплаты")

            if loadingPlans {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small).accessibilityLabel("Загружаю тарифы")
                    Spacer()
                }
            } else if plans.isEmpty {
                Text(Config.backendBaseURL.isEmpty
                     ? "Plans aren't available in this build yet — you're on the built-in free tier."
                     : "Couldn't load plans — check the backend.")
                    .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
            } else {
                ForEach(Self.selectablePlans(plans, interval: interval)) { plan in
                    PlanCard(plan: plan) { subscribe(plan) }
                }
            }

            if !addOns.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionLabel("Дополнения")
                    Text("Add compute, co-pilot time, or cloud transcription only when you need it. Support activates packs during early access.")
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    ForEach(Self.featuredAddOns(addOns)) { addOn in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(addOn.name).font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                            Text(addOn.priceLabel).font(Typo.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
            }

            promoField

            HStack {
                Button("Не сейчас") {
                    Config.paywallChoiceMade = true
                    dismiss()
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Text("Оплата через Stripe · отменить можно в любой момент")
                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    /// "Есть код?" — redeem a promo/access code instead of paying.
    private var promoField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Divider().padding(.vertical, Space.xxs)
            Text("Есть код?")
                .font(Typo.caption.weight(.medium)).foregroundStyle(Theme.inkSecondary)
            HStack(spacing: Space.s) {
                TextField("Промокод или код доступа", text: $promoCode)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .accessibilityLabel("Промокод или код доступа")
                    .accessibilityIdentifier("paywall.promo-code")
                    .onSubmit { Task { await redeem() } }
                Button(redeeming ? "Redeeming…" : "Redeem") { Task { await redeem() } }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .disabled(redeeming || promoCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("paywall.redeem")
            }
            if let promoError {
                Text(promoError).font(Typo.caption).foregroundStyle(Theme.recordRed)
            }
        }
    }

    private func redeem() async {
        let trimmed = promoCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !redeeming else { return }
        redeeming = true; promoError = nil
        defer { redeeming = false }
        LiveTestHooks.recordPromoRedemptionStarted(code: trimmed)
        do {
            // Signed in → attach the plan to that account. Otherwise mint a
            // device-scoped account so the code works with no email step.
            let redemption: PaywallAPI.PromoRedemption
            if await WheesprAuth.validAccessToken() != nil {
                redemption = try await PaywallAPI.redeemPromo(code: trimmed)
            } else {
                redemption = try await PaywallAPI.deviceRedeem(code: trimmed)
            }
            await PaywallAPI.refreshEntitlement()
            state.refreshEntitlementAfterRedeem()
            LiveTestHooks.recordPromoRedemptionSucceeded(redemption)
            FunnelTracker.track(.promoRedeem)
            Config.paywallChoiceMade = true
            stage = .done
        } catch let LLMError.http(_, _, message) {
            LiveTestHooks.recordPromoRedemptionFailed()
            promoError = message.isEmpty ? "Couldn’t redeem that code." : message
        } catch {
            LiveTestHooks.recordPromoRedemptionFailed()
            promoError = "Couldn’t redeem that code."
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label(usingFree ? "Sign in for Free" : "Sign in to subscribe",
                  systemImage: "person.crop.circle")
                .font(Typo.title).foregroundStyle(Theme.ink)
            Text("Тариф привязан к аккаунту. Пришлём одноразовый код на почту.")
                .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
            TextField("", text: $email, prompt: Text("you@example.com"))
                .textFieldStyle(.plain).padding(Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .disabled(codeSent)
                .accessibilityLabel("Адрес почты")
            if codeSent {
                TextField("", text: $code, prompt: Text("6-digit code"))
                    .textFieldStyle(.plain).padding(Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    .accessibilityLabel("6-digit verification code")
            }
            if let signInError {
                Text(signInError).font(Typo.caption).foregroundStyle(Theme.recordRed)
            }
            HStack {
                Button("Назад") { stage = .pricing }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button(signingIn ? "Working…" : (codeSent ? "Verify & continue" : "Send code")) {
                    Task { await signInStep() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(signingIn || email.trimmingCharacters(in: .whitespaces).isEmpty
                          || (codeSent && code.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    private var processing: some View {
        VStack(alignment: .center, spacing: Space.l) {
            ProgressView().controlSize(.large)
            Text("Завершите оплату в браузере…")
                .font(Typo.headline).foregroundStyle(Theme.ink)
            Text("Экран обновится сам, как только Stripe подтвердит оплату.")
                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
            Button("Отмена") { stage = .pricing }.buttonStyle(QuietButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(alignment: .center, spacing: Space.l) {
            Text("🎉").font(.system(size: 44))
                .accessibilityHidden(true)
            Text("Всё готово")
                .font(Typo.title).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("paywall.success")
            Text("Тариф активен — модели и лимиты доступны сразу.")
                .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
            Button("Start using Cruxwing") {
                Config.paywallChoiceMade = true
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("paywall.success-dismiss")
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
                .font(Typo.title).foregroundStyle(Theme.recordRed)
            Text(message).font(Typo.callout).foregroundStyle(Theme.inkSecondary)
            HStack {
                Button("Остаться на бесплатном") {
                    Task { await continueWithFree() }
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Ещё раз") { stage = .pricing }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
                .accessibilityHidden(true)
            Text(text).font(Typo.callout).foregroundStyle(Theme.inkSecondary)
        }
    }

    // MARK: - Plan selection (pure — the pricing screen's catalog logic)

    /// The single featured limited-time offer, if the catalog has one.
    static func featuredOffer(_ plans: [PaywallPlan]) -> PaywallPlan? {
        plans.first(where: { $0.offer })
    }

    /// The regular plans shown for the chosen billing interval — offers are
    /// surfaced separately in the banner, never in the plan list.
    static func selectablePlans(_ plans: [PaywallPlan], interval: String) -> [PaywallPlan] {
        plans.filter { !$0.offer && ($0.tier == "free" || $0.interval == interval) }
    }

    static func featuredAddOns(_ addOns: [PaywallAddOn]) -> [PaywallAddOn] {
        ["compute-250", "copilot-10", "whisper-300", "deepgram-live", "assembly-300"]
            .compactMap { id in addOns.first(where: { $0.id == id }) }
    }

    // MARK: - Actions

    private func loadPlans() async {
        guard !Config.backendBaseURL.isEmpty else { return }
        loadingPlans = true
        defer { loadingPlans = false }
        if let catalog = try? await PaywallAPI.catalog() {
            plans = catalog.plans
            addOns = catalog.addOns
        } else {
            plans = []
            addOns = []
        }
    }

    private func subscribe(_ plan: PaywallPlan) {
        usingFree = false
        chosenPlanID = plan.id
        Task {
            guard await WheesprAuth.validAccessToken() != nil else {
                stage = .signIn
                return
            }
            await startCheckout(planID: plan.id)
        }
    }

    private func signInStep() async {
        signingIn = true
        defer { signingIn = false }
        signInError = nil
        do {
            if !codeSent {
                try await WheesprAuth.requestCode(email: email.trimmingCharacters(in: .whitespaces))
                codeSent = true
            } else {
                let session = try await WheesprAuth.verify(
                    email: email.trimmingCharacters(in: .whitespaces),
                    code: code.trimmingCharacters(in: .whitespaces))
                Config.wheesprSession = session
                WheesprSessionNotifications.postAdopted(session)
                if usingFree {
                    Config.paywallChoiceMade = true
                    dismiss()
                } else if let planID = chosenPlanID {
                    await startCheckout(planID: planID)
                }
                else { stage = .pricing }
            }
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func continueWithFree() async {
        if await WheesprAuth.validAccessToken() != nil {
            Config.paywallChoiceMade = true
            dismiss()
            return
        }
        usingFree = true
        chosenPlanID = nil
        stage = .signIn
    }

    private func startCheckout(planID: String) async {
        FunnelTracker.track(.checkoutStart(plan: planID))
        do {
            let url = try await PaywallAPI.checkout(planID: planID)
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            stage = .processing
            await pollActivation(planID: planID)
        } catch {
            stage = .error(error.localizedDescription)
        }
    }

    /// Poll the profile until the plan is active (webhook latency ≈ seconds).
    private func pollActivation(planID: String) async {
        for _ in 0..<40 {   // ~2 minutes
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard case .processing = stage else { return }   // user backed out
            if let tier = try? await PaywallAPI.activePlanTier() {
                Config.purchasedTier = tier
                FunnelTracker.track(.subscribeSuccess(tier: tier.rawValue, via: .web))
                stage = .done
                return
            }
        }
        stage = .error("The payment hasn't been confirmed yet. If you completed checkout, your plan will activate shortly — reopen this window to re-check.")
    }
}

// MARK: - Cards

private struct PlanCard: View {
    let plan: PaywallPlan
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(plan.name).font(Typo.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text(plan.priceLabel).font(Typo.title).foregroundStyle(Theme.accentText)
            }
            ForEach(plan.features, id: \.self) { feature in
                HStack(spacing: Space.xs) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.speakerYou)
                        .accessibilityHidden(true)
                    Text(feature).font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            HStack {
                Spacer()
                if plan.purchasable {
                    Button("Subscribe") { onSubscribe() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityLabel("Subscribe to \(plan.name), \(plan.priceLabel)")
                } else {
                    Text("Входит")
                        .font(Typo.caption.weight(.semibold))
                        .foregroundStyle(Theme.speakerYou)
                }
            }
        }
        .padding(Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

private struct OfferBanner: View {
    let plan: PaywallPlan
    let onSubscribe: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "bolt.fill").foregroundStyle(.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.name) — \(plan.priceLabel)")
                    .font(Typo.headline).foregroundStyle(.white)
                if let ends = plan.offerEndsAt {
                    Text("Limited time · ends \(ends.formatted(date: .abbreviated, time: .omitted))")
                        .font(Typo.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer()
            Button("Получить") { onSubscribe() }
                .buttonStyle(.borderedProminent).tint(.white.opacity(0.25))
                .accessibilityLabel("Get \(plan.name), \(plan.priceLabel)")
        }
        .padding(Space.m)
        .background(LinearGradient(colors: [Theme.accent, Theme.accentHover],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}
