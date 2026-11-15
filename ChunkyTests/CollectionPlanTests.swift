import Foundation
import Testing

@testable import Chunky

struct CollectionPlanTests {
    @Test func presetsMapToCreateSettings() {
        let recommended = CollectionPlan.preset(
            .recommended, name: "docs", vectorSize: 1024,
            embeddingBackend: "ollama", embeddingModel: "qwen3-embedding"
        )
        #expect(recommended.distance == .cosine)
        #expect(recommended.hybrid)
        #expect(recommended.quantization == .scalarInt8)

        let small = CollectionPlan.preset(
            .smallFastLocal, name: "docs", vectorSize: 1024,
            embeddingBackend: "ollama", embeddingModel: "qwen3-embedding"
        )
        #expect(!small.hybrid)
        #expect(small.quantization == .none)
        #expect(!small.onDisk)

        let cloud = CollectionPlan.preset(
            .largeCloud, name: "docs", vectorSize: 1024,
            embeddingBackend: "openai", embeddingModel: "Qwen/Qwen3-Embedding-0.6B"
        )
        #expect(cloud.target == .qdrantCloud)
        #expect(cloud.onDisk)
        #expect(cloud.quantization == .scalarInt8)
    }

    @Test func nameValidationAndExistingName() {
        #expect(CollectionPlan.nameError("") == "Enter a collection name.")
        #expect(CollectionPlan.nameError("bad name") != nil)
        #expect(CollectionPlan.nameError("docs_v1") == nil)
        let plan = CollectionPlan.preset(
            .recommended, name: "docs", vectorSize: 1024,
            embeddingBackend: "ollama", embeddingModel: "qwen3-embedding"
        )
        #expect(plan.existsWarning(existingNames: ["docs"]) != nil)
        #expect(plan.existsWarning(existingNames: ["other"]) == nil)
    }

    @Test func estimateIsSmallerWithScalarQuantization() {
        var full = CollectionPlan.preset(
            .smallFastLocal, name: "docs", vectorSize: 1024,
            embeddingBackend: "ollama", embeddingModel: "qwen3-embedding"
        )
        full.expectedChunks = 1000
        var scalar = full
        scalar.quantization = .scalarInt8
        #expect(scalar.estimate().ramBytes < full.estimate().ramBytes)
        #expect(scalar.estimate().isEstimate)
        #expect(scalar.binaryWarning == nil)
        scalar.quantization = .binary
        scalar.vectorSize = 384
        #expect(scalar.binaryWarning != nil)
    }

    @Test func savedPlanBecomesCreateOptions() {
        let defaults = UserDefaults(suiteName: "chunky.collection-plan-tests")!
        defaults.removePersistentDomain(forName: "chunky.collection-plan-tests")
        let plan = CollectionPlan.preset(
            .recommended, name: "docs", vectorSize: 1024,
            embeddingBackend: "ollama", embeddingModel: "qwen3-embedding"
        )
        CollectionPlanStore.save(plan, defaults: defaults)
        let options = CollectionPlanStore.options(collection: "docs", settings: IsolatedSettings.make(), defaults: defaults)
        #expect(options.hybrid)
        #expect(options.quantization == .scalarInt8)
        #expect(options.onDiskVectors == false)
        #expect(options.onDiskPayload == false)
        #expect(options.expectedVectorSize == 1024)
        #expect(CollectionPlanStore.mergedNames(server: ["documents"], defaults: defaults) == ["documents", "docs"])
        #expect(plan.connectionProblem(localURL: "http://localhost:6334", cloudURL: "", cloudAPIKey: "") == nil)
        let cloud = CollectionPlan.preset(
            .largeCloud, name: "cloud", vectorSize: 1024,
            embeddingBackend: "openai", embeddingModel: "Qwen/Qwen3-Embedding-0.6B"
        )
        #expect(cloud.connectionProblem(localURL: "http://localhost:6334", cloudURL: "", cloudAPIKey: "") != nil)
        #expect(CollectionPlan.canSave(name: "docs", vectorVerified: false, connectionProblem: nil) == false)
        #expect(CollectionPlan.canSave(name: "docs", vectorVerified: true, connectionProblem: nil))
    }

    @Test func mismatchDetectsDimensionAndHybrid() {
        let plan = CollectionPlan.preset(
            .recommended, name: "docs", vectorSize: 1024,
            embeddingBackend: "ollama", embeddingModel: "qwen3-embedding"
        )
        #expect(plan.mismatch(existingVectorSize: 768, existingHybrid: nil)?.contains("768") == true)
        #expect(plan.mismatch(existingVectorSize: 1024, existingHybrid: false)?.contains("hybrid") == true)
        #expect(plan.mismatch(existingVectorSize: 1024, existingHybrid: true) == nil)
    }
}
