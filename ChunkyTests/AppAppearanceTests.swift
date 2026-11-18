import AppKit
import Foundation
import Testing
@testable import Chunky

@MainActor
struct AppAppearanceTests {
    @Test func defaultAndUnknownAppearanceFollowSystem() {
        let settings = IsolatedSettings.make()
        #expect(settings.appearance == .system)
        settings.defaults.set("future-appearance", forKey: "chunky.appearance")
        let restored = AppSettings(defaults: settings.defaults, secrets: MemorySecretStore())
        #expect(restored.appearance == .system)
        #expect(restored.appearance.appearanceName == nil)
    }

    @Test func appearancePersistsWithoutRewritingOtherSettings() {
        let settings = IsolatedSettings.make()
        settings.embeddingModel = "saved-model"
        settings.embeddingDimensions = 768
        settings.qdrantAPIKey = "fixture-key"
        let before = settings.defaults.dictionaryRepresentation()
        settings.appearance = .dark
        #expect(AppSettings(defaults: settings.defaults, secrets: MemorySecretStore()).appearance == .dark)
        settings.appearance = .light
        #expect(AppSettings(defaults: settings.defaults, secrets: MemorySecretStore()).appearance == .light)
        settings.appearance = .system
        #expect(AppSettings(defaults: settings.defaults, secrets: MemorySecretStore()).appearance == .system)
        var after = settings.defaults.dictionaryRepresentation()
        after.removeValue(forKey: "chunky.appearance")
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
        #expect(settings.qdrantAPIKey == "fixture-key")
    }

    @Test func controllerAppliesSavedAppearanceAndEveryChangeIncludingSystemReset() {
        let settings = IsolatedSettings.make()
        settings.appearance = .dark
        var applied: [NSAppearance.Name?] = []
        let controller = AppAppearanceController(settings: settings) { applied.append($0) }
        #expect(applied == [.darkAqua])
        settings.appearance = .light
        settings.appearance = .light
        settings.appearance = .system
        #expect(applied == [.darkAqua, .aqua, nil])
        withExtendedLifetime(controller) {}
    }
}
