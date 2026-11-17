import Foundation
import Testing
@testable import Chunky

@MainActor
struct DatasetCloudIngestTests {
    let budget = DatasetCloudBudget(tier: .free, ram: 700_000_000, disk: 3_000_000_000)

    func source(rows: Int = 35, text: String = "Fixture text") throws -> DatasetCloudSource {
        let data = try JSONSerialization.data(withJSONObject: ["text": text])
        return DatasetCloudSource(datasetID: "fixture/corpus", revision: String(repeating: "a", count: 40), config: "en", split: "train", sha256: String(repeating: "b", count: 64), rows: rows, visit: { handler in
            for index in 0..<rows { try Task.checkCancellation(); try await handler(index, data) }
        })
    }

    @Test func unicodeChunksReassembleWithoutDroppedBytesAndHaveStableIDs() throws {
        let text = String(repeating: "Ä🙂資料 ", count: 400)
        let input = try JSONSerialization.data(withJSONObject: ["text": text])
        let chunks = try DatasetCloudChunk.split(row: 4, data: input, field: "text", maximumBytes: 512)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.allSatisfy { $0.text.utf8.count <= 512 })
        var offset = 0
        for chunk in chunks { #expect(chunk.offset == offset); offset += chunk.text.utf8.count }
        let dataset = try source()
        let ids = chunks.map { $0.id(source: dataset, field: "text", maximumBytes: 512) }
        #expect(Set(ids).count == chunks.count)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(ids == chunks.map { $0.id(source: dataset, field: "text", maximumBytes: 512) })
        #expect(ids[0] != chunks[0].id(source: dataset, field: "text", maximumBytes: 2048))
        let bytes = try chunks[0].budgetedPayloadBytes(source: dataset, field: "text", backend: "ollama", model: "fixture")
        #expect(bytes % 128 == 0 && bytes > chunks[0].text.utf8.count)
    }

    @Test func freeCeilingsUnknownBudgetsAndDiskReserveFailClosed() throws {
        for bad in [DatasetCloudBudget(tier: .free, ram: .nan, disk: 1), DatasetCloudBudget(tier: .free, ram: 1, disk: 4_000_000_001), DatasetCloudBudget(tier: .standard, ram: 0, disk: .infinity)] {
            #expect(throws: DatasetBenchmarkError.self) { try bad.validate() }
        }
        let estimate = DatasetCloudEstimate(points: 1000, payloadBytes: 100_000, dimensions: 1536)
        #expect(estimate.vectorBytes == 6_144_000)
        #expect(estimate.disk > estimate.persistentDisk * 2)
        #expect(estimate.ram > estimate.vectorBytes)
        #expect(throws: DatasetBenchmarkError.self) { try DatasetCloudBudget(tier: .free, ram: 700_000_000, disk: 10).require(estimate) }
    }

