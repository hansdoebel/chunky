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
        settings.doclingAccelerator = "cuda"
        settings.enableEmbeddingCache = true
        settings.qdrantAPIKey = "super-secret-key-12345"
        let runtime = BenchmarkRuntime(id: "ocr", label: "OCR", embeddingModel: "other-model", embeddingBackend: "ollama", vlmModel: "standard", ocr: true)
        let copy = settings.benchmarkCopy(collection: "chunky-benchmark-abcd1234", host: .devbox, runtime: runtime)
        #expect(settings.defaultCollection == "documents")
        #expect(copy.defaultCollection == "chunky-benchmark-abcd1234")
        #expect(copy.processingHost == .devbox)
        #expect(copy.doclingAccelerator == ProcessingHost.devbox.defaultAccelerator.rawValue)
        #expect(copy.enableEmbeddingCache == false)
        #expect(settings.doclingAccelerator == "cuda")
        #expect(settings.enableEmbeddingCache == true)
        let mac = settings.benchmarkCopy(collection: "chunky-benchmark-mac", host: .localMac, runtime: runtime)
        #expect(mac.doclingAccelerator == ProcessingHost.localMac.defaultAccelerator.rawValue)
        #expect(copy.embeddingModel == "other-model")
        #expect(copy.doOCR == true)
        #expect(copy.devboxIngestTarget == .localDocker)
        #expect(copy.qdrantAPIKey == "super-secret-key-12345")
        #expect(BenchmarkPlanner.accepts(collection: copy.defaultCollection, production: settings.defaultCollection))
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/paper.pdf"))
        job.analyticsRuntime = "OCR"
        job.totalTime = 1
        let draft = RunDraft.make(job: job, settings: settings, contentHash: "abc")
        #expect(draft.runtime == "OCR")
        #expect(BenchmarkPlanner.summary(completed: 2, failed: 1, skipped: 3, cancelled: true) == "Cancelled. 2 completed, 1 failed, 3 skipped.")
        #expect(BenchmarkPlanner.summary(completed: 4, failed: 0, skipped: 0, cancelled: false) == "4 completed.")
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


struct EmbeddingBenchmarkReportTests {
    static func fixture() -> EmbeddingBenchmarkReport {
        let query = RetrievalEvalQuery(question: "Which paper?", relevantIDs: ["paper-1"])
        let hash = String(repeating: "a", count: 64)
        let runs = ["potion", "qwen3"].flatMap { model in
            [false, true].map { hybrid in
                EmbeddingBenchmarkReport.Run(
                    id: UUID(), corpusSHA256: hash, model: model, modelRevision: "fixed-revision",
                    dimensions: model == "potion" ? 512 : 1024, machine: model == "potion" ? "Mac Studio CPU" : "R9700",
                    runtime: model == "potion" ? "FastEmbed CPU" : "Ollama ROCm",
                    collection: "chunky-benchmark-\(model)", hybrid: hybrid,
                    coldStartupMs: 50, warmStartupMs: 2, embeddingSeconds: 1, indexingSeconds: 2,
                    peakMemoryBytes: 1_048_576,
                    results: [.init(queryID: query.id, retrievedIDs: ["other", "paper-1"], latencyMs: 3)]
                )
            }
        }
        return EmbeddingBenchmarkReport(schemaVersion: 1, corpusSHA256: hash, chunkCount: 10, chunking: "Synthetic UI fixture, not benchmark measurements", set: RetrievalEvalSet(name: "Labeled papers", queries: [query]), runs: runs)
    }

    @Test func comparisonRoundTripsAndReusesEvalMetrics() throws {
        let report = Self.fixture()
        let decoded = try EmbeddingBenchmarkReport.decode(JSONEncoder().encode(report), productionCollection: "production")
        #expect(decoded == report)
        let score = decoded.runs[0].score(set: decoded.set)
        #expect(score.recallAtK == 1)
        #expect(score.mrr == 0.5)
        #expect(score.hitRate == 1)
        #expect(score.latencyMs == 3)
        #expect(score.ndcgAtK > 0.6 && score.ndcgAtK < 0.7)
    }

    @Test(arguments: 0..<16) func refusesIncomparableOrInvalidReports(kind: Int) {
        var report = Self.fixture()
        switch kind {
        case 0: report.runs[0].corpusSHA256 = String(repeating: "b", count: 64)
        case 1: report.runs[0].collection = "production"
        case 2: report.runs[0].dimensions = 0
        case 3: report.runs[0].modelRevision = ""
        case 4: report.runs[0].results = []
        case 5: report.runs[0].results[0].queryID = UUID()
        case 6: report.runs[0].embeddingSeconds = 0
        case 7: report.runs[0].results[0].latencyMs = .infinity
        case 8: report.runs.removeAll { $0.hybrid }
        case 9: report.set.queries.append(report.set.queries[0])
        case 10: report.runs[0].peakMemoryBytes = 0
        case 11: report.runs[0].results[0].retrievedIDs = ["paper-1", "paper-1"]
        case 12: report.runs[0].indexingSeconds = 0.5
        case 13: report.runs[0].collection = report.runs[2].collection
        case 14: report.schemaVersion = 2
        default: report.runs = []
        }
        #expect(throws: (any Error).self) { try report.validate(productionCollection: "production") }
    }

    @Test @MainActor func comparisonScreenshotIsNotBlank() throws {
        let renderer = ImageRenderer(content: EmbeddingBenchmarkResults(report: Self.fixture()).padding().frame(width: 1100).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-embedding-benchmark.png"))
        var darkPixels = 0
        var lightPixels = 0
        var transparentPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent < 0.99 { transparentPixels += 1 }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if color.alphaComponent > 0.99 && brightness < 0.6 { darkPixels += 1 }
                if color.alphaComponent > 0.99 && brightness > 0.95 { lightPixels += 1 }
            }
        }
        #expect(darkPixels > 100)
        #expect(lightPixels > 100)
        #expect(transparentPixels == 0)
    }
}
