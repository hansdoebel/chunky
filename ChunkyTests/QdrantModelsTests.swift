import Testing
@testable import Chunky

struct QdrantModelsTests {

    // MARK: - ChunkPoint Tests

    @Test func chunkPointCreation() {
        let point = ChunkPoint(
            id: "test-id",
            vector: [0.1, 0.2, 0.3],
            text: "Test text content",
            source: "test.pdf",
            page: 5,
            headings: ["Chapter 1", "Section 1.1"],
            metadata: ["key": "value"]
        )

        #expect(point.id == "test-id")
        #expect(point.vector == [0.1, 0.2, 0.3])
        #expect(point.text == "Test text content")
        #expect(point.source == "test.pdf")
        #expect(point.page == 5)
        #expect(point.headings == ["Chapter 1", "Section 1.1"])
        #expect(point.metadata["key"] == "value")
    }

    @Test func chunkPointDefaultValues() {
        let point = ChunkPoint(
            vector: [0.5],
            text: "Minimal point",
            source: "file.txt"
        )

        #expect(!point.id.isEmpty) // Auto-generated UUID
        #expect(point.page == nil)
        #expect(point.headings.isEmpty)
        #expect(point.metadata.isEmpty)
    }

    @Test func chunkPointAutoGeneratesUUID() {
        let point1 = ChunkPoint(vector: [0.1], text: "Text 1", source: "file.txt")
        let point2 = ChunkPoint(vector: [0.2], text: "Text 2", source: "file.txt")

        #expect(point1.id != point2.id)
    }

    // MARK: - SearchResult Tests

    @Test func searchResultCreation() {
        let result = SearchResult(
            id: "result-1",
            score: 0.95,
            text: "Matched text",
            source: "document.pdf",
            page: 10,
            headings: ["Introduction"]
        )

        #expect(result.id == "result-1")
        #expect(result.score == 0.95)
        #expect(result.text == "Matched text")
        #expect(result.source == "document.pdf")
        #expect(result.page == 10)
        #expect(result.headings == ["Introduction"])
    }

    // MARK: - CollectionInfo Tests

    @Test func collectionInfoCreation() {
        let info = CollectionInfo(
            name: "my-collection",
            vectorsCount: 1000,
            pointsCount: 500,
            status: .green
        )

        #expect(info.name == "my-collection")
        #expect(info.vectorsCount == 1000)
        #expect(info.pointsCount == 500)
        #expect(info.status == .green)
    }

    @Test func collectionStatusValues() {
        #expect(CollectionInfo.CollectionStatus.green.rawValue == "green")
        #expect(CollectionInfo.CollectionStatus.yellow.rawValue == "yellow")
        #expect(CollectionInfo.CollectionStatus.red.rawValue == "red")
        #expect(CollectionInfo.CollectionStatus.unknown.rawValue == "unknown")
    }

    // MARK: - UploadProgress Tests

    @Test func uploadProgressFraction() {
        let progress = UploadProgress(
            completed: 50,
            total: 100,
            currentBatch: 5,
            totalBatches: 10
        )

        #expect(progress.fraction == 0.5)
        #expect(progress.percentComplete == 50)
    }

    @Test func uploadProgressZeroTotal() {
        let progress = UploadProgress(
            completed: 0,
            total: 0,
            currentBatch: 0,
            totalBatches: 0
        )

        #expect(progress.fraction == 0)
        #expect(progress.percentComplete == 0)
    }

    @Test func uploadProgressComplete() {
        let progress = UploadProgress(
            completed: 100,
            total: 100,
            currentBatch: 10,
            totalBatches: 10
        )

        #expect(progress.fraction == 1.0)
        #expect(progress.percentComplete == 100)
    }

    // MARK: - QdrantError Tests

    @Test func errorDescriptions() {
        let errors: [(QdrantError, String)] = [
            (.connectionFailed("timeout"), "Connection failed: timeout"),
            (.notConnected, "Not connected to Qdrant server"),
            (.invalidURL("bad-url"), "Invalid URL: bad-url"),
            (.collectionNotFound("missing"), "Collection not found: missing"),
            (.collectionAlreadyExists("existing"), "Collection already exists: existing"),
            (.operationFailed("failed op"), "Operation failed: failed op"),
            (.invalidResponse("bad response"), "Invalid response: bad response"),
            (.timeout, "Operation timed out"),
            (.cancelled, "Operation was cancelled"),
        ]

        for (error, expectedDescription) in errors {
            #expect(error.errorDescription == expectedDescription)
        }
    }
}
