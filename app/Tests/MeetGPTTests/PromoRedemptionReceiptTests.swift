import Testing
@testable import MeetGPT

@Suite("Live promo redemption receipt")
struct PromoRedemptionReceiptTests {
    @Test("exact code records one ordered Founder Ultra success without preview")
    func exactSuccess() {
        var receipt = LiveTestPromoRedemptionReceipt.armed(
            commandID: "run:promo", at: 10, previewActive: false)
        receipt.begin(
            code: "DEV-UNLIMITED-LOCAL", exactCode: "DEV-UNLIMITED-LOCAL",
            at: 11, previewActive: false)
        receipt.succeed(
            planID: "founder", planName: "Founder Plan", tier: "ultra",
            at: 12, previewActive: false)

        #expect(receipt.commandID == "run:promo")
        #expect(receipt.preparedAt == 10)
        #expect(receipt.startedAt == 11)
        #expect(receipt.completedAt == 12)
        #expect(receipt.exactCodeMatch == true)
        #expect(receipt.outcome == .success)
        #expect(receipt.planID == "founder")
        #expect(receipt.planName == "Founder Plan")
        #expect(receipt.tier == "ultra")
        #expect(receipt.previewActive == false)
    }

    @Test("wrong code is distinguishable and failure retains no claimed plan")
    func wrongCodeFailure() {
        var receipt = LiveTestPromoRedemptionReceipt.armed(
            commandID: "run:wrong", at: 20, previewActive: false)
        receipt.begin(
            code: "DEV-UNLIMITED-LOCA1", exactCode: "DEV-UNLIMITED-LOCAL",
            at: 21, previewActive: false)
        receipt.fail(at: 22, previewActive: false)

        #expect(receipt.exactCodeMatch == false)
        #expect(receipt.outcome == .failure)
        #expect(receipt.completedAt == 22)
        #expect(receipt.planID == nil)
        #expect(receipt.planName == nil)
        #expect(receipt.tier == nil)
    }

    @Test("receipt transitions are single use and terminal outcomes cannot be overwritten")
    func terminalIsImmutable() {
        var receipt = LiveTestPromoRedemptionReceipt.armed(
            commandID: "run:single-use", at: 30, previewActive: false)
        receipt.succeed(
            planID: "forged", planName: "Forged", tier: "ultra",
            at: 30.5, previewActive: true)
        #expect(receipt.outcome == .armed)
        #expect(receipt.completedAt == nil)

        receipt.begin(
            code: "DEV-UNLIMITED-LOCAL", exactCode: "DEV-UNLIMITED-LOCAL",
            at: 31, previewActive: false)
        receipt.succeed(
            planID: "founder", planName: "Founder Plan", tier: "ultra",
            at: 32, previewActive: false)
        let terminal = receipt

        receipt.begin(
            code: "different", exactCode: "DEV-UNLIMITED-LOCAL",
            at: 33, previewActive: true)
        receipt.fail(at: 34, previewActive: true)
        receipt.succeed(
            planID: "other", planName: "Other", tier: "free",
            at: 35, previewActive: true)
        #expect(receipt == terminal)
    }
}
