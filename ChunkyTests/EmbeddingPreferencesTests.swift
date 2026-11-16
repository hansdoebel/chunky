import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

@MainActor
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

    @Test func pendingJobsValidateTheirActualTargetCollections() {
        let settings = IsolatedSettings.make()
        settings.selectEmbeddingBackend("fastembed")
        settings.processingHost = .localMac
        settings.defaultCollection = "unrelated"
        let matching = CollectionPlan.preset(.recommended, name: "cpu-papers", vectorSize: 512, embeddingBackend: "fastembed", embeddingModel: EmbeddingPreferences.cpuModel)
        CollectionPlanStore.save(matching, defaults: settings.defaults)
        let different = CollectionPlan.preset(.recommended, name: settings.defaultCollection, vectorSize: 512, embeddingBackend: "ollama", embeddingModel: "different-model")
        CollectionPlanStore.save(different, defaults: settings.defaults)
        let watched = ProcessingJob(url: URL(fileURLWithPath: "/tmp/watched.pdf"))
        watched.watchedCollection = matching.name
        watched.ingestCollection = different.name
        let selected = ProcessingJob(url: URL(fileURLWithPath: "/tmp/selected.pdf"))
        selected.ingestCollection = matching.name
        let other = ProcessingJob(url: URL(fileURLWithPath: "/tmp/other.pdf"))
        #expect(settings.embeddingConfigurationProblem != nil)
        #expect(watched.targetCollection(defaultCollection: settings.defaultCollection) == matching.name)
        #expect(settings.embeddingConfigurationProblem(jobs: [watched, selected]) == nil)
        #expect(settings.embeddingConfigurationProblem(jobs: [watched, other]) != nil)
        watched.watchedCollection = ""
        #expect(watched.targetCollection(defaultCollection: settings.defaultCollection) == different.name)
    }

    @Test func cpuRetrievalChecksTheActualRouteInsteadOfProcessingHost() {
        let settings = IsolatedSettings.make()
        settings.selectEmbeddingBackend("fastembed")
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .localDocker
        let plan = CollectionPlan.preset(.recommended, name: settings.defaultCollection, vectorSize: 512, embeddingBackend: "fastembed", embeddingModel: EmbeddingPreferences.cpuModel)
        let local = RetrievalRequest.make(text: "question", collection: plan.name, limit: 10, settings: settings)
        #expect(local.route == .localQdrant)
        #expect(EmbeddingPreferences.retrievalProblem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, route: local.route, plan: plan) == nil)
        #expect(EmbeddingPreferences.problem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, processingHost: settings.processingHost, plan: plan) != nil)
        settings.devboxIngestTarget = .qdrantCloud
        let worker = RetrievalRequest.make(text: "question", collection: plan.name, limit: 10, settings: settings)
        #expect(worker.route == .worker)
        #expect(EmbeddingPreferences.retrievalProblem(backend: "fastembed", model: EmbeddingPreferences.cpuModel, dimensions: 512, route: worker.route, plan: plan) != nil)
    }

    @Test func successfulDownloadRefreshesTheSameQueueReadinessState() async {
        let settings = IsolatedSettings.make()
        settings.selectEmbeddingBackend("fastembed")
        let readiness = CPUEmbeddingReadiness()
        let summary = EmbeddingJobSummary(settings: settings, readiness: readiness)
        await readiness.check(download: false, health: { _ in throw CocoaError(.fileReadNoSuchFile) })
        let missing = summary.readiness.message
        var downloads = 0
        await readiness.check(
            download: true,
            health: { _ in
                #expect(downloads == 1)
                return "Ready — cached model available offline"
            },
            prepare: { _ in downloads += 1 }
        )
        #expect(downloads == 1)
        #expect(summary.readiness.message != missing)
        #expect(summary.readiness.message == "Ready — cached model available offline")
        #expect(!summary.readiness.busy)
        await readiness.checkIfNeeded(model: EmbeddingPreferences.cpuModel)
        #expect(summary.readiness.message == "Ready — cached model available offline")
    }

    @Test func cpuSettingsScreenshotContainsVisibleContent() async throws {
        let settings = IsolatedSettings.make()
        settings.selectEmbeddingBackend("fastembed")
        let readiness = CPUEmbeddingReadiness()
        await readiness.check(download: false, health: { _ in "Ready — cached model available offline" })
        let plan = CollectionPlan.preset(.recommended, name: settings.defaultCollection, vectorSize: 512, embeddingBackend: "fastembed", embeddingModel: EmbeddingPreferences.cpuModel)
        CollectionPlanStore.save(plan, defaults: settings.defaults)
        let view = Form {
            CPUEmbeddingSettingsPane(
                processingHost: .localMac, readiness: readiness.message,
                busy: false, problem: nil,
                onCheck: {}, onDownload: {}
            )
            Section {
                EmbeddingJobSummary(settings: settings, readiness: readiness)
            }
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 600)
        .environment(\.colorScheme, .light)
        .tint(.blue)
        let bitmap = try Self.render(view)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-cpu-embedding-preferences.png"))
        var visible = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
                    visible += 1
                }
            }
        }
        #expect(visible > 100)
        #expect(png.count > 1000)
    }

    private static func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
