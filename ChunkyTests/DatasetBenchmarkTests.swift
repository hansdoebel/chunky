import Foundation
import Testing
@testable import Chunky

@MainActor
struct DatasetBenchmarkTests {
    private func corpus(_ count: Int = 3) -> DatasetBenchmarkCorpus {
        DatasetBenchmarkCorpus(datasetID: "fixture/corpus", revision: String(repeating: "a", count: 40), config: "corpus", split: "test", sha256: String(repeating: "b", count: 64), textField: "text", texts: (0..<count).map { "Fixture row \($0)" })
    }

    @Test func warmupIsSeparateAndEmbeddingOnlyDoesNotTouchQdrant() async throws {
        var calls: [(Int, Bool)] = []
        var mutations = 0
        let operations = DatasetBenchmarkOperations(embed: { texts, query in
            calls.append((texts.count, query))
            return texts.map { _ in [Float(1), 0] }
        }, create: { _, _ in mutations += 1 }, verify: { _, _ in mutations += 1 }, write: { _, _ in mutations += 1 })
        let report = try await DatasetBenchmarkRunner.run(corpus: corpus(), backend: "ollama", model: "fixture-model", collection: nil, production: "documents", operations: operations) { _ in }
        #expect(calls.map(\.0) == [1, 1, 3])
        #expect(calls.map(\.1) == [false, true, false])
        #expect(mutations == 0)
        #expect(report.rows == 3 && report.dimensions == 2)
        #expect(report.collection == nil && report.indexingSeconds == nil)
        #expect(report.warmupSeconds >= 0 && report.embeddingSeconds >= 0)
        #expect(report.revision == corpus().revision && report.sha256 == corpus().sha256)
    }

