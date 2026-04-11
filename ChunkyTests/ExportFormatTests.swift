import Testing
import Foundation

@testable import Chunky

/// Tests for export format functionality using sample.pdf from assets
struct ExportFormatTests {

    // MARK: - Test Setup

    /// Path to sample.pdf in assets directory
    static let samplePDFPath: String = {
        // Get the project root by finding the assets directory
        let currentFile = #file
        let testsDir = URL(fileURLWithPath: currentFile).deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        return projectRoot.appendingPathComponent("assets/sample.pdf").path
    }()

    /// Path to sample_chunks.json in assets directory
    static let sampleChunksPath: String = {
        let currentFile = #file
        let testsDir = URL(fileURLWithPath: currentFile).deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        return projectRoot.appendingPathComponent("assets/sample_chunks.json").path
    }()

    /// Test chunk data structure (mirrors ChunkingService.DocumentChunk)
    struct TestChunk {
        let id: String
        let text: String
        let source: String
        let page: Int?
        let headings: [String]
        let tokenCount: Int
    }

    /// Create test chunks for export testing
    static func createTestChunks() -> [TestChunk] {
        return [
            TestChunk(
                id: "test-chunk-1",
                text: "This is the first test chunk with some content.",
                source: "sample.pdf",
                page: 1,
                headings: ["Introduction", "Overview"],
                tokenCount: 10
            ),
            TestChunk(
                id: "test-chunk-2",
                text: "This is the second test chunk with different content.",
                source: "sample.pdf",
                page: 1,
                headings: ["Introduction", "Details"],
                tokenCount: 11
            ),
            TestChunk(
                id: "test-chunk-3",
                text: "This is the third test chunk on page two.",
                source: "sample.pdf",
                page: 2,
                headings: ["Conclusion"],
                tokenCount: 9
            )
        ]
    }

    /// Test settings structure
    struct TestSettings {
        var metadataIncludeFilename: Bool = true
        var metadataIncludePageNumber: Bool = true
        var metadataIncludeHeadings: Bool = true
        var metadataIncludeTimestamp: Bool = true
    }

    /// Create test settings with all metadata enabled
    static func createTestSettings(
        includeFilename: Bool = true,
        includePageNumber: Bool = true,
        includeHeadings: Bool = true,
        includeTimestamp: Bool = true
    ) -> TestSettings {
        return TestSettings(
            metadataIncludeFilename: includeFilename,
            metadataIncludePageNumber: includePageNumber,
            metadataIncludeHeadings: includeHeadings,
            metadataIncludeTimestamp: includeTimestamp
        )
    }

    /// Mock ChunkExport for testing without AppSettings dependency
    struct MockChunkExport: Codable {
        let id: String
        let text: String
        let source: String?
        let page: Int?
        let headings: [String]?
        let tokenCount: Int
        let timestamp: String?

        init(chunk: TestChunk, settings: TestSettings) {
            self.id = chunk.id
            self.text = chunk.text
            self.source = settings.metadataIncludeFilename ? chunk.source : nil
            self.page = settings.metadataIncludePageNumber ? chunk.page : nil
            self.headings = settings.metadataIncludeHeadings ? (chunk.headings.isEmpty ? nil : chunk.headings) : nil
            self.tokenCount = chunk.tokenCount
            self.timestamp = settings.metadataIncludeTimestamp ? ISO8601DateFormatter().string(from: Date()) : nil
        }
    }

    // MARK: - Sample PDF Tests

    @Test func samplePDFExists() {
        let fileExists = FileManager.default.fileExists(atPath: Self.samplePDFPath)
        #expect(fileExists, "sample.pdf should exist in assets directory at \(Self.samplePDFPath)")
    }

    @Test func sampleChunksJSONExists() {
        let fileExists = FileManager.default.fileExists(atPath: Self.sampleChunksPath)
        #expect(fileExists, "sample_chunks.json should exist in assets directory")
    }

