import Foundation
import Testing
@testable import Chunky

@MainActor
struct InterfaceModeTests {
    @Test func simpleIsDefaultForNewAndExistingSettings() {
        let settings = IsolatedSettings.make()
        #expect(settings.interfaceMode == .simple)
        settings.embeddingModel = "existing-model"
        settings.embeddingDimensions = 768
        settings.embeddingConcurrency = 9
        let restored = AppSettings(defaults: settings.defaults, secrets: MemorySecretStore())
        #expect(restored.interfaceMode == .simple)
        #expect(restored.embeddingModel == "existing-model")
        #expect(restored.embeddingDimensions == 768)
        #expect(restored.embeddingConcurrency == 9)
    }

    @Test func modePersistsAndUnknownValueFallsBackToSimple() {
        let settings = IsolatedSettings.make()
        settings.interfaceMode = .advanced
        #expect(AppSettings(defaults: settings.defaults, secrets: MemorySecretStore()).interfaceMode == .advanced)
        settings.interfaceMode = .simple
        #expect(AppSettings(defaults: settings.defaults, secrets: MemorySecretStore()).interfaceMode == .simple)
        settings.defaults.set("future-mode", forKey: "chunky.interfaceMode")
        #expect(AppSettings(defaults: settings.defaults, secrets: MemorySecretStore()).interfaceMode == .simple)
    }

    @Test func changingModeOnlyWritesPresentationPreference() {
        let settings = IsolatedSettings.make()
        settings.embeddingBackend = "openai"
        settings.embeddingModel = "custom/model"
        settings.embeddingDimensions = 2048
        settings.qdrantAPIKey = "fixture-qdrant-secret"
        settings.workerToken = "fixture-worker-secret"
        let profiles = settings.workerEndpoints()
        let before = settings.defaults.dictionaryRepresentation()
        settings.interfaceMode = .advanced
        settings.interfaceMode = .simple
        var after = settings.defaults.dictionaryRepresentation()
        after.removeValue(forKey: "chunky.interfaceMode")
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
        #expect(settings.qdrantAPIKey == "fixture-qdrant-secret")
        #expect(settings.workerToken == "fixture-worker-secret")
        #expect(settings.workerEndpoints() == profiles)
    }

    @Test func simpleNavigationKeepsCurrentSpecialistToolWithoutChangingSelection() {
        #expect(InterfaceMode.simple.visibleViews(selected: .queue) == [.queue, .collections, .retrieval])
        for selected in ViewMode.allCases {
            let visible = InterfaceMode.simple.visibleViews(selected: selected)
            #expect(visible.contains(selected))
            #expect(visible.filter(\.isAdvanced) == (selected.isAdvanced ? [selected] : []))
            #expect(InterfaceMode.advanced.visibleViews(selected: selected) == ViewMode.allCases)
        }
    }
}
