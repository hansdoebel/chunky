import Foundation
import Testing
import QdrantCore
import QdrantGRPC

@Suite("Chunky client compatibility integration", .serialized)
struct ChunkyCompatibilityIntegrationTests {
    @Test func hybridIngestMetadataFilteringAndSnapshot() async throws {
        let port = Int(ProcessInfo.processInfo.environment["QDRANT_GRPC_PORT"] ?? "6334") ?? 6334
        let client = try await QdrantGRPCClient(host: "127.0.0.1", port: port, useTLS: false)
        defer { client.close() }
        let name = "chunky-compat-" + UUID().uuidString.lowercased()
        try await client.collections.create(name: name, vectors: .named(["dense": VectorConfig(size: 3, distance: .cosine)]), sparseVectors: ["sparse": SparseVectorParams(modifier: .idf)], onDiskPayload: true, quantizationConfig: .scalar(quantile: nil, alwaysRam: false))
        do {
            let info = try await client.collections.get(name: name)
            #expect(info.vectorSize == 3)
            #expect(info.vectorName == "dense")
            try await client.points.createFieldIndex(collection: name, fieldName: "library_id", fieldType: .keyword, isTenant: true)
            let point = Point(id: .integer(1), vector: .namedWithSparse(dense: ["dense": [1, 0, 0]], sparse: ["sparse": SparseVector(indices: [7], values: [1])]), payload: ["library_id": .string("fixture")])
            try await client.points.upsert(collection: name, points: [point], wait: true)
            let filter = Filter(must: [.field(key: "library_id", match: .keyword("fixture"))])
            let dense = try await client.points.search(collection: name, vector: [1, 0, 0], filter: filter, vectorName: "dense")
            #expect(dense.count == 1)
            let hybrid = try await client.points.query(collection: name, query: .fusion(.rrf), prefetch: [PrefetchQuery(query: .nearest(.dense([1, 0, 0])), using: "dense", filter: filter, limit: 10), PrefetchQuery(query: .nearest(.sparse(indices: [7], values: [1])), using: "sparse", filter: filter, limit: 10)], limit: 10)
            #expect(hybrid.count == 1)
            let excluded = try await client.points.search(collection: name, vector: [1, 0, 0], filter: Filter(must: [.field(key: "library_id", match: .keyword("other"))]), vectorName: "dense")
            #expect(excluded.isEmpty)
            let snapshot = try await client.snapshots.create(collection: name)
            let snapshots = try await client.snapshots.list(collection: name)
            #expect(snapshots.contains { $0.name == snapshot.name })
            try await client.snapshots.delete(collection: name, snapshot: snapshot.name)
        } catch {
            try? await client.collections.delete(name: name)
            throw error
        }
        try await client.collections.delete(name: name)
    }
}
