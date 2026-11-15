import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct RetrievalEvalTests {
    @Test func metricsMatchKnownRankings() {
        let first = RetrievalEvalMetrics.Row(
            relevant: ["d1", "d3"],
            retrieved: ["d1", "d2", "d3", "d4"],
            latencyMs: 10
        )
        let second = RetrievalEvalMetrics.Row(
            relevant: ["d9"],
            retrieved: ["d1", "d2"],
            latencyMs: 30
        )
        #expect(RetrievalEvalMetrics.recall(relevant: first.relevant, retrieved: first.retrieved, k: 3) == 1)
        #expect(RetrievalEvalMetrics.reciprocalRank(relevant: first.relevant, retrieved: first.retrieved, k: 3) == 1)
        #expect(abs(RetrievalEvalMetrics.ndcg(relevant: first.relevant, retrieved: first.retrieved, k: 3) - 0.919720789) < 0.0001)
        #expect(RetrievalEvalMetrics.hit(relevant: first.relevant, retrieved: first.retrieved, k: 3) == 1)
        #expect(RetrievalEvalMetrics.reciprocalRank(relevant: ["d3"], retrieved: first.retrieved, k: 3) == 1.0 / 3.0)

        #expect(RetrievalEvalMetrics.recall(relevant: second.relevant, retrieved: second.retrieved, k: 3) == 0)
        #expect(RetrievalEvalMetrics.reciprocalRank(relevant: second.relevant, retrieved: second.retrieved, k: 3) == 0)
        #expect(RetrievalEvalMetrics.ndcg(relevant: second.relevant, retrieved: second.retrieved, k: 3) == 0)
        #expect(RetrievalEvalMetrics.hit(relevant: second.relevant, retrieved: second.retrieved, k: 3) == 0)
        #expect(RetrievalEvalMetrics.recall(relevant: [], retrieved: first.retrieved, k: 3) == 0)
        #expect(RetrievalEvalMetrics.ndcg(relevant: [], retrieved: first.retrieved, k: 3) == 0)
        let repeated = RetrievalEvalMetrics.ndcg(relevant: ["doc-9"], retrieved: ["doc-9", "doc-9"], k: 2)
        #expect(abs(repeated - 1) < 0.0001)

        let score = RetrievalEvalMetrics.summarize([first, second], k: 3)
        #expect(abs(score.recallAtK - 0.5) < 0.0001)
        #expect(abs(score.mrr - 0.5) < 0.0001)
        #expect(abs(score.ndcgAtK - 0.459860394) < 0.0001)
        #expect(score.hitRate == 0.5)
        #expect(score.latencyMs == 20)
        #expect(score.k == 3)
        #expect(score.queries == 2)
    }

    @Test func documentIDsCountAsRelevant() {
        let hit = RetrievalHit(
            id: "point-1",
            score: 0.8,
            text: "body",
            source: "doc-9",
            page: nil,
            headings: [],
            payload: ["document_id": "doc-9"]
        )
        let ranked = RetrievalEvalMetrics.rankedIDs(hits: [hit], relevant: ["doc-9"])
        #expect(RetrievalEvalMetrics.hit(relevant: ["doc-9"], retrieved: ranked, k: 1) == 1)
        #expect(RetrievalEvalMetrics.recall(relevant: ["doc-9"], retrieved: ranked, k: 1) == 1)
    }

    @Test func syntheticSetKeepsSourceChunkIDs() throws {
        let set = RetrievalEvalSets.synthetic(
            name: "chunks",
            chunks: [
                ("c1", "Revenue grew in 2024 after the merger."),
                ("c2", "The appendix lists the source tables."),
            ]
        )
        #expect(set.queries.count == 2)
        #expect(set.queries[0].sourceChunkID == "c1")
        #expect(set.queries[0].relevantIDs == ["c1"])
        #expect(set.queries[0].question.contains("Revenue grew"))
        let encoded = try JSONEncoder().encode(set)
        let decoded = try RetrievalEvalSets.decode(encoded)
        #expect(decoded.queries.map(\.sourceChunkID) == ["c1", "c2"])

        let manual = Data(#"{"name":"hand","queries":[{"question":"Where is revenue?","relevantIDs":["p9","doc-2"]}]}"#.utf8)
        let hand = try RetrievalEvalSets.decode(manual)
        #expect(hand.name == "hand")
        #expect(hand.queries[0].relevantIDs == ["p9", "doc-2"])
        #expect(hand.queries[0].sourceChunkID == nil)
    }

    @Test func overlapJudgeLabelsUnlabelledHits() {
        let judge = TokenOverlapJudge()
        let hits = [
            RetrievalHit(id: "p1", score: 1, text: "Revenue grew after the merger", source: "", page: nil, headings: [], payload: [:]),
            RetrievalHit(id: "p2", score: 0.2, text: "Unrelated cooking notes", source: "", page: nil, headings: [], payload: [:]),
        ]
        #expect(judge.relevantIDs(question: "revenue merger", hits: hits) == ["p1"])
    }

    @Test func runnerUsesHybridRerankAndJudgedLabels() async throws {
        let settings = IsolatedSettings.make()
        let index = EvalFakeIndex(hits: [
            SearchResult(id: "d1", score: 0.9, text: "alpha", source: "doc-1"),
            SearchResult(id: "d2", score: 0.4, text: "beta", source: "doc-2"),
            SearchResult(id: "d3", score: 0.2, text: "Revenue grew after the merger", source: "doc-3"),
        ])
        let reranker = EvalFakeReranker()
        let service = RetrievalService(
            embedding: EvalFakeEmbedding(),
            worker: EvalFakeWorker(),
            reranker: reranker
        )
        let config = RetrievalEvalConfig(
            collection: "documents",
            embeddingBackend: EmbeddingBackendKind.ollama.rawValue,
            embeddingModel: "qwen3-embedding",
            chunking: RetrievalEvalConfig.chunkingLabel(tokens: 512, overlap: 64),
            hybrid: true,
            reranker: true,
            k: 3,
            rrfWeights: [1, 0.5],
            rerank: RerankConfig(url: "https://rerank.example/v1", model: "jina-reranker", apiKey: "secret")
        )
        let set = RetrievalEvalSet(name: "mix", queries: [
            RetrievalEvalQuery(question: "labelled", relevantIDs: ["d1", "d3"]),
            RetrievalEvalQuery(question: "revenue merger", relevantIDs: []),
        ])
        let draft = try await RetrievalEvalRunner(service: service).run(
            set: set,
            config: config,
            settings: settings,
            index: index
        )
        #expect(index.hybridCalls == 2)
        #expect(index.denseCalls == 0)
        #expect(reranker.calls == 2)
        #expect(reranker.lastModel == "jina-reranker")
        #expect(draft.hybrid)
        #expect(draft.reranker)
        #expect(draft.chunking == "512/64")
        #expect(draft.embeddingModel == "qwen3-embedding")
        #expect(draft.score.queries == 2)
        #expect(draft.score.recallAtK == 1)
        #expect(draft.score.hitRate == 1)
        #expect(draft.score.latencyMs >= 0)
        #expect(draft.label.contains("hybrid"))
        #expect(draft.label.contains("rerank"))
        #expect(draft.label.contains("k3"))
        #expect(draft.setIdentity == RetrievalEvalSets.identity(name: set.name, queries: set.queries))
    }

    @Test func memoryStorePersistsEvalRunsAndComparesSetups() throws {
        let store = try RunHistoryStore(inMemory: true)
        let dense = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: false, reranker: false, recall: 0.4, latency: 40)
        let hybrid = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: true, reranker: false, recall: 0.6, latency: 50)
        let again = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: true, reranker: false, recall: 0.8, latency: 70)
        let reranked = sample(model: "qwen3-embedding", chunking: "256/32", hybrid: true, reranker: true, recall: 0.9, latency: 90)
        let tighter = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: true, reranker: false, recall: 0.2, latency: 10, k: 1)
        let otherSet = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: true, reranker: false, recall: 0.2, latency: 10, setIdentity: "other#ffff")
        try store.insert(dense)
        try store.insert(hybrid)
        try store.insert(again)
        try store.insert(reranked)
        try store.insert(tighter)
        try store.insert(otherSet)

        let loaded = try store.evalDrafts()
        #expect(loaded.count == 6)
        #expect(loaded.map(\.score.recallAtK).contains(0.9))
        let compared = RetrievalEvalHistory.compare(loaded)
        let fused = try #require(compared.first { $0.label.contains("· k10 ·") && $0.label.contains("hybrid") && $0.label.contains("no rerank") && $0.label.contains("finance#ab") })
        #expect(fused.runs == 2)
        #expect(abs(fused.recallAtK - 0.7) < 0.0001)
        #expect(abs(fused.latencyMs - 60) < 0.0001)
        #expect(compared.contains { $0.label.contains("256/32") && $0.label.contains("rerank") && !$0.label.contains("no rerank") })
        #expect(compared.contains { $0.label.contains("dense") })
        #expect(compared.contains { $0.label.contains("· k1 ·") && $0.runs == 1 })
        #expect(compared.contains { $0.label.contains("other#ffff") && $0.runs == 1 })
        #expect(try store.allDrafts().isEmpty)
    }

    @Test func differentScopesStaySeparateComparisons() throws {
        let store = try RunHistoryStore(inMemory: true)
        let open = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: false, reranker: false, recall: 0.4, latency: 40)
        var year = sample(model: "qwen3-embedding", chunking: "512/64", hybrid: false, reranker: false, recall: 0.8, latency: 40)
        year.scope = RetrievalFilter.scopeLabel(RetrievalFilter.scope(yearFrom: "2020", yearTo: "2024", author: "Ada"))
        var author = year
        author.scope = RetrievalFilter.scopeLabel(RetrievalFilter.scope(author: "Bea"))
        author.score.recallAtK = 0.2
        try store.insert(open)
        try store.insert(year)
        try store.insert(author)
        let loaded = try store.evalDrafts()
        #expect(loaded.contains { $0.scope == year.scope })
        let compared = RetrievalEvalHistory.compare(loaded)
        #expect(compared.count == 3)
        #expect(compared.contains { $0.label.contains("year:") && $0.label.contains("authors:~Ada") && $0.runs == 1 })
        #expect(compared.contains { $0.label.contains("authors:~Bea") && $0.runs == 1 })
        #expect(compared.contains { $0.runs == 1 && !$0.label.contains("authors:") })
    }

    @Test @MainActor func evalViewRendersAColoredScreenshot() throws {
        let runs = [
            sample(model: "qwen3-embedding", chunking: "512/64", hybrid: false, reranker: false, recall: 0.42, latency: 40),
            sample(model: "qwen3-embedding", chunking: "512/64", hybrid: true, reranker: false, recall: 0.61, latency: 55),
            sample(model: "qwen3-embedding", chunking: "256/32", hybrid: true, reranker: true, recall: 0.74, latency: 80),
            sample(model: "text-embedding-3-large", chunking: "512/64", hybrid: true, reranker: true, recall: 0.69, latency: 70),
        ]
        let queries = [
            RetrievalEvalQuery(question: "Where is revenue reported?", relevantIDs: ["p1"], sourceChunkID: "p1"),
            RetrievalEvalQuery(question: "Which appendix lists tables?", relevantIDs: []),
        ]
        let config = RetrievalEvalConfig(
            collection: "documents",
            embeddingBackend: "ollama",
            embeddingModel: "qwen3-embedding",
            chunking: "512/64",
            hybrid: true,
            reranker: true,
            k: 10,
            rrfWeights: nil,
            rerank: nil
        )
        let light = try render(runs: runs, queries: queries, config: config, scheme: .light)
        let dark = try render(runs: runs, queries: queries, config: config, scheme: .dark)
        try light.png.write(to: URL(fileURLWithPath: "/tmp/chunky-eval.png"))
        #expect(light.colored > 20)
        #expect(dark.colored > 20)
        #expect(dark.luminance < light.luminance)
    }

    @MainActor
    private func render(
        runs: [RetrievalEvalDraft],
        queries: [RetrievalEvalQuery],
        config: RetrievalEvalConfig,
        scheme: ColorScheme
    ) throws -> (png: Data, colored: Int, luminance: Double) {
        let view = RetrievalEvalView(
            setName: "finance",
            queries: queries,
            config: config,
            runs: runs,
            status: "Recall@10 0.740 · MRR 0.680 · nDCG 0.710 · hit 0.900 · 80 ms",
            metric: .recall,
            scrolls: false
        )
        .frame(width: 960, height: 720)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.94))
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
        let detailStart = bitmap.pixelsWide / 3
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: detailStart, to: bitmap.pixelsWide, by: stepX) {
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

    private func sample(
        model: String,
        chunking: String,
        hybrid: Bool,
        reranker: Bool,
        recall: Double,
        latency: Double,
        k: Int = 10,
        setIdentity: String = "finance#ab"
    ) -> RetrievalEvalDraft {
        RetrievalEvalDraft(
            setName: "finance",
            embeddingModel: model,
            chunking: chunking,
            hybrid: hybrid,
            reranker: reranker,
            setIdentity: setIdentity,
            score: RetrievalEvalScore(
                recallAtK: recall,
                mrr: recall - 0.05,
                ndcgAtK: recall - 0.02,
                hitRate: min(1, recall + 0.1),
                latencyMs: latency,
                k: k,
                queries: 4
            )
        )
    }

    @Test func evalSearchSendsTheSameScopeFilter() async throws {
        let settings = IsolatedSettings.make()
        let index = EvalFakeIndex(hits: [
            SearchResult(id: "d1", score: 0.9, text: "alpha", source: "doc-1"),
        ])
        let service = RetrievalService(embedding: EvalFakeEmbedding(), worker: EvalFakeWorker())
        let filters = RetrievalFilter.scope(yearFrom: "2020", yearTo: "2024", author: "Ada")
        let config = RetrievalEvalConfig(
            collection: "documents",
            embeddingBackend: EmbeddingBackendKind.ollama.rawValue,
            embeddingModel: "qwen3-embedding",
            chunking: "512/64",
            hybrid: false,
            reranker: false,
            k: 3,
            rrfWeights: nil,
            rerank: nil,
            filters: filters
        )
        _ = try await RetrievalEvalRunner(service: service).run(
            set: RetrievalEvalSet(name: "scope", queries: [RetrievalEvalQuery(question: "revenue", relevantIDs: ["d1"])]),
            config: config,
            settings: settings,
            index: index
        )
        let encoded = RetrievalFilter.encodedSummaries(filters)
        #expect(encoded.map(\.key) == ["year", "authors"])
        #expect(index.lastFilter?.must.count == 2)
        #expect(index.denseCalls == 1)
    }
}

