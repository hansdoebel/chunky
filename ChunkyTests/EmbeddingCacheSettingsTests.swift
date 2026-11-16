import AppKit
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct EmbeddingCacheSettingsTests {
    @Test func chunkVectorsRemainIndependentOfStreamingAndQdrantReuse() async throws {
        let settings = IsolatedSettings.make()
        settings.embeddingModel = "test-model"
        settings.embeddingDimensions = 2
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ChunkCacheBridge(settings: settings, directory: root, remote: nil)
        try bridge.store(
            digest: "abc",
            document: Data("{}".utf8),
            chunks: [ChunkCacheChunk.normalize(["text": "unchanged", "source": "paper.pdf"])],
            vectors: [[0.5, 0.25]]
        )
        for streaming in [true, false] {
            for reuse in [true, false] {
                settings.streamingPipeline = streaming
                settings.enableEmbeddingCache = reuse
                #expect(await bridge.load(digest: "abc", force: false)?.vectors == [[0.5, 0.25]])
            }
        }
        settings.embeddingDimensions = 3
        let differentDimensions = await bridge.load(digest: "abc", force: false)
        #expect(differentDimensions?.chunks.count == 1)
        #expect(differentDimensions?.vectors == nil)
        settings.embeddingDimensions = 2
        settings.embeddingModel = "other-model"
        #expect(await bridge.load(digest: "abc", force: false)?.vectors == nil)
        #expect(await bridge.load(digest: "abc", force: true) == nil)
    }

    @Test func rendersStreamingSequentialAndWorkerCacheControls() throws {
        for (name, streaming, host) in [
            ("streaming", true, ProcessingHost.localMac),
            ("sequential", false, ProcessingHost.localMac),
            ("worker", false, ProcessingHost.devbox),
        ] {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text("Embedding performance").font(.title2)
                EmbeddingCacheSettingsPane(
                    streaming: .constant(streaming),
                    reuseEmbeddings: .constant(true),
                    host: host
                )
            }
            .padding(24)
            .frame(width: 620, height: 330, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            var darkPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent < 0.6 && color.greenComponent < 0.6 && color.blueComponent < 0.6 {
                        darkPixels += 1
                    }
                }
            }
            #expect(darkPixels > 100)
            try png.write(to: URL(fileURLWithPath: "/tmp/chunky-embedding-cache-\(name).png"))
        }
    }
}
