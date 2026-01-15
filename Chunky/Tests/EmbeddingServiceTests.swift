import XCTest

enum MockEmbeddingError: Error, LocalizedError {
    case invalidURL(String)
    case requestFailed
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid Ollama URL: \(url)"
        case .requestFailed:
            return "Failed to get embeddings from Ollama"
        case .emptyInput:
            return "No text to embed"
        }
    }
}

struct MockEmbeddingResponse: Codable {
    let embeddings: [[Float]]
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

enum MockEmbeddingModelInfo {
    static let dimensions: [String: Int] = [
        "nomic-embed-text": 768,
        "nomic-embed-text:latest": 768,
        "mxbai-embed-large": 1024,
        "mxbai-embed-large:latest": 1024,
        "all-minilm": 384,
        "all-minilm:latest": 384,
        "snowflake-arctic-embed": 1024,
        "snowflake-arctic-embed:latest": 1024,
    ]

    static func getDimensions(for model: String) -> Int {
        let baseName = model.replacingOccurrences(of: ":latest", with: "")
        return dimensions[baseName] ?? dimensions[model] ?? 768
    }
}

final class EmbeddingServiceTests: XCTestCase {

    func testURLValidation() {
        let validURLs = [
            "http://localhost:11434",
            "https://ollama.example.com",
            "http://192.168.1.100:11434"
        ]

        for urlString in validURLs {
            let url = URL(string: urlString)
            XCTAssertNotNil(url, "Should create URL from: \(urlString)")
            XCTAssertNotNil(url?.scheme, "URL should have scheme: \(urlString)")
        }
    }

    func testInvalidURLDetection() {
        let emptyURL = URL(string: "")
        XCTAssertNil(emptyURL, "Empty string should not create URL")

        let validHTTPUrl = URL(string: "http://localhost:11434")
        XCTAssertEqual(validHTTPUrl?.scheme, "http")
        XCTAssertEqual(validHTTPUrl?.host, "localhost")
        XCTAssertEqual(validHTTPUrl?.port, 11434)
    }

    func testEmbeddingErrorDescriptions() {
        let invalidURLError = MockEmbeddingError.invalidURL("bad-url")
        XCTAssertEqual(invalidURLError.errorDescription, "Invalid Ollama URL: bad-url")

        let requestFailedError = MockEmbeddingError.requestFailed
        XCTAssertEqual(requestFailedError.errorDescription, "Failed to get embeddings from Ollama")

        let emptyInputError = MockEmbeddingError.emptyInput
        XCTAssertEqual(emptyInputError.errorDescription, "No text to embed")
    }

    func testEmbeddingResponseDecoding() throws {
        let json = """
        {
            "embeddings": [
                [0.1, 0.2, 0.3, 0.4, 0.5],
                [0.6, 0.7, 0.8, 0.9, 1.0]
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(MockEmbeddingResponse.self, from: data)

        XCTAssertEqual(response.embeddings.count, 2)
        XCTAssertEqual(response.embeddings[0].count, 5)
        XCTAssertEqual(response.embeddings[0][0], 0.1, accuracy: 0.001)
        XCTAssertEqual(response.embeddings[1][4], 1.0, accuracy: 0.001)
    }

    func testArrayChunkedExtension() {
        let array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        let chunked3 = array.chunked(into: 3)
        XCTAssertEqual(chunked3.count, 4)
        XCTAssertEqual(chunked3[0], [1, 2, 3])
        XCTAssertEqual(chunked3[1], [4, 5, 6])
        XCTAssertEqual(chunked3[2], [7, 8, 9])
        XCTAssertEqual(chunked3[3], [10])

        let chunked5 = array.chunked(into: 5)
        XCTAssertEqual(chunked5.count, 2)
        XCTAssertEqual(chunked5[0], [1, 2, 3, 4, 5])
        XCTAssertEqual(chunked5[1], [6, 7, 8, 9, 10])

        let chunkedLarge = array.chunked(into: 100)
        XCTAssertEqual(chunkedLarge.count, 1)
        XCTAssertEqual(chunkedLarge[0], array)
    }

    func testArrayChunkedEmptyArray() {
        let empty: [Int] = []
        let chunked = empty.chunked(into: 5)
        XCTAssertTrue(chunked.isEmpty)
    }

    func testArrayChunkedSingleElement() {
        let single = [42]
        let chunked = single.chunked(into: 10)
        XCTAssertEqual(chunked.count, 1)
        XCTAssertEqual(chunked[0], [42])
    }

    func testMockEmbeddingGeneration() {
        let dimensions = 768
        let batchSize = 10

        let mockEmbeddings = (0..<batchSize).map { _ in
            (0..<dimensions).map { _ in Float.random(in: -1...1) }
        }

        XCTAssertEqual(mockEmbeddings.count, batchSize)
        XCTAssertEqual(mockEmbeddings[0].count, dimensions)
    }

    func testMockEmbeddingResponse() throws {
        let response = MockEmbeddingResponse(embeddings: [
            [0.1, 0.2, 0.3],
            [0.4, 0.5, 0.6]
        ])

        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(MockEmbeddingResponse.self, from: encoded)

        XCTAssertEqual(decoded.embeddings.count, 2)
    }
}

final class EmbeddingModelInfoTests: XCTestCase {

    func testKnownModelDimensions() {
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "nomic-embed-text"), 768)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "nomic-embed-text:latest"), 768)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "mxbai-embed-large"), 1024)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "mxbai-embed-large:latest"), 1024)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "all-minilm"), 384)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "all-minilm:latest"), 384)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "snowflake-arctic-embed"), 1024)
    }

    func testUnknownModelDefaultsDimensions() {
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "unknown-model"), 768)
        XCTAssertEqual(MockEmbeddingModelInfo.getDimensions(for: "custom-embedding-model:v1"), 768)
    }
}
