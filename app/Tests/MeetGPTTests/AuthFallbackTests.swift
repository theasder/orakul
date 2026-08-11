import Foundation
import Testing
@testable import MeetGPT

/// A provider with a broken key (Anthropic 401 "invalid x-api-key") must
/// degrade to another configured provider's model, not surface a raw error.
@Suite("LLM auth-failure fallback")
struct AuthFallbackTests {
    @Test("classifies provider auth failures, not backend/session or other errors")
    func classification() {
        #expect(AutoOrchestrator.isProviderAuthFailure(
            LLMError.http("Anthropic", 401, "invalid x-api-key")))
        #expect(AutoOrchestrator.isProviderAuthFailure(
            LLMError.missingKey("Anthropic")))
        // Backend 401 = expired session — a different model can't fix it.
        #expect(!AutoOrchestrator.isProviderAuthFailure(
            LLMError.http("Backend", 401, "unauthorized")))
        // Non-auth provider errors pass through untouched.
        #expect(!AutoOrchestrator.isProviderAuthFailure(
            LLMError.http("Anthropic", 429, "rate limited")))
        #expect(!AutoOrchestrator.isProviderAuthFailure(
            LLMError.badResponse("Gemini")))
    }

    @Test("fallback model comes from a different provider, allowed for the tier")
    func fallbackModelSelection() {
        for tier in Tier.allCases {
            for provider in [LLMProvider.anthropic, .openAI] {
                guard let fallback = AutoOrchestrator.authFallbackModel(
                    excluding: provider, tier: tier) else { continue }
                #expect(fallback.provider != provider)
                #expect(fallback.isAvailable(for: tier))
                #expect(fallback.provider.isConfigured)
            }
        }
    }
}
