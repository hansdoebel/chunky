import XCTest

struct MockUploadProgress: Codable {
    let batch: Int
    let total: Int
    let points: Int
}

enum MockQdrantError: Error, LocalizedError {
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let message):
            return "Qdrant upload failed: \(message)"
        }
    }
}

struct MockChunkPayload: Codable {
    let text: String
    let source: String
    let page: Int?
    let headings: [String]
}

struct MockChunkWithEmbedding: Codable {
    let id: String
    let vector: [Float]
    let payload: MockChunkPayload
}

struct MockQdrantInput: Codable {
    let points: [MockChunkWithEmbedding]
}

final class QdrantServiceTests: XCTestCase {

    func testUploadProgressDecoding() throws {
        let json = """
        {
            "batch": 3,
            "total": 10,
            "points": 100
        }
        """
        let data = json.data(using: .utf8)!
        let progress = try JSONDecoder().decode(MockUploadProgress.self, from: data)

        XCTAssertEqual(progress.batch, 3)
        XCTAssertEqual(progress.total, 10)
        XCTAssertEqual(progress.points, 100)
    }

    func testQdrantErrorDescription() {
        let error = MockQdrantError.uploadFailed("Connection timeout after 30 seconds")
        XCTAssertEqual(error.errorDescription, "Qdrant upload failed: Connection timeout after 30 seconds")
    }

    func testChunkWithEmbeddingEncoding() throws {
        let chunk = MockChunkWithEmbedding(
            id: "test-id-123",
            vector: [0.1, 0.2, 0.3, 0.4, 0.5],
            payload: MockChunkPayload(
                text: "Sample text content",
                source: "document.pdf",
                page: 5,
                headings: ["Chapter 1", "Section A"]
            )
        )

        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(MockChunkWithEmbedding.self, from: data)

        XCTAssertEqual(decoded.id, "test-id-123")
        XCTAssertEqual(decoded.vector.count, 5)
        XCTAssertEqual(decoded.vector[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(decoded.payload.text, "Sample text content")
        XCTAssertEqual(decoded.payload.source, "document.pdf")
        XCTAssertEqual(decoded.payload.page, 5)
        XCTAssertEqual(decoded.payload.headings, ["Chapter 1", "Section A"])
    }

    func testChunkPayloadWithNilPage() throws {
        let payload = MockChunkPayload(
            text: "Text without page info",
            source: "file.pdf",
            page: nil,
            headings: []
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MockChunkPayload.self, from: data)

        XCTAssertNil(decoded.page)
        XCTAssertTrue(decoded.headings.isEmpty)
    }

    func testQdrantInputEncoding() throws {
        let input = MockQdrantInput(points: [
            MockChunkWithEmbedding(
                id: "id-1",
                vector: [0.1, 0.2],
                payload: MockChunkPayload(
                    text: "Text 1",
                    source: "doc.pdf",
                    page: 1,
                    headings: ["H1"]
                )
            ),
            MockChunkWithEmbedding(
                id: "id-2",
                vector: [0.3, 0.4],
                payload: MockChunkPayload(
                    text: "Text 2",
                    source: "doc.pdf",
                    page: 2,
                    headings: ["H2"]
                )
            )
        ])

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(MockQdrantInput.self, from: data)

        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.points[0].id, "id-1")
        XCTAssertEqual(decoded.points[1].id, "id-2")
    }

    func testLargeVectorEncoding() throws {
        let dimensions = 768
        let vector = (0..<dimensions).map { Float($0) / Float(dimensions) }

        let chunk = MockChunkWithEmbedding(
            id: "large-vector-test",
            vector: vector,
            payload: MockChunkPayload(
                text: "Test",
                source: "test.pdf",
                page: 1,
                headings: []
            )
        )

        let data = try JSONEncoder().encode(chunk)
        XCTAssertGreaterThan(data.count, 0)

        let decoded = try JSONDecoder().decode(MockChunkWithEmbedding.self, from: data)
        XCTAssertEqual(decoded.vector.count, dimensions)
    }

    func testMockUploadBatching() {
        let totalPoints = 250
        let batchSize = 100

        let expectedBatches = (totalPoints + batchSize - 1) / batchSize
        XCTAssertEqual(expectedBatches, 3)

        var processedPoints = 0
        for batch in 0..<expectedBatches {
            let pointsInBatch = min(batchSize, totalPoints - processedPoints)
            processedPoints += pointsInBatch

            if batch == expectedBatches - 1 {
                XCTAssertEqual(pointsInBatch, 50)
            } else {
                XCTAssertEqual(pointsInBatch, 100)
            }
        }

        XCTAssertEqual(processedPoints, totalPoints)
    }

    func testMockProgressReporting() {
        var progressUpdates: [(batch: Int, total: Int)] = []

        let totalBatches = 5
        for batch in 1...totalBatches {
            progressUpdates.append((batch: batch, total: totalBatches))
        }

        XCTAssertEqual(progressUpdates.count, 5)
        XCTAssertEqual(progressUpdates.first?.batch, 1)
        XCTAssertEqual(progressUpdates.last?.batch, 5)
        XCTAssertTrue(progressUpdates.allSatisfy { $0.total == 5 })
    }
}
