import XCTest

struct ChunkingOptions {
    var maxTokens: Int = 512
    var model: String = "default"
    var workers: Int = 4
    var accelerator: String = "auto"
    var timeout: Int = 300
    var maxPages: Int = 0
    var doTableExtraction: Bool = true
    var tableMode: String = "accurate"
    var doOCR: Bool = false
    var exportFormat: String = "none"
    var exportFolder: String = ""
}

struct MockChunkMetadata: Codable {
    let chunkIndex: Int
    let source: String
    let headings: [String]
    let page: Int?

    enum CodingKeys: String, CodingKey {
        case chunkIndex = "chunk_index"
        case source
        case headings
        case page
    }
}

struct MockChunk: Codable, Identifiable {
    let id: String
    let text: String
    let metadata: MockChunkMetadata
}

struct MockChunkerOutput: Codable {
    let source: String
    let totalChunks: Int
    let chunks: [MockChunk]

    enum CodingKeys: String, CodingKey {
        case source
        case totalChunks = "total_chunks"
        case chunks
    }
}

final class ChunkingServiceTests: XCTestCase {

    func testOptionsDefaultValues() {
        let options = ChunkingOptions()

        XCTAssertEqual(options.maxTokens, 512)
        XCTAssertEqual(options.model, "default")
        XCTAssertEqual(options.workers, 4)
        XCTAssertEqual(options.accelerator, "auto")
        XCTAssertEqual(options.timeout, 300)
        XCTAssertEqual(options.maxPages, 0)
        XCTAssertTrue(options.doTableExtraction)
        XCTAssertEqual(options.tableMode, "accurate")
        XCTAssertFalse(options.doOCR)
        XCTAssertEqual(options.exportFormat, "none")
        XCTAssertEqual(options.exportFolder, "")
    }

    func testOptionsCustomValues() {
        let options = ChunkingOptions(
            maxTokens: 256,
            model: "granite-docling",
            workers: 2,
            accelerator: "mps",
            timeout: 600,
            maxPages: 50,
            doTableExtraction: false,
            tableMode: "fast",
            doOCR: true,
            exportFormat: "markdown",
            exportFolder: "/tmp/export"
        )

        XCTAssertEqual(options.maxTokens, 256)
        XCTAssertEqual(options.model, "granite-docling")
        XCTAssertEqual(options.workers, 2)
        XCTAssertEqual(options.accelerator, "mps")
        XCTAssertEqual(options.timeout, 600)
        XCTAssertEqual(options.maxPages, 50)
        XCTAssertFalse(options.doTableExtraction)
        XCTAssertEqual(options.tableMode, "fast")
        XCTAssertTrue(options.doOCR)
        XCTAssertEqual(options.exportFormat, "markdown")
        XCTAssertEqual(options.exportFolder, "/tmp/export")
    }

    func testChunkMetadataCodingKeys() throws {
        let json = """
        {
            "chunk_index": 5,
            "source": "test.pdf",
            "headings": ["Chapter 1", "Section A"],
            "page": 3
        }
        """
        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(MockChunkMetadata.self, from: data)

        XCTAssertEqual(metadata.chunkIndex, 5)
        XCTAssertEqual(metadata.source, "test.pdf")
        XCTAssertEqual(metadata.headings, ["Chapter 1", "Section A"])
        XCTAssertEqual(metadata.page, 3)
    }

    func testChunkMetadataWithNullPage() throws {
        let json = """
        {
            "chunk_index": 0,
            "source": "document.pdf",
            "headings": [],
            "page": null
        }
        """
        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(MockChunkMetadata.self, from: data)

        XCTAssertNil(metadata.page)
    }

    func testChunkerOutputDecoding() throws {
        let json = """
        {
            "source": "sample.pdf",
            "total_chunks": 2,
            "chunks": [
                {
                    "id": "chunk-001",
                    "text": "First chunk text",
                    "metadata": {
                        "chunk_index": 0,
                        "source": "sample.pdf",
                        "headings": ["Introduction"],
                        "page": 1
                    }
                },
                {
                    "id": "chunk-002",
                    "text": "Second chunk text",
                    "metadata": {
                        "chunk_index": 1,
                        "source": "sample.pdf",
                        "headings": ["Body"],
                        "page": 2
                    }
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(MockChunkerOutput.self, from: data)

        XCTAssertEqual(output.source, "sample.pdf")
        XCTAssertEqual(output.totalChunks, 2)
        XCTAssertEqual(output.chunks.count, 2)
        XCTAssertEqual(output.chunks[0].id, "chunk-001")
        XCTAssertEqual(output.chunks[0].text, "First chunk text")
        XCTAssertEqual(output.chunks[1].metadata.headings, ["Body"])
    }

    func testChunkWithLongText() throws {
        let longText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 100)
        let chunk = MockChunk(
            id: "long-text-chunk",
            text: longText,
            metadata: MockChunkMetadata(
                chunkIndex: 0,
                source: "long-doc.pdf",
                headings: [],
                page: nil
            )
        )

        let encoded = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(MockChunk.self, from: encoded)

        XCTAssertEqual(decoded.text.count, longText.count)
    }

    func testChunkWithSpecialCharacters() throws {
        let chunk = MockChunk(
            id: "special-chars",
            text: "Special chars: é, ñ, ü, 中文, 日本語, emoji: 🎉",
            metadata: MockChunkMetadata(
                chunkIndex: 0,
                source: "special.pdf",
                headings: ["Tëst Hëading"],
                page: 1
            )
        )

        let encoded = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(MockChunk.self, from: encoded)

        XCTAssertTrue(decoded.text.contains("中文"))
        XCTAssertTrue(decoded.text.contains("🎉"))
    }

    func testEmptyChunkerOutput() throws {
        let output = MockChunkerOutput(
            source: "empty.pdf",
            totalChunks: 0,
            chunks: []
        )

        let encoded = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(MockChunkerOutput.self, from: encoded)

        XCTAssertEqual(decoded.totalChunks, 0)
        XCTAssertTrue(decoded.chunks.isEmpty)
    }

    func testMockChunkerOutputGeneration() throws {
        let chunks = (0..<5).map { i in
            MockChunk(
                id: "chunk-\(i)",
                text: "Content for chunk \(i)",
                metadata: MockChunkMetadata(
                    chunkIndex: i,
                    source: "test.pdf",
                    headings: ["Section \(i)"],
                    page: i + 1
                )
            )
        }

        let output = MockChunkerOutput(
            source: "test.pdf",
            totalChunks: chunks.count,
            chunks: chunks
        )

        let encoded = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(MockChunkerOutput.self, from: encoded)

        XCTAssertEqual(decoded.totalChunks, 5)
        XCTAssertEqual(decoded.chunks.count, 5)
        XCTAssertEqual(decoded.chunks[2].id, "chunk-2")
    }
}
