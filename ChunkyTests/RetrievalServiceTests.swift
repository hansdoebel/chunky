import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct RetrievalServiceTests {

    @Test func requestForLocalMacOmitsTheCloudKey() {
        let settings = IsolatedSettings.make()
        settings.processingHost = .localMac
        settings.defaultCollection = "documents"
        settings.embeddingBackend = EmbeddingBackendKind.ollama.rawValue
        settings.embeddingModel = "qwen3-embedding"
        settings.ollamaURL = "http://127.0.0.1:11434"
        settings.qdrantURL = "http://127.0.0.1:6334"
        settings.qdrantAPIKey = "local-secret"
        settings.workerToken = "worker-secret"

        let request = RetrievalRequest.make(
            text: "  revenue  ",
            collection: "documents",
            limit: 8,
            filters: RetrievalFilter.playground(source: "paper.pdf", page: "2", contentType: "text"),
            settings: settings
        )

        #expect(request.route == .localQdrant)
        #expect(request.text == "revenue")
        #expect(request.qdrantURL == "http://127.0.0.1:6334")
        #expect(request.qdrantAPIKey == "local-secret")
        #expect(request.embeddingBackend == "ollama")
        #expect(request.filters.count == 3)
        let json = request.workerJSON()
        #expect(json["qdrant_api_key"] == nil)
        #expect(json["query"] as? String == "revenue")
        #expect(json["limit"] as? Int == 8)
    }

    @Test func devboxCloudRequestUsesTheWorkerAndSendsItsOwnKey() throws {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .qdrantCloud
        settings.devboxWorkerURL = "http://10.0.0.8:8080"
        settings.workerToken = "worker-secret"
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io"
        settings.qdrantAPIKey = "cloud-secret"
        settings.embeddingBackend = EmbeddingBackendKind.openai.rawValue
        settings.embeddingAPIURL = "http://127.0.0.1:8002"
        settings.embeddingModel = "Qwen/Qwen3-Embedding-0.6B"

        let request = RetrievalRequest.make(
            text: "revenue",
            collection: "documents",
            limit: 5,
            offset: 10,
            filters: [RetrievalFilter(key: "year", gte: 2020, lte: 2024)],
            settings: settings
        )

        #expect(request.route == .worker)
        #expect(request.qdrantURL == "https://example.cloud.qdrant.io")
        #expect(request.qdrantAPIKey == "cloud-secret")
        #expect(request.embeddingURL == "http://127.0.0.1:8002")
        let json = request.workerJSON()
        let data = try JSONSerialization.data(withJSONObject: json)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["qdrant_url"] as? String == "https://example.cloud.qdrant.io")
        #expect(object["qdrant_api_key"] as? String == "cloud-secret")
        #expect(object["embedding_backend"] as? String == "openai")
        #expect(object["offset"] as? Int == 10)
        let filters = try #require(object["filters"] as? [[String: Any]])
        #expect(filters.count == 1)
        #expect(filters[0]["key"] as? String == "year")
        #expect(filters[0]["gte"] as? Double == 2020)
        #expect(filters[0]["lte"] as? Double == 2024)
        #expect(String(data: data, encoding: .utf8)?.contains("worker-secret") == false)
    }

    @Test func filterEncodingMatchesSourcePageAndContentType() {
        let filters = RetrievalFilter.playground(source: "paper.pdf", page: "2", contentType: "table")
            + [RetrievalFilter(key: "year", gte: 2020, lte: 2024)]
        let encoded = RetrievalFilter.encodedSummaries(filters)
        #expect(encoded.count == 4)
        #expect(encoded[0] == EncodedFilterSummary(key: "source", keyword: "paper.pdf"))
        #expect(encoded[1] == EncodedFilterSummary(key: "page", integer: 2))
        #expect(encoded[2] == EncodedFilterSummary(key: "content_type", keyword: "table"))
        #expect(encoded[3] == EncodedFilterSummary(key: "year", gte: 2020, lte: 2024))
        #expect(RetrievalFilter.encodedSummaries([]).isEmpty)
    }

    @Test func localDimensionMismatchRefusesBeforeSearch() async {
        let embedding = FakeEmbedding(probeSize: 3, vector: [0.1, 0.2, 0.3])
        let index = FakeIndex(vectorSize: 1024)
        let worker = FakeWorker()
        let service = RetrievalService(embedding: embedding, worker: worker)
        let request = localRequest()
        do {
            _ = try await service.search(request, index: index)
            Issue.record("mismatch was accepted")
        } catch let error as RetrievalError {
            guard case .dimensionMismatch(let collection, let existing, let probed, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(collection == "documents")
            #expect(existing == 1024)
            #expect(probed == 3)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(index.searchCalls == 0)
        #expect(embedding.embedCalls == 0)
        #expect(worker.calls == 0)
    }

    @Test func localSearchMapsHitsAndPassesTheFilter() async throws {
        let embedding = FakeEmbedding(probeSize: 3, vector: [0.1, 0.2, 0.3])
        let index = FakeIndex(
            vectorSize: 3,
            hits: [
                SearchResult(id: "p1", score: 0.91, text: "Revenue grew.", source: "paper.pdf", page: 2, headings: ["Intro"], metadata: ["content_type": "text"])
            ]
        )
        let service = RetrievalService(embedding: embedding, worker: FakeWorker())
        var request = localRequest()
        request.filters = RetrievalFilter.playground(source: "paper.pdf", page: "2", contentType: "text")
        request.limit = 1
        let page = try await service.search(request, index: index)
        #expect(page.route == .localQdrant)
        #expect(page.embeddingDim == 3)
        #expect(page.nextOffset == 2)
        #expect(page.hits[0].text == "Revenue grew.")
        #expect(page.hits[0].page == 2)
        #expect(page.hits[0].headings == ["Intro"])
        #expect(page.hits[0].payload["content_type"] == "text")
        #expect(page.hits[0].payload["source"] == "paper.pdf")
        #expect(RetrievalFilter.encodedSummaries(request.filters).count == 3)
        #expect(index.lastOffset == 1)
        #expect(page.statusLine.contains("limit 1"))
        #expect(page.statusLine.contains("1000"))
    }

    @Test func workerResponseMapsPayloadAndRejectsAMismatch() async throws {
        let worker = FakeWorker(status: 200, body: workerPageJSON())
        let service = RetrievalService(embedding: FakeEmbedding(probeSize: 3, vector: [1]), worker: worker)
        let settings = cloudSettings()
        let request = RetrievalRequest.make(text: "revenue", collection: "documents", limit: 8, settings: settings)
        let page = try await service.search(request, index: nil)
        #expect(page.route == .worker)
        #expect(page.hits[0].score == 0.91)
        #expect(page.hits[0].text == "Revenue grew.")
        #expect(page.hits[0].source == "paper.pdf")
        #expect(page.hits[0].page == 2)
        #expect(page.hits[0].headings == ["Intro", "Results"])
        #expect(page.hits[0].payload["content_type"] == "text")
        #expect(page.embeddingDim == 1024)
        #expect(page.nextOffset == nil)
        let sent = try #require(worker.bodies.first)
        #expect(sent["qdrant_api_key"] as? String == "cloud-secret")
        #expect(worker.tokens == ["worker-secret"])

        worker.status = 409
        worker.body = Data("{\"detail\":\"Collection documents has vector size 1024, but qwen3-embedding produces vectors of size 3.\",\"error_type\":\"dimension_mismatch\"}".utf8)
        do {
            _ = try await service.search(request, index: nil)
            Issue.record("worker mismatch was accepted")
        } catch let error as RetrievalError {
            guard case .dimensionMismatch(_, let existing, let probed, let detail) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(existing == 1024)
            #expect(probed == 3)
            #expect(detail.contains("vector size 1024"))
        }
    }

    @Test func devboxLocalDockerSearchesOnTheMac() {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .localDocker
        settings.devboxWorkerURL = "http://10.0.0.8:8080"
        settings.qdrantURL = "http://localhost:6334"
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io"
        let request = RetrievalRequest.make(text: "revenue", collection: "documents", limit: 8, settings: settings)
        #expect(request.route == .localQdrant)
        #expect(request.qdrantURL == "http://localhost:6334")
        #expect(request.workerJSON()["qdrant_url"] == nil)
    }

    @Test func namedDenseVectorIsPassedToSearch() async throws {
        let index = FakeIndex(vectorSize: 3, hits: [
            SearchResult(id: "p1", score: 0.2, text: "t", source: "s", page: nil, headings: [], metadata: [:])
        ])
        index.reportedName = "dense"
        let service = RetrievalService(embedding: FakeEmbedding(probeSize: 3, vector: [0.1, 0.2, 0.3]), worker: FakeWorker())
        _ = try await service.search(localRequest(), index: index)
        #expect(index.lastSeenName == "dense")
    }

    @Test func hybridBodyUsesTextQueryAndOptionalRRFWeights() throws {
        let weighted = HybridQuery.body(
            vector: [0.1, 0.2],
            text: "revenue by year",
            denseUsing: "dense",
            limit: 8,
            offset: 2,
            weights: [0.7, 0.3]
        )
        let prefetch = try #require(weighted["prefetch"] as? [[String: Any]])
        #expect(prefetch[0]["using"] as? String == "dense")
        #expect(prefetch[0]["query"] as? [Float] == [0.1, 0.2])
        let lexical = try #require(prefetch[1]["query"] as? [String: String])
        #expect(lexical["text"] == "revenue by year")
        #expect(prefetch[1]["using"] as? String == "text")
        #expect(prefetch[0]["limit"] as? Int == 10)
        #expect(prefetch[1]["limit"] as? Int == 10)
        let query = try #require(weighted["query"] as? [String: Any])
        let rrf = try #require(query["rrf"] as? [String: Any])
        #expect(rrf["weights"] as? [Double] == [0.7, 0.3])
        let filtered = HybridQuery.body(
            vector: [0.1],
            text: "revenue",
            denseUsing: "dense",
            limit: 4,
            offset: 0,
            weights: nil,
            filters: RetrievalFilter.playground(source: "paper.pdf", page: "2", contentType: "text")
        )
        let filteredPrefetch = try #require(filtered["prefetch"] as? [[String: Any]])
        let must = try #require((filteredPrefetch[0]["filter"] as? [String: Any])?["must"] as? [[String: Any]])
        #expect(must.count == 3)
        let plain = HybridQuery.body(vector: [0.1], text: "revenue", denseUsing: nil, limit: 4, offset: 0, weights: nil)
        let plainQuery = try #require(plain["query"] as? [String: Any])
        let plainRRF = try #require(plainQuery["rrf"] as? [String: Any])
        #expect(plainRRF["weights"] == nil)
        let data = Data("{\"result\":{\"points\":[{\"id\":\"p1\",\"score\":0.5,\"payload\":{\"text\":\"Revenue\",\"source\":\"a.pdf\",\"page\":3}}]}}".utf8)
        let hits = try HybridQuery.hits(from: data)
        #expect(hits[0].text == "Revenue")
        #expect(hits[0].page == 3)
        #expect(RetrievalScreen.weights(dense: "", lexical: "") == nil)
        #expect(RetrievalScreen.weights(dense: "0.7", lexical: "0.3") == [0.7, 0.3] as [Double]?)
    }

    @Test func invalidLimitIsRejected() async {
        let service = RetrievalService(embedding: FakeEmbedding(probeSize: 3, vector: [1]), worker: FakeWorker())
        var request = localRequest()
        request.limit = RetrievalLimits.maximum + 1
        await #expect(throws: RetrievalError.invalidLimit(101)) {
            try await service.search(request, index: FakeIndex(vectorSize: 3))
        }
    }

    @Test @MainActor func retrievalPlaygroundRendersAColoredScreenshot() throws {
        let hits = [
            RetrievalHit(
                id: "p1",
                score: 0.912,
                text: "Revenue grew after the hybrid index was enabled.",
                source: "paper.pdf",
                page: 2,
                headings: ["Intro", "Results"],
                payload: ["text": "Revenue grew after the hybrid index was enabled.", "source": "paper.pdf", "page": "2", "headings": "Intro > Results", "content_type": "text"]
            ),
            RetrievalHit(
                id: "p2",
                score: 0.640,
                text: "Table 1 lists quarterly revenue.",
                source: "paper.pdf",
                page: 4,
                headings: ["Tables"],
                payload: ["text": "Table 1 lists quarterly revenue.", "source": "paper.pdf", "page": "4", "content_type": "table"]
            ),
        ]
        let light = try render(hits: hits, scheme: .light)
        let dark = try render(hits: hits, scheme: .dark)
        try light.png.write(to: URL(fileURLWithPath: "/tmp/chunky-retrieval.png"))
        #expect(light.colored > 20)
        #expect(dark.colored > 20)
        #expect(dark.luminance < light.luminance)
    }

    @MainActor
    private func render(hits: [RetrievalHit], scheme: ColorScheme) throws -> (png: Data, colored: Int, luminance: Double) {
        let view = RetrievalScreenshotHost(hits: hits)
            .frame(width: 960, height: 640)
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

    private func localRequest() -> RetrievalRequest {
        let settings = IsolatedSettings.make()
        settings.processingHost = .localMac
        settings.embeddingModel = "qwen3-embedding"
        settings.qdrantURL = "http://127.0.0.1:6334"
        return RetrievalRequest.make(text: "revenue", collection: "documents", limit: 8, offset: 1, settings: settings)
    }

    private func cloudSettings() -> AppSettings {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .qdrantCloud
        settings.devboxWorkerURL = "http://10.0.0.8:8080"
        settings.workerToken = "worker-secret"
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io"
        settings.qdrantAPIKey = "cloud-secret"
        settings.embeddingModel = "qwen3-embedding"
        return settings
    }

    private func workerPageJSON() -> Data {
        let object: [String: Any] = [
            "results": [[
                "id": "p1",
                "score": 0.91,
                "payload": [
                    "text": "Revenue grew.",
                    "source": "paper.pdf",
                    "page": 2,
                    "headings": ["Intro", "Results"],
                    "content_type": "text",
                ],
            ]],
            "limit": 8,
            "offset": 0,
            "next_offset": NSNull(),
            "embedding_model": "qwen3-embedding",
            "embedding_backend": "ollama",
            "embedding_dim": 1024,
            "collection": "documents",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

}

private final class FakeEmbedding: RetrievalEmbedding {
    var probeSize: Int
    var vector: [Float]
    var embedCalls = 0

    init(probeSize: Int, vector: [Float]) {
        self.probeSize = probeSize
        self.vector = vector
    }

    func probe(backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> Int {
        probeSize
    }

    func embed(text: String, backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> [Float] {
        embedCalls += 1
        return vector
    }
}

private final class FakeIndex: RetrievalIndex {
    var vectorSize: Int?
    var hits: [SearchResult]
    var searchCalls = 0
    var lastOffset: Int?

    init(vectorSize: Int?, hits: [SearchResult] = []) {
        self.vectorSize = vectorSize
        self.hits = hits
    }

    func vectorSize(collection: String) async throws -> Int? {
        vectorSize
    }

    var reportedName: String?
    var lastSeenName: String?

    func vectorName(collection: String) async throws -> String? {
        reportedName
    }

    func denseSearch(
        collection: String,
        vector: [Float],
        limit: Int,
        offset: Int,
        filter: RetrievalQueryFilter?,
        vectorName: String?
    ) async throws -> [SearchResult] {
        searchCalls += 1
        lastOffset = offset
        lastSeenName = vectorName
        _ = filter
        return hits
    }

    func hybridRRF(collection: String, url: String, apiKey: String, body: [String: Any]) async throws -> [SearchResult] {
        hits
    }
}

private final class FakeWorker: RetrievalWorker {
    var status: Int
    var body: Data
    var tokens: [String] = []
    var bodies: [[String: Any]] = []

    init(status: Int = 200, body: Data = Data("{}".utf8)) {
        self.status = status
        self.body = body
    }

    var calls: Int { bodies.count }

    func search(baseURL: String, token: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
        tokens.append(token)
        bodies.append(json)
        return (status, body)
    }
}

private struct RetrievalScreenshotHost: View {
    var hits: [RetrievalHit]
    @State private var query = "revenue by year"
    @State private var collection = "documents"
    @State private var backend = EmbeddingBackendKind.ollama.rawValue
    @State private var model = "qwen3-embedding"
    @State private var limit = 8
    @State private var offset = 0
    @State private var source = "paper.pdf"
    @State private var page = "2"
    @State private var contentType = "text"
    @State private var mode = RetrievalMode.hybrid.rawValue
    @State private var denseWeight = "0.7"
    @State private var lexicalWeight = "0.3"

    var body: some View {
        RetrievalPlayground(
            query: $query,
            collection: $collection,
            backend: $backend,
            model: $model,
            limit: $limit,
            offset: $offset,
            source: $source,
            page: $page,
            contentType: $contentType,
            mode: $mode,
            denseWeight: $denseWeight,
            lexicalWeight: $lexicalWeight,
            collections: ["documents", "notes"],
            routeLabel: RetrievalRoute.localQdrant.displayName,
            statusLine: "2 results · limit 8 · offset 0 · end · Local Qdrant · ollama qwen3-embedding (1024). Browse loads at most 1000 points.",
            error: nil,
            hits: hits,
            isSearching: false,
            scrolls: false,
            onSearch: {}
        )
    }
}