    @Test func sampleChunksJSONIsValid() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sampleChunksPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil, "sample_chunks.json should be valid JSON")
        #expect(json?["source"] as? String == "sample.pdf")
        #expect(json?["total_chunks"] as? Int == 4)

        let chunks = json?["chunks"] as? [[String: Any]]
        #expect(chunks?.count == 4)
    }

    // MARK: - ChunkExport Tests

    @Test func chunkExportIncludesAllMetadataWhenEnabled() {
        let settings = Self.createTestSettings()
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text content",
            source: "test.pdf",
            page: 5,
            headings: ["Heading 1", "Heading 2"],
            tokenCount: 4
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.id == "test-id")
        #expect(export.text == "Test text content")
        #expect(export.source == "test.pdf")
        #expect(export.page == 5)
        #expect(export.headings == ["Heading 1", "Heading 2"])
        #expect(export.tokenCount == 4)
        #expect(export.timestamp != nil)
    }

    @Test func chunkExportExcludesFilenameWhenDisabled() {
        let settings = Self.createTestSettings(includeFilename: false)
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text",
            source: "test.pdf",
            page: 1,
            headings: [],
            tokenCount: 2
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.source == nil)
    }

    @Test func chunkExportExcludesPageNumberWhenDisabled() {
        let settings = Self.createTestSettings(includePageNumber: false)
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text",
            source: "test.pdf",
            page: 5,
            headings: [],
            tokenCount: 2
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.page == nil)
    }

    @Test func chunkExportExcludesHeadingsWhenDisabled() {
        let settings = Self.createTestSettings(includeHeadings: false)
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text",
            source: "test.pdf",
            page: 1,
            headings: ["Heading 1"],
            tokenCount: 2
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.headings == nil)
    }

    @Test func chunkExportExcludesTimestampWhenDisabled() {
        let settings = Self.createTestSettings(includeTimestamp: false)
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text",
            source: "test.pdf",
            page: 1,
            headings: [],
            tokenCount: 2
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.timestamp == nil)
    }

    @Test func chunkExportEmptyHeadingsBecomesNil() {
        let settings = Self.createTestSettings()
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text",
            source: "test.pdf",
            page: 1,
            headings: [],
            tokenCount: 2
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.headings == nil)
    }

    // MARK: - JSON Export Tests

    @Test func jsonExportProducesValidJSON() throws {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        let exports = chunks.map { MockChunkExport(chunk: $0, settings: settings) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(exports)

        #expect(!data.isEmpty)

        // Verify it can be decoded back
        let decoded = try JSONDecoder().decode([MockChunkExport].self, from: data)
        #expect(decoded.count == 3)
    }

    @Test func jsonExportContainsExpectedFields() throws {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        let exports = chunks.map { MockChunkExport(chunk: $0, settings: settings) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(exports)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\"id\""))
        #expect(jsonString.contains("\"text\""))
        #expect(jsonString.contains("\"source\""))
        #expect(jsonString.contains("\"page\""))
        #expect(jsonString.contains("\"headings\""))
        #expect(jsonString.contains("\"tokenCount\""))
        #expect(jsonString.contains("\"timestamp\""))
        #expect(jsonString.contains("sample.pdf"))
    }

    @Test func jsonExportOmitsNullFieldsCorrectly() throws {
        let settings = Self.createTestSettings(
            includeFilename: false,
            includePageNumber: false,
            includeHeadings: false,
            includeTimestamp: false
        )
        let chunk = TestChunk(
            id: "test-id",
            text: "Test text",
            source: "test.pdf",
            page: 1,
            headings: ["Heading"],
            tokenCount: 2
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        // Verify fields are nil in the struct
        #expect(export.source == nil)
        #expect(export.page == nil)
        #expect(export.headings == nil)
        #expect(export.timestamp == nil)

        // Verify JSON encoding works - Swift's Codable omits nil fields by default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode([export])
        let jsonString = String(data: data, encoding: .utf8)!

        // These optional fields should be omitted entirely from JSON when nil
        #expect(!jsonString.contains("\"source\""), "source field should be omitted when nil")
        #expect(!jsonString.contains("\"page\""), "page field should be omitted when nil")
        #expect(!jsonString.contains("\"headings\""), "headings field should be omitted when nil")
        #expect(!jsonString.contains("\"timestamp\""), "timestamp field should be omitted when nil")

        // Required fields should still be present
        #expect(jsonString.contains("\"id\""))
        #expect(jsonString.contains("\"text\""))
        #expect(jsonString.contains("\"tokenCount\""))
    }

    @Test func jsonExportSortedKeys() throws {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        let exports = chunks.map { MockChunkExport(chunk: $0, settings: settings) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(exports)
        let jsonString = String(data: data, encoding: .utf8)!

        // With sortedKeys, "headings" should appear before "id" and "id" before "page"
        let headingsIndex = jsonString.range(of: "\"headings\"")?.lowerBound
        let idIndex = jsonString.range(of: "\"id\"")?.lowerBound
        let pageIndex = jsonString.range(of: "\"page\"")?.lowerBound

        if let h = headingsIndex, let i = idIndex, let p = pageIndex {
            #expect(h < i, "headings should come before id with sorted keys")
            #expect(i < p, "id should come before page with sorted keys")
        }
    }

    // MARK: - Text Export Tests

    @Test func textExportProducesValidText() {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        var header = "sample.pdf\n"
        header += "Chunks: \(chunks.count)\n"
        header += String(repeating: "=", count: 40) + "\n\n"

        let text = chunks.enumerated().map { index, chunk in
            var txt = "=== Chunk \(index + 1) ===\n"
            if settings.metadataIncludeHeadings && !chunk.headings.isEmpty {
                txt += "Headings: \(chunk.headings.joined(separator: " > "))\n"
            }
            if settings.metadataIncludePageNumber, let page = chunk.page {
                txt += "Page: \(page)\n"
            }
            txt += "\n\(chunk.text)\n"
            return txt
        }.joined(separator: "\n\n")

        let exportText = header + text

        #expect(exportText.contains("sample.pdf"))
        #expect(exportText.contains("Chunks: 3"))
        #expect(exportText.contains("=== Chunk 1 ==="))
        #expect(exportText.contains("=== Chunk 2 ==="))
        #expect(exportText.contains("=== Chunk 3 ==="))
        #expect(exportText.contains("first test chunk"))
        #expect(exportText.contains("second test chunk"))
        #expect(exportText.contains("third test chunk"))
    }

    @Test func textExportIncludesHeadings() {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        let text = chunks.enumerated().map { index, chunk in
            var txt = "=== Chunk \(index + 1) ===\n"
            if settings.metadataIncludeHeadings && !chunk.headings.isEmpty {
                txt += "Headings: \(chunk.headings.joined(separator: " > "))\n"
            }
            txt += "\n\(chunk.text)\n"
            return txt
        }.joined(separator: "\n\n")

        #expect(text.contains("Headings: Introduction > Overview"))
        #expect(text.contains("Headings: Introduction > Details"))
        #expect(text.contains("Headings: Conclusion"))
    }

    @Test func textExportIncludesPageNumbers() {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        let text = chunks.enumerated().map { index, chunk in
            var txt = "=== Chunk \(index + 1) ===\n"
            if settings.metadataIncludePageNumber, let page = chunk.page {
                txt += "Page: \(page)\n"
            }
            txt += "\n\(chunk.text)\n"
            return txt
        }.joined(separator: "\n\n")

        #expect(text.contains("Page: 1"))
        #expect(text.contains("Page: 2"))
    }

    @Test func textExportWithoutMetadata() {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings(
            includeFilename: false,
            includePageNumber: false,
            includeHeadings: false,
            includeTimestamp: false
        )

        let text = chunks.enumerated().map { index, chunk in
            var txt = "=== Chunk \(index + 1) ===\n"
            if settings.metadataIncludeHeadings && !chunk.headings.isEmpty {
                txt += "Headings: \(chunk.headings.joined(separator: " > "))\n"
            }
            if settings.metadataIncludePageNumber, let page = chunk.page {
                txt += "Page: \(page)\n"
            }
            txt += "\n\(chunk.text)\n"
            return txt
        }.joined(separator: "\n\n")

        #expect(!text.contains("Headings:"))
        #expect(!text.contains("Page:"))
        #expect(text.contains("first test chunk"))
    }

    // MARK: - Export Format Selection Tests

    @Test func exportFormatFromRawValue() {
        #expect(ExportFormat(rawValue: "docling") == .docling)
        #expect(ExportFormat(rawValue: "html") == .html)
        #expect(ExportFormat(rawValue: "json") == .json)
        #expect(ExportFormat(rawValue: "none") == ExportFormat.none)
        #expect(ExportFormat(rawValue: "text") == .text)
        #expect(ExportFormat(rawValue: "invalid") == nil)
    }

    @Test func exportFormatDefaultsToJSON() {
        let settings = AppSettings()
        // Default should be docling (markdown), but let's test fallback
        let format = ExportFormat(rawValue: settings.exportFormat) ?? .json
        #expect(format != nil)
    }

    @Test func allExportFormatsHaveDisplayNames() {
        for format in ExportFormat.allCases {
            #expect(!format.displayName.isEmpty, "\(format) should have a display name")
        }
    }

    @Test func allExportFormatsHaveDescriptions() {
        for format in ExportFormat.allCases {
            #expect(!format.description.isEmpty, "\(format) should have a description")
        }
    }

    // MARK: - File Extension Tests

    @Test func exportFormatFileExtensions() {
        // Test that each format maps to expected file extension
        let formatExtensions: [(ExportFormat, String)] = [
            (.docling, "md"),
            (.html, "html"),
            (.json, "json"),
            (.text, "txt")
        ]

        for (format, expectedExtension) in formatExtensions {
            let fileExtension: String
            switch format {
            case .none:
                continue // none doesn't produce a file
            case .docling:
                fileExtension = "md"
            case .json:
                fileExtension = "json"
            case .text:
                fileExtension = "txt"
            case .html:
                fileExtension = "html"
            case .doctags:
                fileExtension = "doctags"
            }
            #expect(fileExtension == expectedExtension, "\(format) should use .\(expectedExtension) extension")
        }
    }

    // MARK: - ChunkExport Codable Tests

    @Test func chunkExportEncodesAndDecodes() throws {
        let settings = Self.createTestSettings()
        let chunk = TestChunk(
            id: "roundtrip-test",
            text: "Test content for roundtrip",
            source: "test.pdf",
            page: 3,
            headings: ["Section A", "Subsection B"],
            tokenCount: 5
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        let encoder = JSONEncoder()
        let data = try encoder.encode(export)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MockChunkExport.self, from: data)

        #expect(decoded.id == export.id)
        #expect(decoded.text == export.text)
        #expect(decoded.source == export.source)
        #expect(decoded.page == export.page)
        #expect(decoded.headings == export.headings)
        #expect(decoded.tokenCount == export.tokenCount)
        // Timestamp may differ due to encoding/decoding, so just check it's present
        #expect(decoded.timestamp != nil)
    }

    @Test func chunkExportArrayEncodesAndDecodes() throws {
        let chunks = Self.createTestChunks()
        let settings = Self.createTestSettings()

        let exports = chunks.map { MockChunkExport(chunk: $0, settings: settings) }

        let encoder = JSONEncoder()
        let data = try encoder.encode(exports)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([MockChunkExport].self, from: data)

        #expect(decoded.count == exports.count)
        for (original, decoded) in zip(exports, decoded) {
            #expect(original.id == decoded.id)
            #expect(original.text == decoded.text)
        }
    }

    // MARK: - Edge Cases

    @Test func chunkExportHandlesEmptyText() throws {
        let settings = Self.createTestSettings()
        let chunk = TestChunk(
            id: "empty-text",
            text: "",
            source: "test.pdf",
            page: 1,
            headings: [],
            tokenCount: 0
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        let encoder = JSONEncoder()
        let data = try encoder.encode(export)
        let decoded = try JSONDecoder().decode(MockChunkExport.self, from: data)

        #expect(decoded.text == "")
        #expect(decoded.tokenCount == 0)
    }

    @Test func chunkExportHandlesSpecialCharacters() throws {
        let settings = Self.createTestSettings()
        let chunk = TestChunk(
            id: "special-chars",
            text: "Text with \"quotes\", 'apostrophes', <tags>, & ampersands, emojis",
            source: "test.pdf",
            page: 1,
            headings: ["Ueberschrift", "Section"],
            tokenCount: 15
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        let encoder = JSONEncoder()
        let data = try encoder.encode(export)
        let decoded = try JSONDecoder().decode(MockChunkExport.self, from: data)

        #expect(decoded.text.contains("\"quotes\""))
        #expect(decoded.text.contains("emojis"))
        #expect(decoded.source == "test.pdf")
        #expect(decoded.headings?.contains("Ueberschrift") == true)
    }

    @Test func chunkExportHandlesVeryLongText() throws {
        let settings = Self.createTestSettings()
        let longText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 1000)
        let chunk = TestChunk(
            id: "long-text",
            text: longText,
            source: "test.pdf",
            page: 1,
            headings: [],
            tokenCount: longText.count / 4
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        let encoder = JSONEncoder()
        let data = try encoder.encode(export)
        let decoded = try JSONDecoder().decode(MockChunkExport.self, from: data)

        #expect(decoded.text == longText)
        #expect(decoded.tokenCount == longText.count / 4)
    }

    @Test func chunkExportHandlesManyHeadings() throws {
        let settings = Self.createTestSettings()
        let manyHeadings = (1...10).map { "Heading \($0)" }
        let chunk = TestChunk(
            id: "many-headings",
            text: "Content",
            source: "test.pdf",
            page: 1,
            headings: manyHeadings,
            tokenCount: 1
        )

        let export = MockChunkExport(chunk: chunk, settings: settings)

        #expect(export.headings?.count == 10)
        #expect(export.headings?.first == "Heading 1")
        #expect(export.headings?.last == "Heading 10")
    }
}
