import Foundation
import Testing
@testable import Chunky

@MainActor
struct DatasetCloudIngestTests {
    let budget = DatasetCloudBudget(tier: .free, ram: 700_000_000, disk: 3_000_000_000)

    @Test func cloudOllamaRequestDisablesTruncationWithoutChangingOtherCallers() throws {
        let fullText = String(repeating: "Unicode🙂", count: 1000)
        let strict = OllamaService.EmbeddingRequest(model: "fixture", input: [fullText], truncate: false)
        let legacy = OllamaService.EmbeddingRequest(model: "fixture", input: [fullText])
        let strictJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(strict)) as? [String: Any])
        let legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(strictJSON["truncate"] as? Bool == false)
        #expect(strictJSON["input"] as? [String] == [fullText])
        #expect(legacyJSON["truncate"] == nil)
    }

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

    @Test func cancelledImportStopsAfterAcknowledgedBatchAndDoesNotReportSuccess() async throws {
        var writes = 0
        let operations = DatasetCloudOperations(embed: { texts, _ in texts.map { _ in [Float(1), 0] } }, capacity: { budget }, create: { _, _ in }, verify: { _, _ in }, write: { _, _ in
            writes += 1
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let plan = try await DatasetCloudRunner.prepare(source: source(), field: "text", chunkBytes: 512, backend: "ollama", model: "fixture", budget: budget, operations: operations)
        let work = Task { await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in } }
        let result = await work.value
        #expect(!result.completed && result.acknowledgedPoints == 16 && writes == 1)
        #expect(result.message.contains("Cancelled"))
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

    @Test func curatedVectorsUseDeclaredColumnWithoutDocumentEmbeddingOrChunking() async throws {
        let profile = DatasetCloudEmbeddingProfile.dbpedia
        let vector = [Float(1)] + Array(repeating: Float(0), count: profile.dimensions - 1)
        let original = String(repeating: "Original unmodified input. ", count: 100)
        let data = try JSONSerialization.data(withJSONObject: ["_id": "fixture-id", profile.textField: original, profile.vectorField: vector, "openai": [1, 2]])
        let dataset = DatasetCloudSource(datasetID: profile.datasetID, revision: profile.revision, config: profile.config, split: profile.split, sha256: String(repeating: "b", count: 64), rows: 1, visit: { handler in try await handler(0, data) })
        var probes = 0
        var uploaded: [ChunkPoint] = []
        let operations = DatasetCloudOperations(embed: { _, _ in Issue.record("No generic document/query embedding for a curated profile"); return [] }, capacity: { budget }, create: { _, _ in }, verify: { _, _ in }, write: { _, points in uploaded += points }, preembeddedQuery: { requested, _ in
            #expect(requested == profile)
            probes += 1
            return vector
        })
        let plan = try await DatasetCloudRunner.prepare(source: dataset, field: "ignored", chunkBytes: 512, backend: profile.backend, model: profile.model, budget: budget, preembedded: true, operations: operations)
        #expect(plan.field == profile.textField && plan.chunkBytes == 0 && plan.estimate.points == 1)
        let result = await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in }
        #expect(result.completed && probes == 2 && uploaded.count == 1)
        #expect(uploaded[0].text == original && uploaded[0].vector == vector)
        #expect(uploaded[0].metadata["dataset_embedding_profile"] == profile.id)
        #expect(result.embeddingProfile == profile.id)
    }

    @Test func unknownPreembeddedSourceAndWrongConfiguredModelRejectBeforeProbeOrMutation() async throws {
        let operations = DatasetCloudOperations(embed: { _, _ in Issue.record("Unexpected embedding"); return [] }, capacity: { budget }, create: { _, _ in Issue.record("Unexpected create") }, verify: { _, _ in }, write: { _, _ in }, preembeddedQuery: { _, _ in Issue.record("Unexpected probe"); return [] })
        for unknown in [false, true] {
            let profile = DatasetCloudEmbeddingProfile.dbpedia
            var dataset = try source()
            if !unknown { dataset.datasetID = profile.datasetID; dataset.revision = profile.revision; dataset.config = profile.config; dataset.split = profile.split }
            do {
                _ = try await DatasetCloudRunner.prepare(source: dataset, field: "text", chunkBytes: 512, backend: "openai", model: "another-1536-model", budget: budget, preembedded: true, operations: operations)
                Issue.record("Expected identity rejection")
            } catch { }
        }
    }

    @Test func restCreationConflictHasNoFallbackAndUploadsRequireCompletedAcknowledgement() async throws {
        let fixture = DatasetCloudHTTPFixture()
        let client = DatasetCloudQdrant(baseURL: "https://fixture.invalid:6333", apiKey: "fixture-key", tier: .free, transport: fixture)
        let name = DatasetBenchmarkSafety.collectionName()
        let estimate = DatasetCloudEstimate(points: 1, payloadBytes: 1000, dimensions: 2)
        fixture.respond(status: 409, body: Data("{}".utf8))
        do { try await client.create(name: name, estimate: estimate); Issue.record("Expected conflict") } catch { }
        #expect(fixture.calls.count == 1)
        fixture.respond(status: 200, body: Data("{\"result\":{\"status\":\"acknowledged\"}}".utf8))
        let point = ChunkPoint(id: UUID().uuidString, vector: [1, 0], text: "fixture", source: "hf://fixture", metadata: ["embedding_model": "fixture"])
        do { try await client.write(name: name, points: [point]); Issue.record("Expected incomplete acknowledgement") } catch { }
        fixture.respond(status: 200, body: Data("{\"result\":{\"status\":\"completed\"}}".utf8))
        try await client.write(name: name, points: [point])
        let calls = fixture.calls
        #expect(calls.count == 3)
        #expect(calls[2].url.host == "fixture.invalid" && calls[2].url.port == 6333)
        #expect(calls[2].url.query == "wait=true" && calls[2].method == "PUT" && calls[2].key == "fixture-key")
        let body = try #require(calls[2].body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let points = try #require(object["points"] as? [[String: Any]])
        #expect(points.count == 1 && points[0]["id"] as? String == point.id)
        let oversized = ChunkPoint(id: UUID().uuidString, vector: [1, 0], text: String(repeating: "x", count: 16 * 1024 * 1024), source: "fixture")
        do { try await client.write(name: name, points: [oversized]); Issue.record("Expected encoded byte limit") } catch { }
        #expect(fixture.calls.count == 3)
    }

    @Test func verifiedCPUPlanSurvivesPartialUploadAndNeverOverwritesSavedPlans() async throws {
        let suite = "dataset-partial-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vector = [Float(1)] + Array(repeating: Float(0), count: FastEmbedService.dimensions - 1)
        var writes = 0
        let operations = DatasetCloudOperations(embed: { texts, _ in texts.map { _ in vector } }, capacity: { budget }, create: { _, _ in }, verify: { name, estimate in
            try DatasetCloudRunner.recordVerifiedCollection(name: name, estimate: estimate, backend: "fastembed", model: FastEmbedService.model, defaults: defaults)
        }, write: { _, _ in writes += 1; if writes == 2 { throw DatasetBenchmarkError.invalid("Quota") } })
        let plan = try await DatasetCloudRunner.prepare(source: source(), field: "text", chunkBytes: 512, backend: "fastembed", model: FastEmbedService.model, budget: budget, operations: operations)
        let result = await DatasetCloudRunner.run(plan: plan, operations: operations) { _ in }
        #expect(!result.completed && result.acknowledgedPoints == 16)
        try FastEmbedCollectionIdentity.validate(collection: result.collection, backend: "fastembed", model: FastEmbedService.model, defaults: defaults)
        let saved = try #require(CollectionPlanStore.load(name: result.collection, defaults: defaults))
        #expect(saved.target == .qdrantCloud && saved.onDisk && saved.payloadIndexes.isEmpty)
        #expect(throws: DatasetBenchmarkError.self) { try DatasetCloudRunner.recordVerifiedCollection(name: result.collection, estimate: plan.estimate, backend: "ollama", model: "other", defaults: defaults) }
        #expect(CollectionPlanStore.load(name: result.collection, defaults: defaults) == saved)
    }
}

@MainActor
private final class DatasetCloudHTTPFixture: SnapshotTransport {
    struct Call: Sendable { var method: String; var url: URL; var key: String; var body: Data? }
    var calls: [Call] = []
    var status = 200
    var response = Data()
    func respond(status: Int, body: Data) { self.status = status; response = body }
    func send(method: String, url: URL, apiKey: String, body: Data?) async throws -> (status: Int, body: Data) {
        calls.append(Call(method: method, url: url, key: apiKey, body: body))
        return (status, response)
    }
    func download(url: URL, apiKey: String, to destination: URL) async throws { throw DatasetBenchmarkError.invalid("Unexpected download") }
    func upload(url: URL, apiKey: String, file: URL) async throws -> (status: Int, body: Data) { throw DatasetBenchmarkError.invalid("Unexpected upload") }
}
