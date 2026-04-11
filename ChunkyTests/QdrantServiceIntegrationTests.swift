import Foundation
import Testing

@testable import Chunky

/// Integration tests for QdrantService
/// These tests require a running Qdrant instance at localhost:6334
/// Run with: `docker run -p 6334:6334 qdrant/qdrant`
@MainActor
struct QdrantServiceIntegrationTests {

    // Test configuration - adjust for your environment
    static let testURL = "http://localhost:6334"
    static let testCollection = "chunky_test_collection_\(UUID().uuidString.prefix(8))"

    // MARK: - Connection Tests

    @Test(.disabled("Requires running Qdrant instance"))
    func connectToLocalQdrant() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = QdrantService()
        try await service.configure(url: Self.testURL, apiKey: nil)
        try await service.connect()

        #expect(service.isConnected == true)
        #expect(service.serverVersion != nil)

        await service.disconnect()
    }

    @Test(.disabled("Requires running Qdrant instance"))
    func connectionFailsWithInvalidURL() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = QdrantService()

        do {
            try await service.configure(url: "http://invalid-host:9999", apiKey: nil)
            try await service.connect()
            Issue.record("Expected connection to fail")
        } catch {
            #expect(service.isConnected == false)
        }
    }

    // MARK: - Collection Tests

    @Test(.disabled("Requires running Qdrant instance"))
    func createAndDeleteCollection() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection

        // Create collection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 384)

        // Verify it exists
        let exists = try await service.collectionExists(collectionName)
        #expect(exists == true)

        // Get info
        let info = try await service.getCollectionInfo(collectionName)
        #expect(info.name == collectionName)

        // List collections should include it
        let collections = try await service.listCollections()
        #expect(collections.contains(collectionName))

        // Delete collection
        try await service.deleteCollection(collectionName)

        // Verify it's gone
        let existsAfterDelete = try await service.collectionExists(collectionName)
        #expect(existsAfterDelete == false)

        await service.disconnect()
    }

    @Test(.disabled("Requires running Qdrant instance"))
    func createCollectionIfNeededIsIdempotent() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection

        // Create twice - should not throw
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 384)
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 384)

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    // MARK: - Points Tests

    @Test(.disabled("Requires running Qdrant instance"))
    func upsertAndLoadPoints() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 3)

        // Create test points
        let points = [
            ChunkPoint(
                id: "point-1",
                vector: [0.1, 0.2, 0.3],
                text: "First test document",
                source: "test.pdf",
                page: 1,
                headings: ["Chapter 1"]
            ),
            ChunkPoint(
                id: "point-2",
                vector: [0.4, 0.5, 0.6],
                text: "Second test document",
                source: "test.pdf",
                page: 2,
                headings: ["Chapter 2"]
            ),
        ]

        // Upsert points
        var progressUpdates: [UploadProgress] = []
        try await service.upsertPoints(
            collectionName: collectionName,
            points: points,
            batchSize: 10
        ) { progress in
            progressUpdates.append(progress)
        }

        #expect(!progressUpdates.isEmpty)

        // Load points back
        let loadedPoints = try await service.loadPoints(collectionName: collectionName, limit: 100)
        #expect(loadedPoints.count == 2)

        // Verify content
        let point1 = loadedPoints.first { $0.id == "point-1" }
        #expect(point1?.text == "First test document")
        #expect(point1?.source == "test.pdf")
        #expect(point1?.page == 1)

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    @Test(.disabled("Requires running Qdrant instance"))
    func deletePoints() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 3)

        // Add points
        let points = [
            ChunkPoint(
                id: "delete-1", vector: [0.1, 0.2, 0.3], text: "To delete", source: "file.txt"),
            ChunkPoint(id: "keep-1", vector: [0.4, 0.5, 0.6], text: "To keep", source: "file.txt"),
        ]
        try await service.upsertPoints(collectionName: collectionName, points: points)

        // Delete one point
        try await service.deletePoints(collectionName: collectionName, ids: ["delete-1"])

        // Verify only one remains
        let remaining = try await service.loadPoints(collectionName: collectionName)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == "keep-1")

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    @Test(.disabled("Requires running Qdrant instance"))
    func countPoints() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 3)

        // Add points
        let points = (0..<5).map { i in
            ChunkPoint(
                id: "count-\(i)",
                vector: [Float(i) * 0.1, Float(i) * 0.2, Float(i) * 0.3],
                text: "Document \(i)",
                source: "file.txt"
            )
        }
        try await service.upsertPoints(collectionName: collectionName, points: points)

        // Count
        let count = try await service.countPoints(collectionName: collectionName)
        #expect(count == 5)

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    // MARK: - Search Tests

    @Test(.disabled("Requires running Qdrant instance"))
    func searchSimilarVectors() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 3)

        // Add points with distinct vectors
        let points = [
            ChunkPoint(id: "near", vector: [0.9, 0.9, 0.9], text: "Near target", source: "a.txt"),
            ChunkPoint(
                id: "far", vector: [0.1, 0.1, 0.1], text: "Far from target", source: "b.txt"),
        ]
        try await service.upsertPoints(collectionName: collectionName, points: points)

        // Search for vector close to [1.0, 1.0, 1.0]
        let results = try await service.search(
            collectionName: collectionName,
            vector: [1.0, 1.0, 1.0],
            limit: 2
        )

        #expect(results.count == 2)
        #expect(results.first?.id == "near")  // Should be most similar
        #expect(results.first?.score ?? 0 > results.last?.score ?? 1)

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    @Test(.disabled("Requires running Qdrant instance"))
    func searchWithSourceFilter() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 3)

        // Add points from different sources
        let points = [
            ChunkPoint(id: "a1", vector: [0.9, 0.9, 0.9], text: "Doc A1", source: "source-a.txt"),
            ChunkPoint(id: "a2", vector: [0.8, 0.8, 0.8], text: "Doc A2", source: "source-a.txt"),
            ChunkPoint(
                id: "b1", vector: [0.95, 0.95, 0.95], text: "Doc B1", source: "source-b.txt"),
        ]
        try await service.upsertPoints(collectionName: collectionName, points: points)

        // Search with filter for source-a.txt
        let results = try await service.search(
            collectionName: collectionName,
            vector: [1.0, 1.0, 1.0],
            limit: 10,
            sourceFilter: "source-a.txt"
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.source == "source-a.txt" })

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    // MARK: - Sources Tests

    @Test(.disabled("Requires running Qdrant instance"))
    func getUniqueSources() async throws {
        guard #available(macOS 15.0, *) else { return }

        let service = try await createConnectedService()
        let collectionName = Self.testCollection
        try await service.createCollectionIfNeeded(name: collectionName, vectorSize: 3)

        // Add points from different sources
        let points = [
            ChunkPoint(id: "1", vector: [0.1, 0.1, 0.1], text: "A", source: "file1.pdf"),
            ChunkPoint(id: "2", vector: [0.2, 0.2, 0.2], text: "B", source: "file2.pdf"),
            ChunkPoint(id: "3", vector: [0.3, 0.3, 0.3], text: "C", source: "file1.pdf"),  // Duplicate source
        ]
        try await service.upsertPoints(collectionName: collectionName, points: points)

        // Get unique sources
        let sources = try await service.getSources(collectionName: collectionName)

        #expect(sources.count == 2)
        #expect(sources.contains("file1.pdf"))
        #expect(sources.contains("file2.pdf"))

        // Clean up
        try await service.deleteCollection(collectionName)
        await service.disconnect()
    }

    // MARK: - Helper Methods

    @available(macOS 15.0, *)
    private func createConnectedService() async throws -> QdrantService {
        let service = QdrantService()
        try await service.configure(url: Self.testURL, apiKey: nil)
        try await service.connect()
        return service
    }
}

// MARK: - Qdrant Cloud Integration Tests

@MainActor
struct QdrantCloudIntegrationTests {

    // Set these environment variables or modify for your Qdrant Cloud instance
    static var cloudURL: String? {
        ProcessInfo.processInfo.environment["QDRANT_CLOUD_URL"]
    }

    static var cloudAPIKey: String? {
        ProcessInfo.processInfo.environment["QDRANT_CLOUD_API_KEY"]
    }

    @Test(.disabled("Requires QDRANT_CLOUD_URL and QDRANT_CLOUD_API_KEY environment variables"))
    func connectToQdrantCloud() async throws {
        guard #available(macOS 15.0, *) else { return }

        guard let url = Self.cloudURL, let apiKey = Self.cloudAPIKey else {
            Issue.record("Set QDRANT_CLOUD_URL and QDRANT_CLOUD_API_KEY environment variables")
            return
        }

        let service = QdrantService()
        try await service.configure(url: url, apiKey: apiKey)
        try await service.connect()

        #expect(service.isConnected == true)
        print("Connected to Qdrant Cloud, version: \(service.serverVersion ?? "unknown")")

        let collections = try await service.listCollections()
        print("Available collections: \(collections)")

        await service.disconnect()
    }
}
