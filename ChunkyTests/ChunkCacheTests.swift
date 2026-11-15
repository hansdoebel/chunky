import AppKit
import Foundation
import SwiftUI
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
        #expect(key.id == "3636fff3a40669cb435b521f6960f2888b9555317a5077458119ae261d853611")
        #expect(key.canonical == "abc\n2.64.0\nstandard\n\n512\n")
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

    @Test func reuseSkipsConversionAndEmbeddingOnlyWhenVectorsMatch() async throws {
        let settings = IsolatedSettings.make()
        settings.recordedDoclingVersion = "2.64.0"
        settings.doclingModel = "standard"
        settings.chunkTokenizer = ""
        settings.maxTokensPerChunk = 512
        settings.embeddingModel = "qwen3-embedding"
        settings.embeddingDimensions = 2
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-cache-bridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ChunkCacheBridge(settings: settings, directory: root, remote: nil)
        #expect(await bridge.load(digest: "abc", force: false) == nil)
        #expect(ChunkCachePolicy.use(force: true, chunkCount: 2, vectorCount: 2) == .miss)
        #expect(ChunkCachePolicy.use(force: false, chunkCount: 2, vectorCount: nil) == .hit)
        #expect(ChunkCachePolicy.use(force: false, chunkCount: 2, vectorCount: 2) == .vectors)
        let limited = IsolatedSettings.make()
        limited.doclingMaxPages = 3
        limited.doOCR = true
        #expect(ChunkCachePolicy.key(contentSHA256: "abc", settings: limited).id != ChunkCachePolicy.key(contentSHA256: "abc", settings: settings).id)
        let chunk = ChunkCacheChunk.normalize(["text": "Hello", "source": "paper.pdf", "page": 1])
        let document = try JSONSerialization.data(withJSONObject: ["name": "paper.pdf"])
        try bridge.store(digest: "abc", document: document, chunks: [chunk], vectors: [[0.5, 0.25]])
        let loaded = await bridge.load(digest: "abc", force: false)
        #expect(loaded?.chunks.first?.source == "paper.pdf")
        #expect(loaded?.vectors?.first == [0.5, 0.25])
        #expect(await bridge.load(digest: "abc", force: true) == nil)
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/paper.pdf"))
        job.cacheStatus = "hit"
        job.totalTime = 1
        #expect(job.timingSummary?.contains("cache hit") == true)
    }

    @Test @MainActor func cacheSettingsRenderAColoredScreenshot() throws {
        let light = try render(scheme: .light)
        let dark = try render(scheme: .dark)
        try light.png.write(to: URL(fileURLWithPath: "/tmp/chunky-cache.png"))
        #expect(light.colored > 20)
        #expect(dark.colored > 20)
        #expect(dark.luminance < light.luminance)
    }

    @MainActor
    private func render(scheme: ColorScheme) throws -> (png: Data, colored: Int, luminance: Double) {
        let view = ChunkCacheScreenshot(scheme: scheme)
            .frame(width: 720, height: 420)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.94))
            .environment(\.colorScheme, scheme)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let previous = NSAppearance.current
        NSAppearance.current = appearance
        defer { NSAppearance.current = previous }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let bitmap = rep.converting(to: .sRGB, renderingIntent: .relativeColorimetric) ?? rep
        var colored = 0
        var luminance = 0.0
        var samples = 0
        let stepX = max(1, bitmap.pixelsWide / 40)
        let stepY = max(1, bitmap.pixelsHigh / 40)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                if alpha > 0.1 && (red < 0.97 || green < 0.97 || blue < 0.97) {
                    colored += 1
                }
                luminance += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
                samples += 1
            }
        }
        return (png, colored, samples == 0 ? 1 : luminance / Double(samples))
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

private struct ChunkCacheScreenshot: View {
    var scheme: ColorScheme
    @State private var limitMB = 2048
    @State private var force = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chunk cache")
                .font(.title2.weight(.semibold))
            ChunkCacheSettingsPane(limitMB: $limitMB, onClear: {})
            Toggle("Reconvert", isOn: $force)
            Text("paper.pdf")
                .font(.headline)
            Text("12 chunks")
            Text("cache hit")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .environment(\.colorScheme, scheme)
    }
}

private struct ScriptedChunkCacheHTTP: ChunkCacheHTTP {
    var status: Int
    var body: Data

    func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
        (status, self.body)
    }
}
