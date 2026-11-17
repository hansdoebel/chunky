import Testing
@testable import Chunky

@MainActor
struct PreferenceSearchTests {
    @Test func matchesEveryWordAcrossTitlesAndAliases() {
        #expect(PreferenceSearchItem.matches("  QDRANT timeout ").map(\.id) == ["upload"])
        #expect(PreferenceSearchItem.matches("download folder").map(\.id) == ["datasets"])
        #expect(PreferenceSearchItem.matches("dark").map(\.id) == ["appearance"])
        #expect(PreferenceSearchItem.matches("OCR").map(\.id) == ["documents"])
        #expect(PreferenceSearchItem.matches(" ").isEmpty)
        #expect(PreferenceSearchItem.matches("nonexistent-option").isEmpty)
    }

    @Test func resultsHaveStableUniqueIdentityAndValidDestination() {
        #expect(Set(PreferenceSearchItem.all.map(\.id)).count == PreferenceSearchItem.all.count)
        #expect(PreferenceSearchItem.all.allSatisfy { (0...6).contains($0.tab) })
    }
}
