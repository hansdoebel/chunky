import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct AnalyticsTests {
    @Test func historyRedactsSecretsAndDropsVectors() throws {
        let settings = IsolatedSettings.make()
        settings.qdrantAPIKey = "super-secret-key-12345"
        settings.workerToken = "worker-token-abcdef"
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/paper.pdf"))
        job.chunksCount = 4
        job.totalTime = 2
        job.conversionTime = 1
        job.embeddingTime = 0.5
        job.uploadTime = 0.2
        job.embeddedCount = 4
        var metrics = JobMetrics.record(job: job, settings: settings, host: "Devbox")
        if let index = metrics.stages.firstIndex(where: { $0.name == "embedding" }) {
            metrics.stages[index].runtime = "ollama super-secret-key-12345"
        }
        job.metrics = metrics
        job.error = "upsert failed super-secret-key-12345 bearer worker-token-abcdef"
        let draft = RunDraft.make(job: job, settings: settings, contentHash: "abc")
        let stored = try JSONEncoder().encode(draft)
        let object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object["embeddings"] == nil)
        #expect(object["vectors"] == nil)
        #expect(object["qdrantAPIKey"] == nil)
        let text = String(data: stored, encoding: .utf8) ?? ""
        #expect(!text.contains("super-secret-key-12345"))
        #expect(!text.contains("worker-token-abcdef"))
        #expect(text.contains("[redacted]"))
    }

    @Test func contentHashIsStable() {
        let first = Data("same-bytes".utf8)
        #expect(RunHistory.contentHash(of: first) == RunHistory.contentHash(of: first))
        #expect(RunHistory.contentHash(of: first) != RunHistory.contentHash(of: Data("other".utf8)))
    }

    @Test func memoryStoreInsertsQueriesAndAggregates() throws {
        let store = try RunHistoryStore(inMemory: true)
        let shared = "hash-paper"
        try store.insert(sample(file: "paper.pdf", hash: shared, host: "Devbox", runtime: "docling", rate: 100, wall: 1000))
        try store.insert(sample(file: "paper.pdf", hash: shared, host: "Local Mac", runtime: "docling", rate: 40, wall: 2000))
        try store.insert(sample(file: "notes.md", hash: "hash-notes", host: "Local Mac", runtime: "ollama", rate: 80, wall: 500))

        let sameFile = try store.drafts(contentHash: shared)
        #expect(sameFile.count == 2)
        #expect(sameFile.allSatisfy { $0.fileName == "paper.pdf" })

        let byHost = try store.aggregates(by: .host)
        let devbox = try #require(byHost.first { $0.key == "Devbox" })
        let mac = try #require(byHost.first { $0.key == "Local Mac" })
        #expect(devbox.runs == 1)
        #expect(devbox.averageEmbeddingsPerSecond == 100)
        #expect(mac.runs == 2)
        #expect(mac.averageEmbeddingsPerSecond == 60)
        #expect(mac.averageWallMs == 1250)

        let byRuntime = try store.aggregates(by: .runtime)
        #expect(byRuntime.first { $0.key == "docling" }?.runs == 2)
        #expect(byRuntime.first { $0.key == "ollama" }?.runs == 1)

        let fetched = try store.allDrafts()
        let blob = fetched.map(\.encodedStages).joined()
        #expect(!blob.contains("embeddings"))
        #expect(fetched.allSatisfy { $0.errorMessage == nil })
    }

    @Test @MainActor func analyticsViewRendersAColoredScreenshot() throws {
        let runs = screenshotRuns()
        let view = AnalyticsView(runs: runs, group: .host, selectedID: runs[0].runID)
            .frame(width: 960, height: 720)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-analytics.png"))
        let bitmap = rep.converting(to: .sRGB, renderingIntent: .relativeColorimetric) ?? rep
        var colored = 0
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
            }
        }
        #expect(colored > 20)
    }

    private func sample(
        file: String,
        hash: String,
        host: String,
        runtime: String,
        rate: Double?,
        wall: Double
    ) -> RunDraft {
        RunDraft(
            fileName: file,
            contentHash: hash,
            host: host,
            runtime: runtime,
            pages: 4,
            chunks: 8,
            tokens: 100,
            embeddingsPerSecond: rate,
            wallMs: wall,
            upsertMs: 20,
            upsertStatus: "ok",
            errorMessage: nil,
            stages: [
                StageMetric(name: "convert_layout", durationMs: 10, status: "ok", runtime: "docling")
            ]
        )
    }

    private func screenshotRuns() -> [RunDraft] {
        let hash = "hash-paper"
        let stages: [StageMetric] = [
            StageMetric(name: "convert_layout", durationMs: 1200, status: "ok", runtime: "docling", pages: 12),
            StageMetric(name: "ocr", durationMs: 1200, status: "ok", runtime: "docling", pages: 12),
            StageMetric(name: "table", durationMs: 1200, status: "ok", runtime: "docling"),
            StageMetric(name: "picture_description", durationMs: 0, status: "skipped"),
            StageMetric(name: "vlm_convert", durationMs: 1200, status: "ok", runtime: "docling"),
            StageMetric(name: "chunking", durationMs: 180, status: "ok", runtime: "docling", chunks: 40),
            StageMetric(name: "embedding", durationMs: 640, status: "ok", runtime: "ollama", chunks: 40, tokens: 8200),
            StageMetric(name: "qdrant_upsert", durationMs: 240, status: "ok", runtime: "qdrant", chunks: 40),
        ]
        return [
            RunDraft(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                fileName: "paper.pdf",
                contentHash: hash,
                host: "Devbox",
                runtime: "docling",
                pages: 12,
                chunks: 40,
                tokens: 8200,
                embeddingsPerSecond: 186,
                wallMs: 3400,
                upsertMs: 240,
                upsertStatus: "ok",
                errorMessage: nil,
                stages: stages
            ),
            RunDraft(
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                fileName: "paper.pdf",
                contentHash: hash,
                host: "Local Mac",
                runtime: "docling",
                pages: 12,
                chunks: 40,
                tokens: 8200,
                embeddingsPerSecond: 42,
                wallMs: 9100,
                upsertMs: 310,
                upsertStatus: "ok",
                errorMessage: nil,
                stages: stages
            ),
            RunDraft(
                createdAt: Date(timeIntervalSince1970: 1_700_000_200),
                fileName: "scan.pdf",
                contentHash: "hash-scan",
                host: "Devbox",
                runtime: "docling",
                pages: 3,
                chunks: 6,
                tokens: 400,
                embeddingsPerSecond: nil,
                wallMs: 1500,
                upsertMs: 0,
                upsertStatus: "error",
                errorMessage: "Qdrant rejected the batch",
                stages: stages
            ),
        ]
    }
}