    @Test func preparesAllRowsThenStreamsMoreThanLegacyBenchmarkLimitInBoundedBatches() async throws {
        var maxBatch = 0
        var writes = 0
        var creates = 0
        var queries = 0
        let operations = DatasetCloudOperations(embed: { texts, query in
            maxBatch = max(maxBatch, texts.count)
            if query { queries += 1 }
            return texts.map { _ in [Float(1), 0] }
        }, capacity: { budget }, create: { _, estimate in #expect(estimate.points == 1001); creates += 1 }, verify: { _, _ in }, write: { _, points in
            #expect(points.allSatisfy { $0.metadata["dataset_byte_offset"] != nil })
            writes += points.count
        })
        let plan = try await DatasetCloudRunner.prepare(source: source(rows: 1001), field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: budget, operations: operations)
        #expect(creates == 0 && writes == 0)
        let result = await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in }
        #expect(result.completed && result.acknowledgedPoints == 1001)
        #expect(maxBatch == 16 && creates == 1 && queries == 2)
    }

    @Test func overBudgetPlanAndChangedCapacityNeverCreate() async throws {
        var creates = 0
        var available = budget
        let operations = DatasetCloudOperations(embed: { texts, _ in texts.map { _ in [Float(1), 0] } }, capacity: { available }, create: { _, _ in creates += 1 }, verify: { _, _ in }, write: { _, _ in Issue.record("Unexpected write") })
        do {
            _ = try await DatasetCloudRunner.prepare(source: source(), field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: DatasetCloudBudget(tier: .free, ram: 1, disk: 1), operations: operations)
            Issue.record("Expected budget rejection")
        } catch { #expect(creates == 0) }
        let plan = try await DatasetCloudRunner.prepare(source: source(), field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: budget, operations: operations)
        available.disk = 1
        let result = await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in }
        #expect(!result.creationAttempted && creates == 0)
    }

    @Test func invalidLateRowRejectsFullPlanBeforeMutation() async throws {
        let input = try JSONSerialization.data(withJSONObject: ["text": "valid"])
        var dataset = try source()
        dataset.visit = { handler in try await handler(0, input); try await handler(1, Data("{\"text\":null}".utf8)) }
        var embeddings = 0
        let operations = DatasetCloudOperations(embed: { texts, _ in embeddings += 1; return texts.map { _ in [Float(1), 0] } }, capacity: { budget }, create: { _, _ in Issue.record("Unexpected create") }, verify: { _, _ in }, write: { _, _ in })
        do { _ = try await DatasetCloudRunner.prepare(source: dataset, field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: budget, operations: operations); Issue.record("Expected missing field") }
        catch { #expect(embeddings == 0) }
    }

    @Test func quotaFailurePreservesAcknowledgedPartialResultWithoutRetry() async throws {
        var writes = 0
        var created = ""
        let operations = DatasetCloudOperations(embed: { texts, _ in texts.map { _ in [Float(1), 0] } }, capacity: { budget }, create: { name, _ in created = name }, verify: { _, _ in }, write: { _, _ in
            writes += 1
            if writes == 2 { throw DatasetBenchmarkError.invalid("Cloud quota") }
        })
        let plan = try await DatasetCloudRunner.prepare(source: source(), field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: budget, operations: operations)
        let result = await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in }
        #expect(!result.completed && result.creationAttempted && result.collection == created)
        #expect(result.acknowledgedPoints == 16 && writes == 2 && result.message.contains("quota"))
    }

    @Test func changedDocumentDimensionsAndVerificationFailurePreventWrites() async throws {
        for failVerification in [false, true] {
            var calls = 0
            var creates = 0
            let operations = DatasetCloudOperations(embed: { texts, _ in
                calls += 1
                return texts.map { _ in !failVerification && calls > 2 ? [Float(1), 0, 0] : [Float(1), 0] }
            }, capacity: { budget }, create: { _, _ in creates += 1 }, verify: { _, _ in throw DatasetBenchmarkError.invalid("Wrong caps") }, write: { _, _ in Issue.record("Unexpected write") })
            let plan = try await DatasetCloudRunner.prepare(source: source(), field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: budget, operations: operations)
            let result = await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in }
            #expect(!result.completed && result.acknowledgedPoints == 0)
            #expect(creates == (failVerification ? 1 : 0))
        }
    }

    @Test func leastFreeNodeAndIncompleteMetricsNeverUseClusterSum() throws {
        let samples = PrometheusText.samples(in: """
        container_memory_working_set_bytes{namespace="test",pod="a",container="qdrant"} 100
        container_memory_working_set_bytes{namespace="test",pod="b",container="qdrant"} 700
        kube_pod_container_resource_limits{namespace="test",pod="a",container="qdrant",resource="memory"} 1000
        kube_pod_container_resource_limits{namespace="test",pod="b",container="qdrant",resource="memory"} 1000
        kubelet_volume_stats_used_bytes{namespace="test",persistentvolumeclaim="a"} 100
        kubelet_volume_stats_capacity_bytes{namespace="test",persistentvolumeclaim="a"} 2000
        kubelet_volume_stats_used_bytes{namespace="test",persistentvolumeclaim="b"} 1500
        kubelet_volume_stats_capacity_bytes{namespace="test",persistentvolumeclaim="b"} 2000
        """)
        let available = try DatasetCloudQdrant.capacity(samples: samples, tier: .standard)
        #expect(available.ram == 100 && available.disk == 100)
        #expect(throws: DatasetBenchmarkError.self) { _ = try DatasetCloudQdrant.capacity(samples: Array(samples.dropLast()), tier: .standard) }
    }

    @Test func creationAndVerificationRequireExplicitStorageAndByteGuards() throws {
        let estimate = DatasetCloudEstimate(points: 10, payloadBytes: 5000, dimensions: 384)
        let body = DatasetCloudQdrant.createBody(estimate)
        let strict = try #require(body["strict_mode_config"] as? [String: Any])
        #expect(strict["enabled"] as? Bool == true)
        #expect(strict["max_collection_vector_size_bytes"] as? Int == estimate.vectorCap)
        let params: [String: Any] = ["vectors": body["vectors"]!, "payload": body["payload"]!, "shard_number": 1, "replication_factor": 1]
        let config: [String: Any] = ["params": params, "hnsw_config": body["hnsw_config"]!, "strict_mode_config": strict]
        try DatasetCloudQdrant.verify(JSONSerialization.data(withJSONObject: ["result": ["config": config]]), estimate: estimate)
        var bad = config
        bad.removeValue(forKey: "strict_mode_config")
        #expect(throws: DatasetBenchmarkError.self) { try DatasetCloudQdrant.verify(JSONSerialization.data(withJSONObject: ["result": ["config": bad]]), estimate: estimate) }
    }
}
