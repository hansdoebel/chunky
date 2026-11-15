import AppKit
import SwiftUI
import Testing

@testable import Chunky

struct BenchmarkTests {
    @Test func matrixCoversHostsRuntimesAndSamplesWithoutTheProductionCollection() {
        let hosts: [ProcessingHost] = [.localMac, .devbox]
        let runtimes = [
            BenchmarkRuntime(id: "embed", label: "Embed only", embeddingModel: "qwen3-embedding", embeddingBackend: "ollama", vlmModel: "standard", ocr: false),
            BenchmarkRuntime(id: "ocr", label: "OCR", embeddingModel: "qwen3-embedding", embeddingBackend: "ollama", vlmModel: "standard", ocr: true),
        ]
        let samples = Array(BenchmarkPlanner.samples.prefix(3))
        let cells = BenchmarkPlanner.cells(hosts: hosts, runtimes: runtimes, samples: samples)
        #expect(cells.count == hosts.count * runtimes.count * samples.count * 2)
        #expect(cells.filter { $0.phase == .warmup }.count == cells.filter { $0.phase == .timed }.count)
        let pairs = Dictionary(grouping: cells) { "\($0.host.rawValue)|\($0.runtime.id)|\($0.sample.id)" }
        #expect(pairs.count == hosts.count * runtimes.count * samples.count)
        #expect(pairs.values.allSatisfy { Set($0.map(\.phase)) == Set([BenchmarkPhase.warmup, .timed]) })
        let production = "documents"
        let collection = BenchmarkPlanner.collectionName(production: production)
        #expect(BenchmarkPlanner.accepts(collection: collection, production: production))
        #expect(collection != production)
        #expect(BenchmarkPlanner.cells(hosts: [], runtimes: runtimes, samples: samples).isEmpty)
    }

    @Test func benchmarkCopyLeavesTheProductionCollectionAlone() {
        let settings = IsolatedSettings.make()
        settings.defaultCollection = "documents"
        settings.embeddingModel = "qwen3-embedding"
        settings.doclingModel = "standard"
        settings.qdrantAPIKey = "super-secret-key-12345"
        let runtime = BenchmarkRuntime(id: "ocr", label: "OCR", embeddingModel: "other-model", embeddingBackend: "ollama", vlmModel: "standard", ocr: true)
        let copy = settings.benchmarkCopy(collection: "chunky-benchmark-abcd1234", host: .devbox, runtime: runtime)
        #expect(settings.defaultCollection == "documents")
        #expect(copy.defaultCollection == "chunky-benchmark-abcd1234")
        #expect(copy.processingHost == .devbox)
        #expect(copy.embeddingModel == "other-model")
        #expect(copy.doOCR == true)
        #expect(copy.devboxIngestTarget == .localDocker)
        #expect(copy.qdrantAPIKey == "super-secret-key-12345")
        #expect(BenchmarkPlanner.accepts(collection: copy.defaultCollection, production: settings.defaultCollection))
    }

    @Test @MainActor func benchmarkViewRendersAColoredScreenshot() throws {
        let runtimes = [
            BenchmarkRuntime(id: "embed", label: "Embed only", embeddingModel: "qwen3-embedding", embeddingBackend: "ollama", vlmModel: "standard", ocr: false),
            BenchmarkRuntime(id: "ocr", label: "OCR", embeddingModel: "qwen3-embedding", embeddingBackend: "ollama", vlmModel: "standard", ocr: true),
        ]
        let view = BenchmarkView(
            hosts: [.localMac, .devbox],
            runtimes: runtimes,
            samples: BenchmarkPlanner.samples,
            selectedHosts: ["Devbox"],
            selectedRuntimes: ["embed", "ocr"],
            productionCollection: "documents",
            collectionName: "chunky-benchmark-abcd1234",
            status: "Idle",
            scrolls: false
        )
        .frame(width: 720, height: 860)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-benchmark.png"))
        let bitmap = rep.converting(to: .sRGB, renderingIntent: .relativeColorimetric) ?? rep
        var colored = 0
        let stepX = max(1, bitmap.pixelsWide / 30)
        let stepY = max(1, bitmap.pixelsHigh / 30)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                if alpha > 0.1 && (red < 0.93 || green < 0.93 || blue < 0.93) {
                    colored += 1
                }
            }
        }
        #expect(colored > 15)
    }
}
