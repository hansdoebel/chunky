import Foundation

@MainActor
struct DatasetBenchmarkOperations {
    var embed: ([String], Bool) async throws -> [[Float]]
    var create: (String, Int) async throws -> Void
    var verify: (String, Int) async throws -> Void
    var write: (String, [ChunkPoint]) async throws -> Void
}

@MainActor
enum DatasetBenchmarkRunner {
    static func run(corpus: DatasetBenchmarkCorpus, backend: String, model: String, collection: String?, production: String, operations: DatasetBenchmarkOperations, progress: (String) -> Void) async throws -> DatasetBenchmarkReport {
        guard ["ollama", "openai", "fastembed"].contains(backend), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !corpus.texts.isEmpty, corpus.texts.count <= 1000 else {
            throw DatasetBenchmarkError.invalid("Select a supported embedding provider, model and bounded dataset rows.")
        }
        if let collection { try DatasetBenchmarkSafety.validateCollection(collection, production: production) }
        try Task.checkCancellation()
        progress("Warming the selected document and query encoder…")
        let warmupStart = ContinuousClock.now
        let warmup = try await operations.embed([corpus.texts[0]], false)
        let dimensions = try DatasetBenchmarkSafety.validateVectors(warmup, count: 1)
        let query = try await operations.embed([corpus.texts[0]], true)
        _ = try DatasetBenchmarkSafety.validateVectors(query, count: 1, dimensions: dimensions)
        let warmupSeconds = seconds(warmupStart.duration(to: .now))
        try Task.checkCancellation()
        let embeddingStart = ContinuousClock.now
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: corpus.texts.count, by: 16) {
            try Task.checkCancellation()
            let texts = Array(corpus.texts[start..<min(start + 16, corpus.texts.count)])
            let batch = try await operations.embed(texts, false)
            _ = try DatasetBenchmarkSafety.validateVectors(batch, count: texts.count, dimensions: dimensions)
            vectors += batch
            progress("Embedded \(vectors.count) of \(corpus.texts.count) rows.")
        }
        let embeddingSeconds = seconds(embeddingStart.duration(to: .now))
        try Task.checkCancellation()
        var indexingSeconds: Double?
        if let collection {
            progress("Creating new test collection \(collection)…")
            let indexingStart = ContinuousClock.now
            try await operations.create(collection, dimensions)
            try await operations.verify(collection, dimensions)
            for start in stride(from: 0, to: vectors.count, by: 32) {
                try Task.checkCancellation()
                let end = min(start + 32, vectors.count)
                let points = (start..<end).map { corpus.point(index: $0, vector: vectors[$0], backend: backend, model: model) }
                try await operations.write(collection, points)
                progress("Indexed \(end) of \(vectors.count) rows in \(collection).")
            }
            indexingSeconds = seconds(indexingStart.duration(to: .now))
        }
        try Task.checkCancellation()
        return DatasetBenchmarkReport(createdAt: Date(), datasetID: corpus.datasetID, revision: corpus.revision, config: corpus.config, split: corpus.split, sha256: corpus.sha256, textField: corpus.textField, rows: corpus.texts.count, backend: backend, model: model, dimensions: dimensions, warmupSeconds: warmupSeconds, embeddingSeconds: embeddingSeconds, indexingSeconds: indexingSeconds, collection: collection)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
