import Foundation
import Testing
@testable import Chunky

@MainActor
struct PreferenceDiagnosticTests {
    @Test func copyRemovesKnownKeysAndAuthorization() {
        let report = PreferenceDiagnostic.report(context: "Worker check", message: "Failed: fixture-key Authorization: Bearer token-value", secrets: ["fixture-key"])
        #expect(report.contains("Chunky — Worker check"))
        #expect(!report.contains("fixture-key"))
        #expect(!report.contains("token-value"))
    }

    @Test func copyRemovesURLCredentialsQueriesAndFragments() {
        let message = PreferenceDiagnostic.message("Failed https://person:password@example.test/v1?api_key=secret#private and http://localhost:6334/health", secrets: [])
        #expect(message.contains("https://example.test/v1"))
        #expect(message.contains("http://localhost:6334/health"))
        for secret in ["person", "password", "api_key", "secret", "private"] {
            #expect(!message.contains(secret))
        }
    }

    @Test func plainFailureRemainsActionable() {
        let message = "Connection refused at localhost:6334. Start Qdrant and try again."
        #expect(PreferenceDiagnostic.message(message, secrets: [""]) == message)
    }
}