private struct EvalFakeEmbedding: RetrievalEmbedding {
    func probe(backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> Int { 4 }
    func embed(text: String, backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> [Float] {
        [1, 0, 0, 0]
    }
}

private final class EvalFakeIndex: RetrievalIndex {
    var hits: [SearchResult]
    var hybridCalls = 0
    var denseCalls = 0

    init(hits: [SearchResult]) {
        self.hits = hits
    }

    func vectorSize(collection: String) async throws -> Int? { 4 }
    func vectorName(collection: String) async throws -> String? { "dense" }
    var lastFilter: RetrievalQueryFilter?

    func denseSearch(
        collection: String,
        vector: [Float],
        limit: Int,
        offset: Int,
        filter: RetrievalQueryFilter?,
        vectorName: String?
    ) async throws -> [SearchResult] {
        denseCalls += 1
        lastFilter = filter
        return hits
    }

    func hybridRRF(collection: String, url: String, apiKey: String, body: [String: Any]) async throws -> [SearchResult] {
        hybridCalls += 1
        return hits
    }
}

private final class EvalFakeReranker: Reranker {
    var calls = 0
    var lastModel = ""

    func rerank(config: RerankConfig, query: String, documents: [String], topN: Int) async throws -> [RerankScore] {
        calls += 1
        lastModel = config.model
        return documents.indices.map { RerankScore(index: $0, score: Double(documents.count - $0)) }
    }
}

private struct EvalFakeWorker: RetrievalWorker {
    func search(baseURL: String, token: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
        (500, Data())
    }
}
