import Foundation
import Testing

@testable import QdrantCore
@testable import QdrantREST

@Suite("Qdrant Cloud Validation", .serialized)
struct CloudValidationTests {

    private func createClient() throws -> QdrantRESTClient {
        let config = try IntegrationTestConfig.load()

        guard let url = URL(string: config.url) else {
            throw TestError.invalidURL
        }

        let host = url.host ?? "localhost"
        let port = url.port ?? 6333
        let useTLS = url.scheme == "https"

        return try QdrantRESTClient(
            host: host,
            port: port,
            useTLS: useTLS,
            apiKey: config.apiKey
        )
    }

    enum TestError: Error {
        case invalidURL
    }

    @Test("1. Connectivity check - verify connection and authentication")
    func connectivityCheck() async throws {
        let client = try createClient()

        let telemetry = try await client.telemetry()

        #expect(telemetry.result?.app?.name == "qdrant")
        #expect(telemetry.result?.app?.version != nil)
    }

    @Test("2. Collection lifecycle - create, verify, delete")
    func collectionLifecycle() async throws {
        let client = try createClient()
        let collectionName = "cloud-validation-\(UUID().uuidString.prefix(8))"

        try await client.collections.create(
            name: collectionName,
            vectorSize: 4,
            distance: .cosine
        )

        let exists = try await client.collections.exists(name: collectionName)
        #expect(exists == true)

        let info = try await client.collections.get(name: collectionName)
        #expect(info.status == .green)

        try await client.collections.delete(name: collectionName)

        let existsAfter = try await client.collections.exists(name: collectionName)
        #expect(existsAfter == false)
    }

    @Test("3. Points upsert and get")
    func pointsUpsertAndGet() async throws {
        let client = try createClient()
        let collectionName = "cloud-validation-\(UUID().uuidString.prefix(8))"

        try await client.collections.create(
            name: collectionName,
            vectorSize: 4,
            distance: .cosine
        )

        let points = [
            Point(
                id: .integer(1),
                vector: [0.1, 0.2, 0.3, 0.4],
                payload: ["name": .string("first"), "value": .integer(100)]
            ),
            Point(
                id: .integer(2),
                vector: [0.5, 0.6, 0.7, 0.8],
                payload: ["name": .string("second"), "value": .integer(200)]
            ),
        ]

        try await client.points.upsert(collection: collectionName, points: points, wait: true)

        let retrieved = try await client.points.get(
            collection: collectionName,
            ids: [.integer(1), .integer(2)],
            withPayload: true,
            withVectors: true
        )

        #expect(retrieved.count == 2)

        let point1 = retrieved.first {
            if case .integer(let id) = $0.id { return id == 1 }
            return false
        }
        #expect(point1?.payload?["name"]?.stringValue == "first")
        #expect(point1?.payload?["value"]?.integerValue == 100)

        try await client.collections.delete(name: collectionName)
    }

    @Test("4. Vector search")
    func vectorSearch() async throws {
        let client = try createClient()
        let collectionName = "cloud-validation-\(UUID().uuidString.prefix(8))"

        try await client.collections.create(
            name: collectionName,
            vectorSize: 4,
            distance: .cosine
        )

        let points = [
            Point(
                id: .integer(1), vector: [1.0, 0.0, 0.0, 0.0], payload: ["name": .string("north")]),
            Point(
                id: .integer(2), vector: [0.0, 1.0, 0.0, 0.0], payload: ["name": .string("east")]),
            Point(id: .integer(3), vector: [0.0, 0.0, 1.0, 0.0], payload: ["name": .string("up")]),
        ]

        try await client.points.upsert(collection: collectionName, points: points, wait: true)

        let results = try await client.points.search(
            collection: collectionName,
            vector: [0.99, 0.01, 0.0, 0.0],
            limit: 2,
            withPayload: true
        )

        #expect(results.count == 2)

        if case .integer(let id) = results[0].id {
            #expect(id == 1)
        }
        #expect(results[0].payload?["name"]?.stringValue == "north")

        try await client.collections.delete(name: collectionName)
    }

    @Test("5. Payload operations")
    func payloadOperations() async throws {
        let client = try createClient()
        let collectionName = "cloud-validation-\(UUID().uuidString.prefix(8))"

        try await client.collections.create(
            name: collectionName,
            vectorSize: 4,
            distance: .cosine
        )

        let points = [
            Point(id: .integer(1), vector: [0.1, 0.2, 0.3, 0.4])
        ]

        try await client.points.upsert(collection: collectionName, points: points, wait: true)

        try await client.points.setPayload(
            collection: collectionName,
            ids: [.integer(1)],
            payload: ["category": .string("test"), "score": .double(95.5)],
            wait: true
        )

        let retrieved = try await client.points.get(
            collection: collectionName,
            ids: [.integer(1)],
            withPayload: true
        )

        #expect(retrieved[0].payload?["category"]?.stringValue == "test")
        #expect(retrieved[0].payload?["score"]?.doubleValue == 95.5)

        try await client.collections.delete(name: collectionName)
    }
}
