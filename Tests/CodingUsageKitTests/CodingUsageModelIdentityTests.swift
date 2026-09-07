import Foundation
import Testing
@testable import CodingUsageKit

struct CodingUsageModelIdentityTests {
    @Test func antigravityPlaceholdersMapToPublicCatalogIds() {
        #expect(CodingUsageModelIdentity.canonical("model_placeholder_m318") == "gemini-3.8-flash-high")
        #expect(CodingUsageModelIdentity.canonical("MODEL_PLACEHOLDER_M319") == "gemini-3.8-flash-medium")
        #expect(CodingUsageModelIdentity.canonical("m320") == "gemini-3.8-flash-low")
        #expect(CodingUsageModelIdentity.canonical("model_placeholder_m298") == "gemini-3.7-flash-high")
        #expect(CodingUsageModelIdentity.canonical("model_placeholder_m299") == "gemini-3.7-flash-medium")
        #expect(CodingUsageModelIdentity.canonical("model-placeholder-m71") == "gemini-3.6-flash-high")
        #expect(CodingUsageModelIdentity.canonical("model_placeholder_m264") == "gemini-3.6-flash-high")
    }

    @Test func unknownPlaceholdersAndPublicNamesStayPut() {
        #expect(CodingUsageModelIdentity.canonical("model_placeholder_m50") == "model_placeholder_m50")
        #expect(CodingUsageModelIdentity.canonical("gemini-3.8-flash-high") == "gemini-3.8-flash-high")
        #expect(CodingUsageModelIdentity.canonical("  claude-fable-5-1  ") == "claude-fable-5-1")
        #expect(CodingUsageModelIdentity.canonical("") == "")
    }
}
