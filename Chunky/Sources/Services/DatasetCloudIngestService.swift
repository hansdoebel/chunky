import Foundation

@MainActor
struct DatasetCloudOperations {
    var embed: ([String], Bool) async throws -> [[Float]]
    var capacity: () async throws -> DatasetCloudBudget
    var create: (String, DatasetCloudEstimate) async throws -> Void
    var verify: (String, DatasetCloudEstimate) async throws -> Void
    var write: (String, [ChunkPoint]) async throws -> Void
}

@MainActor
enum DatasetCloudRunner {
    static func prepare(source: DatasetCloudSource, field: String, chunkBytes: Int, backend: String, model: String, budget: DatasetCloudBudget, operations: DatasetCloudOperations) async throws -> DatasetCloudPlan {
        try budget.validate()
        guard ["ollama", "openai", "fastembed"].contains(backend), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatasetBenchmarkError.invalid("Select a supported embedding provider and model in Preferences.")
        }
        let planner = DatasetCloudPlanner()
        try await source.visit { row, data in
            try await planner.add(row: row, data: data, source: source, field: field, chunkBytes: chunkBytes, backend: backend, model: model)
        }
        let (points, bytes, firstText) = await planner.summary()
        guard points > 0 else { throw DatasetBenchmarkError.invalid("The selected field contains no chunks.") }
        try Task.checkCancellation()
        let document = try await operations.embed([firstText], false)
        let dimensions = try DatasetBenchmarkSafety.validateVectors(document, count: 1)
        let query = try await operations.embed([firstText], true)
        _ = try DatasetBenchmarkSafety.validateVectors(query, count: 1, dimensions: dimensions)
        let estimate = DatasetCloudEstimate(points: points, payloadBytes: bytes, dimensions: dimensions)
        try budget.require(estimate)
        try await operations.capacity().require(estimate)
        try Task.checkCancellation()
        return DatasetCloudPlan(source: source, field: field, chunkBytes: chunkBytes, backend: backend, model: model, estimate: estimate, budget: budget)
    }

    static func run(plan: DatasetCloudPlan, operations: DatasetCloudOperations, progress: @escaping (Int) -> Void) async -> DatasetCloudResult {
        let session = DatasetCloudSession(plan: plan, operations: operations, progress: progress)
        do {
            try Task.checkCancellation()
            try plan.budget.require(plan.estimate)
            try await operations.capacity().require(plan.estimate)
            try await plan.source.visit { row, data in
                try await session.consume(row: row, data: data)
            }
            try await session.flush()
            try Task.checkCancellation()
            guard session.result.acknowledgedPoints == plan.estimate.points else {
                throw DatasetBenchmarkError.invalid("The verified source no longer matches the prepared plan.")
            }
            session.result.completed = true
            session.result.message = "Completed. All planned points were acknowledged."
        } catch {
            session.result.message = error is CancellationError ? "Cancelled. Any partial collection is preserved." : error.localizedDescription
        }
        return session.result
    }
}

@MainActor
private final class DatasetCloudSession {
    let plan: DatasetCloudPlan
    let operations: DatasetCloudOperations
    let progress: (Int) -> Void
    var batch: [DatasetCloudChunk] = []
    var uploadedPayload = 0
    var result: DatasetCloudResult

    init(plan: DatasetCloudPlan, operations: DatasetCloudOperations, progress: @escaping (Int) -> Void) {
        self.plan = plan
        self.operations = operations
        self.progress = progress
        result = DatasetCloudResult(datasetID: plan.source.datasetID, revision: plan.source.revision, sha256: plan.source.sha256, collection: DatasetBenchmarkSafety.collectionName(), plannedPoints: plan.estimate.points)
    }

    func consume(row: Int, data: Data) async throws {
        let chunks = try await Self.chunks(row: row, data: data, field: plan.field, limit: plan.chunkBytes)
        for chunk in chunks {
            try Task.checkCancellation()
            batch.append(chunk)
            if batch.count == 16 { try await flush() }
        }
    }

    @concurrent nonisolated static func chunks(row: Int, data: Data, field: String, limit: Int) async throws -> [DatasetCloudChunk] {
        try DatasetCloudChunk.split(row: row, data: data, field: field, maximumBytes: limit)
    }

    func flush() async throws {
        guard !batch.isEmpty else { return }
        try Task.checkCancellation()
        let remaining = DatasetCloudEstimate(points: plan.estimate.points - result.acknowledgedPoints, payloadBytes: max(0, plan.estimate.payloadBytes - uploadedPayload), dimensions: plan.estimate.dimensions)
        try await operations.capacity().require(remaining)
        let vectors = try await operations.embed(batch.map(\.text), false)
        _ = try DatasetBenchmarkSafety.validateVectors(vectors, count: batch.count, dimensions: plan.estimate.dimensions)
        try Task.checkCancellation()
        try await operations.capacity().require(remaining)
        if !result.creationAttempted {
            let query = try await operations.embed([batch[0].text], true)
            _ = try DatasetBenchmarkSafety.validateVectors(query, count: 1, dimensions: plan.estimate.dimensions)
            try Task.checkCancellation()
            result.creationAttempted = true
            try await operations.create(result.collection, plan.estimate)
            try await operations.verify(result.collection, plan.estimate)
        }
        let points = batch.enumerated().map { index, chunk in
            var payload = chunk.payload(source: plan.source, field: plan.field, backend: plan.backend, model: plan.model, dimensions: plan.estimate.dimensions)
            let text = payload.removeValue(forKey: "text") ?? ""
            let source = payload.removeValue(forKey: "source") ?? ""
            return ChunkPoint(id: chunk.id(source: plan.source, field: plan.field, maximumBytes: plan.chunkBytes), vector: vectors[index], text: text, source: source, metadata: payload)
        }
        try await operations.write(result.collection, points)
        for chunk in batch {
            uploadedPayload += try chunk.budgetedPayloadBytes(source: plan.source, field: plan.field, backend: plan.backend, model: plan.model)
        }
        result.acknowledgedPoints += batch.count
        progress(result.acknowledgedPoints)
        batch.removeAll(keepingCapacity: true)
    }
}

extension DatasetCloudSource {
    init(snapshot: DatasetValidatedSnapshot) {
        let manifest = snapshot.manifest
        self.init(datasetID: manifest.datasetID, revision: manifest.revision, config: manifest.config, split: manifest.split, sha256: manifest.sha256, rows: manifest.rowCount, visit: { handler in try await snapshot.forEachRow(handler) })
    }
}