    @Test func incompatibleQueryOrInvalidTimedVectorsNeverCreateCollection() async {
        for invalidQuery in [true, false] {
            var calls = 0
            var creates = 0
            let operations = DatasetBenchmarkOperations(embed: { texts, query in
                calls += 1
                if invalidQuery && query { return [[1, 0, 0]] }
                if !invalidQuery && calls == 3 { return texts.map { _ in [Float.nan, 0] } }
                return texts.map { _ in [Float(1), 0] }
            }, create: { _, _ in creates += 1 }, verify: { _, _ in }, write: { _, _ in Issue.record("Unexpected write") })
            do {
                _ = try await DatasetBenchmarkRunner.run(corpus: corpus(), backend: "openai", model: "fixture", collection: DatasetBenchmarkSafety.collectionName(), production: "documents", operations: operations) { _ in }
                Issue.record("Expected validation failure")
            } catch { #expect(creates == 0) }
        }
    }

    @Test func newCollectionIsVerifiedBeforeWritingAndCarriesProvenance() async throws {
        let name = DatasetBenchmarkSafety.collectionName()
        var order: [String] = []
        var saved: [ChunkPoint] = []
        let input = corpus()
        let operations = DatasetBenchmarkOperations(embed: { texts, _ in texts.map { _ in [Float(1), 0] } }, create: { collection, dimensions in
            #expect(collection == name && dimensions == 2)
            order.append("create")
        }, verify: { _, _ in order.append("verify") }, write: { _, points in
            order.append("write")
            saved += points
        })
        let report = try await DatasetBenchmarkRunner.run(corpus: input, backend: "ollama", model: "fixture", collection: name, production: "documents", operations: operations) { _ in }
        #expect(order == ["create", "verify", "write"])
        #expect(saved.count == 3 && Set(saved.map(\.id)).count == 3)
        #expect(saved.allSatisfy { UUID(uuidString: $0.id) != nil })
        #expect(saved[0].metadata["dataset_sha256"] == input.sha256)
        #expect(saved[0].metadata["chunky_test_data"] == "true")
        #expect(saved[0].metadata["embedding_model"] == "fixture")
        #expect(report.collection == name && report.indexingSeconds != nil)
    }

    @Test func creationRefusalAndVerificationFailurePreventWrites() async {
        for failCreation in [true, false] {
            var writes = 0
            var verified = false
            let operations = DatasetBenchmarkOperations(embed: { texts, _ in texts.map { _ in [Float(1), 0] } }, create: { _, _ in
                if failCreation { throw DatasetBenchmarkError.invalid("Already exists") }
            }, verify: { _, _ in
                verified = true
                throw DatasetBenchmarkError.invalid("Wrong dimensions")
            }, write: { _, _ in writes += 1 })
            do {
                _ = try await DatasetBenchmarkRunner.run(corpus: corpus(), backend: "ollama", model: "fixture", collection: DatasetBenchmarkSafety.collectionName(), production: "documents", operations: operations) { _ in }
                Issue.record("Expected refusal")
            } catch {
                #expect(writes == 0)
                #expect(verified == !failCreation)
            }
        }
    }

    @Test func cancellationAfterEmbeddingPreventsCollectionCreation() async {
        var creates = 0
        let operations = DatasetBenchmarkOperations(embed: { texts, query in
            if query { withUnsafeCurrentTask { $0?.cancel() } }
            return texts.map { _ in [Float(1), 0] }
        }, create: { _, _ in creates += 1 }, verify: { _, _ in }, write: { _, _ in Issue.record("Unexpected write") })
        let input = corpus()
        let task = Task { try await DatasetBenchmarkRunner.run(corpus: input, backend: "ollama", model: "fixture", collection: DatasetBenchmarkSafety.collectionName(), production: "documents", operations: operations) { _ in } }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(creates == 0)
    }

    @Test func partialUploadFailureDoesNotReportSuccess() async {
        var accepted = 0
        let operations = DatasetBenchmarkOperations(embed: { texts, _ in texts.map { _ in [Float(1), 0] } }, create: { _, _ in }, verify: { _, _ in }, write: { _, points in
            if accepted > 0 { throw DatasetBenchmarkError.invalid("Fixture transport failure") }
            accepted += points.count
        })
        do {
            _ = try await DatasetBenchmarkRunner.run(corpus: corpus(33), backend: "ollama", model: "fixture", collection: DatasetBenchmarkSafety.collectionName(), production: "documents", operations: operations) { _ in }
            Issue.record("Expected failure")
        } catch { #expect(accepted == 32) }
    }

    @Test func productionNamesAndMalformedVectorsAreRejected() {
        let name = DatasetBenchmarkSafety.collectionName()
        #expect(throws: DatasetBenchmarkError.self) { try DatasetBenchmarkSafety.validateCollection(name, production: name) }
        #expect(throws: DatasetBenchmarkError.self) { try DatasetBenchmarkSafety.validateCollection("documents", production: "other") }
        #expect(throws: DatasetBenchmarkError.self) { try DatasetBenchmarkSafety.validateCollection("chunky-dataset-test-arbitrary", production: "documents") }
        for vectors: [[Float]] in [[], [[]], [[0, 0]], [[1, .infinity]], [[1, 0], [1]]] {
            #expect(throws: DatasetBenchmarkError.self) { try DatasetBenchmarkSafety.validateVectors(vectors, count: 1) }
        }
    }

    @Test func cancelledBackgroundInspectionDoesNotReadFiles() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DatasetBenchmarkLoader.inspect(URL(fileURLWithPath: "/missing-snapshot-fixture"))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation before file access") }
        catch { #expect(error is CancellationError) }
    }

    @Test func snapshotFieldMappingRejectsMissingOversizedOrChangedRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("{\"text\":\"first\",\"id\":1}\n{\"text\":\"second\",\"id\":2}\n".utf8)
        let manifest = DatasetManifest(schemaVersion: 1, datasetID: "fixture/corpus", revision: String(repeating: "a", count: 40), config: "default", split: "test", sourceURL: "https://huggingface.co/datasets/fixture/corpus", license: nil, downloadedAt: Date(), rowCount: 2, requestedRows: 2, totalRows: 2, sha256: DatasetSnapshot.digest(data))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try data.write(to: directory.appendingPathComponent("rows.jsonl"))
        let (snapshot, fields) = try await DatasetBenchmarkLoader.inspect(directory)
        #expect(fields == ["text"])
        #expect(try await DatasetBenchmarkLoader.corpus(snapshot: snapshot, field: "text", limit: 1).texts == ["first"])
        #expect(try DatasetBenchmarkCorpus.load(snapshot: snapshot, field: "text", limit: 1).texts == ["first"])
        #expect(throws: DatasetBenchmarkError.self) { try DatasetBenchmarkCorpus.load(snapshot: snapshot, field: "id", limit: 2) }
        #expect(throws: DatasetBenchmarkError.self) { try DatasetBenchmarkCorpus.load(snapshot: snapshot, field: "text", limit: 1001) }
        try Data("{\"text\":\"tampered\"}\n".utf8).write(to: snapshot.rowsURL)
        #expect(throws: (any Error).self) { try DatasetBenchmarkCorpus.load(snapshot: snapshot, field: "text", limit: 1) }
    }
}
