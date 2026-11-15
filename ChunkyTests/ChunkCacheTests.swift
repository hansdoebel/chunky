import Foundation
import Testing

@testable import Chunky

struct ChunkCacheTests {
    @Test func keyMatchesTheWorkerDigest() {
        let key = ChunkCacheKey(
            contentSHA256: "ABC",
            doclingVersion: "2.64.0",
            pipeline: "standard",
            tokenizer: "",
            maxTokens: 512
        )
        #expect(key.id == "71d568677ac1aeaaf2e1d1d762fb6c2b630ce1a6f27abdd7ee9779dfbdba38d6")
        #expect(key.canonical == "abc\n2.64.0\nstandard\n\n512")
    }

    @Test func macCacheLivesUnderApplicationSupport() {
        #expect(ChunkCacheLocation.macDirectory().path.hasSuffix("/Library/Application Support/Chunky/Cache")
            || ChunkCacheLocation.macDirectory().lastPathComponent == "Cache")
    }

    @Test func storeKeepsCitationChunksAndEvictsTheOldest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChunkCacheStore(directory: root)
        let key = ChunkCacheKey(contentSHA256: "abc", doclingVersion: "2.64.0", pipeline: "standard", tokenizer: "", maxTokens: 512)
        let chunk = ChunkCacheChunk.normalize([
            "text": "Hello",
            "page": 2,
            "page_labels": ["ii"],
            "headings": ["Intro"],
            "bboxes": [["page": 2, "l": 0, "t": 3, "r": 2, "b": 1]],
            "doc_title": "Paper",
            "authors": ["Ada"],
            "year": 2024,
            "doi": "10.1/abc",
            "source": "paper.pdf",
        ])
        #expect(chunk.pageEnd == 2)
        #expect(chunk.pages == [2])
        #expect(chunk.bboxes[0].coordOrigin == nil)
        let document = try JSONSerialization.data(withJSONObject: ["name": "paper.pdf"])
        _ = try store.store(key: key, document: document, chunks: [chunk])
        let miss = try store.lookup(key, embeddingModel: "qwen3-embedding", embeddingDimension: 4)
        #expect(miss?.vectorHit == false)
        #expect(miss?.chunks.first?.source == "paper.pdf")
        #expect(miss?.chunks.first?.docTitle == "Paper")
        #expect(miss?.chunks.first?.authors == ["Ada"])
        try store.storeVectors(key: key, model: "qwen3-embedding", dimension: 4, vectors: [[0.1, 0.2, 0.3, 0.4]])
        let hit = try store.lookup(key, embeddingModel: "qwen3-embedding", embeddingDimension: 4, includeDocument: true)
        #expect(hit?.vectorHit == true)
        #expect(hit?.vectors?.first == [0.1, 0.2, 0.3, 0.4])
        let saved = try JSONSerialization.jsonObject(with: hit?.document ?? Data()) as? [String: String]
        #expect(saved?["name"] == "paper.pdf")
        let other = try store.lookup(key, embeddingModel: "other", embeddingDimension: 4)
        #expect(other?.vectorHit == false)
        #expect(other?.chunks.count == 1)
        _ = try store.store(key: key, document: document, chunks: [ChunkCacheChunk.normalize(["text": "replaced"])])
        #expect(try store.lookup(key, embeddingModel: "qwen3-embedding", embeddingDimension: 4)?.vectorHit == false)
        #expect(throws: ChunkCacheError.invalidVectors) {
            try store.storeVectors(key: key, model: "qwen3-embedding", dimension: 4, vectors: [[0.1, 0.2, 0.3, 0.4], [0.1, 0.2, 0.3, 0.4]])
        }

        let tight = ChunkCacheStore(directory: root.appendingPathComponent("tight"), limitBytes: 1)
        let first = ChunkCacheKey(contentSHA256: String(repeating: "a", count: 64), doclingVersion: "2.64.0", pipeline: "standard", tokenizer: "", maxTokens: 512)
        let second = ChunkCacheKey(contentSHA256: String(repeating: "b", count: 64), doclingVersion: "2.64.0", pipeline: "standard", tokenizer: "", maxTokens: 512)
        _ = try tight.store(key: first, document: document, chunks: [ChunkCacheChunk.normalize(["text": "one"])])
        _ = try tight.store(key: second, document: document, chunks: [ChunkCacheChunk.normalize(["text": "two"])])
        #expect(try tight.lookup(first) == nil)
        #expect(try tight.lookup(second)?.chunks.first?.text == "two")
        #expect(try tight.stats().entries == 1)
        try tight.clear()
        #expect(try tight.stats() == ChunkCacheStats(entries: 0, bytes: 0, limitBytes: 1))
    }

    @Test func corruptManifestIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-cache-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let store = ChunkCacheStore(directory: root)
        #expect(throws: ChunkCacheError.corruptManifest) {
            try store.stats()
        }
    }

    @Test func workerLookupDecodesACacheHit() async throws {
        let payload: [String: Any] = [
            "hit": true,
            "id": "abc",
            "vector_hit": true,
            "chunks": [["text": "Hello", "source": "paper.pdf", "page": 1, "doc_title": "Paper"]],
            "vectors": [[0.5, 0.25]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let cache = WorkerChunkCache(http: ScriptedChunkCacheHTTP(status: 200, body: data))
        let key = ChunkCacheKey(contentSHA256: "abc", doclingVersion: "2.64.0", pipeline: "standard", tokenizer: "", maxTokens: 512)
        let hit = try await cache.lookup(key, embeddingModel: "qwen3-embedding", embeddingDimension: 2)
        #expect(hit.vectorHit)
        #expect(hit.chunks.first?.source == "paper.pdf")
        #expect(hit.chunks.first?.docTitle == "Paper")
        #expect(hit.vectors?.first == [0.5, 0.25])
    }
}

private struct ScriptedChunkCacheHTTP: ChunkCacheHTTP {
    var status: Int
    var body: Data

    func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
        (status, self.body)
    }
}
