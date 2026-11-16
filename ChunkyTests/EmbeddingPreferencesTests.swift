import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct EmbeddingPreferencesTests {
    @Test func cpuProviderIsOptInAndProviderSwitchRestoresSavedSettings() {
        let settings = IsolatedSettings.make()
        #expect(settings.embeddingBackend == "ollama")
        settings.embeddingModel = "nomic-embed-text"
        settings.embeddingDimensions = 768
        let profiles = settings.workerEndpoints()
        settings.selectEmbeddingBackend("fastembed")
        #expect(settings.embeddingModel == "minishlab/potion-retrieval-32M")
        #expect(settings.embeddingDimensions == 512)
        #expect(settings.workerEndpoints() == profiles)
        settings.selectEmbeddingBackend("ollama")
        #expect(settings.embeddingModel == "nomic-embed-text")
        #expect(settings.embeddingDimensions == 768)
        settings.selectEmbeddingBackend("openai")
        settings.embeddingModel = "custom/model"
        settings.embeddingDimensions = 2048
        settings.selectEmbeddingBackend("fastembed")
        settings.selectEmbeddingBackend("openai")
        #expect(settings.embeddingModel == "custom/model")
        #expect(settings.embeddingDimensions == 2048)
    }

    @Test func localOpenAIHostUsesItsConfiguredEndpoint() {
        let settings = IsolatedSettings.make()
        settings.processingHost = .localMac
        settings.embeddingBackend = "openai"
        settings.embeddingAPIURL = "http://localhost:8002"
        settings.ollamaURL = "http://localhost:11434"
        #expect(settings.embeddingHostDescription == "http://localhost:8002 (from Local Mac)")
        settings.embeddingBackend = "fastembed"
        #expect(settings.embeddingHostDescription == "Local Mac")
    }

    @Test func savedProviderSurvivesReloadWithoutMigration() {
        let settings = IsolatedSettings.make()
        settings.embeddingBackend = "openai"
        settings.embeddingModel = "existing-model"
        settings.embeddingDimensions = 128
        let restored = AppSettings(defaults: settings.defaults, secrets: MemorySecretStore())
        #expect(restored.embeddingBackend == "openai")
        #expect(restored.embeddingModel == "existing-model")
        #expect(restored.embeddingDimensions == 128)
    }

    @Test func cpuHostAndCollectionModelAreCheckedIndependentlyOfWidth() {
        #expect(EmbeddingPreferences.host(backend: "fastembed", processingHost: .devbox) == "Local Mac")
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, processingHost: .devbox, plan: nil) != nil)
        var plan = CollectionPlan.preset(.recommended, name: "existing", vectorSize: 512, embeddingBackend: "ollama", embeddingModel: "different-model")
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, processingHost: .localMac, plan: plan)?.contains("Matching dimensions") == true)
        plan.embeddingBackend = "fastembed"
        plan.embeddingModel = EmbeddingPreferences.cpuModel
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, processingHost: .localMac, plan: plan) == nil)
        plan.vectorSize = 1024
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, processingHost: .localMac, plan: plan) != nil)
        #expect(plan.vectorSize == 1024)
    }

    @Test func cpuRequiresExplicitCollectionModelIdentity() {
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, processingHost: .localMac, plan: nil)?.contains("no saved embedding model identity") == true)
    }

    @Test func unsupportedCPUModelAndDimensionAreRejected() {
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: "other-model", dimensions: 512, processingHost: .localMac, plan: nil) != nil)
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 768, processingHost: .localMac, plan: nil) != nil)
    }

    @Test @MainActor func cpuSettingsScreenshotContainsVisibleContent() throws {
        let view = Form {
            CPUEmbeddingSettingsPane(
                processingHost: .localMac, readiness: "Ready — cached model available offline",
                busy: false, problem: "Create a collection for this model before indexing.",
                onCheck: {}, onDownload: {}
            )
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 430)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-cpu-embedding-preferences.png"))
        var visible = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 40)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 40)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.1 && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.85 {
                    visible += 1
                }
            }
        }
        #expect(visible > 20)
    }
}
