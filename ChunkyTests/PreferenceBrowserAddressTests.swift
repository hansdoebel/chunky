import Foundation
import Testing
@testable import Chunky

@MainActor
struct PreferenceBrowserAddressTests {
    @Test func opensSavedServerRootWithSchemeAndPort() {
        #expect(PreferenceBrowserAddress.url(" http://127.0.0.1:8080/v1?api_key=secret ")?.absoluteString == "http://127.0.0.1:8080")
        #expect(PreferenceBrowserAddress.url("HTTPS://example.test/api")?.absoluteString == "https://example.test")
    }

    @Test func refusesUnsafeAddresses() {
        for value in ["", "file:///tmp/example", "javascript:alert(1)", "https://user:secret@example.test", "http://"] {
            #expect(PreferenceBrowserAddress.url(value) == nil)
        }
    }

    @Test func cloudDashboardRequiresConfiguredCloudAndNeverIncludesCredentials() {
        #expect(PreferenceBrowserAddress.cloudDashboard(cloudAddress: "", nativeAddress: "http://localhost:6334") == nil)
        #expect(PreferenceBrowserAddress.cloudDashboard(cloudAddress: "https://proxy.example.test:6333", nativeAddress: "")?.absoluteString == "https://cloud.qdrant.io")
        #expect(PreferenceBrowserAddress.cloudDashboard(cloudAddress: "", nativeAddress: "https://cluster.eu.aws.cloud.qdrant.io:6334")?.absoluteString == "https://cloud.qdrant.io")
        #expect(PreferenceBrowserAddress.cloudDashboard(cloudAddress: "", nativeAddress: "https://cloud.qdrant.io.evil.test:6334") == nil)
    }

    @Test func qdrantBrowserAddressUsesRestPort() throws {
        let rest = try #require(CollectionSnapshots.restBase(qdrantURL: "https://example.test:6334"))
        #expect(PreferenceBrowserAddress.url(rest.absoluteString)?.port == 6333)
    }
}
