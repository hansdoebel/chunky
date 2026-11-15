import Foundation
import QdrantCore

enum CollectionBrowse {
    static let pointLimit = 1000
}

enum RetrievalLimits {
    static let maximum = 100
}

typealias RetrievalQueryFilter = Filter

enum RetrievalMode: String, CaseIterable, Identifiable, Sendable {
    case dense
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dense: return "Dense"
        case .hybrid: return "Hybrid"
        }
    }
}

enum RetrievalRoute: String, Sendable, Equatable {
    case localQdrant
    case worker

    var displayName: String {
        switch self {
        case .localQdrant: return "Local Qdrant"
        case .worker: return "Worker /v1/search"
        }
    }
}

enum RetrievalMatch: Equatable, Sendable {
    case text(String)
    case integer(Int)
    case boolean(Bool)
}

struct RetrievalFilter: Equatable, Sendable {
    var key: String
    var match: RetrievalMatch?
    var gt: Double?
    var gte: Double?
    var lt: Double?
    var lte: Double?

    var hasRange: Bool {
        gt != nil || gte != nil || lt != nil || lte != nil
    }

    func conditions() -> [Condition] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var items: [Condition] = []
        if let match {
            let encoded: Match
            switch match {
            case .text(let value):
                encoded = .keyword(value)
            case .integer(let value):
                encoded = .integer(Int64(value))
            case .boolean(let value):
                encoded = .boolean(value)
            }
            items.append(.field(key: trimmed, match: encoded))
        }
        if hasRange {
            items.append(.field(key: trimmed, range: Range(lt: lt, gt: gt, lte: lte, gte: gte)))
        }
        return items
    }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["key": key]
        switch match {
        case .text(let value):
            object["match"] = value
        case .integer(let value):
            object["match"] = value
        case .boolean(let value):
            object["match"] = value
        case nil:
            break
        }
        if let gt { object["gt"] = gt }
        if let gte { object["gte"] = gte }
        if let lt { object["lt"] = lt }
        if let lte { object["lte"] = lte }
        return object
    }

    static func qdrantFilter(_ filters: [RetrievalFilter]) -> Filter? {
        let must = filters.flatMap { $0.conditions() }
        guard !must.isEmpty else { return nil }
        return Filter(must: must)
    }

    static func encodedSummaries(_ filters: [RetrievalFilter]) -> [EncodedFilterSummary] {
        filters.flatMap { $0.conditions() }.map { condition in
            guard case .field(let field) = condition else {
                return EncodedFilterSummary(key: "")
            }
            var summary = EncodedFilterSummary(key: field.key)
            if case .keyword(let value) = field.match {
                summary.keyword = value
            }
            if case .integer(let value) = field.match {
                summary.integer = Int(value)
            }
            summary.gte = field.range?.gte
            summary.lte = field.range?.lte
            return summary
        }
    }

    static func playground(source: String, page: String, contentType: String) -> [RetrievalFilter] {
        var filters: [RetrievalFilter] = []
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceText.isEmpty {
            filters.append(RetrievalFilter(key: "source", match: .text(sourceText)))
        }
        if let pageNumber = Int(page.trimmingCharacters(in: .whitespacesAndNewlines)) {
            filters.append(RetrievalFilter(key: "page", match: .integer(pageNumber)))
        }
        let kind = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kind.isEmpty {
            filters.append(RetrievalFilter(key: "content_type", match: .text(kind)))
        }
        return filters
    }
}

struct EncodedFilterSummary: Equatable, Sendable {
    var key: String
    var keyword: String? = nil
    var integer: Int? = nil
    var gte: Double? = nil
    var lte: Double? = nil
}

struct RetrievalRequest: Equatable, Sendable {
    var text: String
    var collection: String
    var mode: RetrievalMode
    var limit: Int
    var offset: Int
    var embeddingBackend: String
    var embeddingModel: String
    var embeddingURL: String
    var route: RetrievalRoute
    var qdrantURL: String
    var qdrantAPIKey: String
    var workerURL: String
    var workerToken: String
    var filters: [RetrievalFilter]
    var rrfWeights: [Double]?
    var rerank: RerankConfig?

    static func make(
        text: String,
        collection: String,
        mode: RetrievalMode = .dense,
        limit: Int,
        offset: Int = 0,
        backend: String? = nil,
        model: String? = nil,
        filters: [RetrievalFilter] = [],
        rrfWeights: [Double]? = nil,
        rerank: RerankConfig? = nil,
        settings: AppSettings
    ) -> RetrievalRequest {
        let resolvedBackend = (backend ?? settings.embeddingBackend).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = (model ?? settings.embeddingModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddingURL = resolvedBackend == EmbeddingBackendKind.openai.rawValue
            ? settings.embeddingAPIURL
            : settings.ollamaURL
        let usesWorker = settings.processingHost == .devbox && settings.devboxIngestTarget == .qdrantCloud
        let route: RetrievalRoute = usesWorker ? .worker : .localQdrant
        let qdrantURL = usesWorker ? settings.qdrantCloudURL : settings.qdrantURL
        let qdrantAPIKey = settings.qdrantAPIKey
        return RetrievalRequest(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            collection: collection.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            limit: limit,
            offset: offset,
            embeddingBackend: resolvedBackend.isEmpty ? EmbeddingBackendKind.ollama.rawValue : resolvedBackend,
            embeddingModel: resolvedModel,
            embeddingURL: embeddingURL,
            route: route,
            qdrantURL: qdrantURL,
            qdrantAPIKey: qdrantAPIKey,
            workerURL: settings.devboxWorkerURL,
            workerToken: settings.workerToken,
            filters: filters,
            rrfWeights: rrfWeights,
            rerank: rerank
        )
    }

    func workerJSON() -> [String: Any] {
        var body: [String: Any] = [
            "query": text,
            "collection": collection,
            "mode": mode.rawValue,
            "limit": limit,
            "offset": offset,
            "embedding_model": embeddingModel,
            "embedding_backend": embeddingBackend,
            "embedding_url": embeddingURL,
            "filters": filters.map { $0.jsonObject() },
        ]
        if let rrfWeights {
            body["rrf_weights"] = rrfWeights
        }
        if route == .worker && !qdrantURL.isEmpty {
            body["qdrant_url"] = qdrantURL
        }
        if route == .worker && !qdrantAPIKey.isEmpty {
            body["qdrant_api_key"] = qdrantAPIKey
        }
        return body
    }
}

struct RetrievalHit: Identifiable, Equatable, Sendable {
    var id: String
    var score: Double
    var text: String
    var source: String
    var page: Int?
    var headings: [String]
    var payload: [String: String]

    init(result: SearchResult) {
        var payload = result.metadata
        payload["text"] = result.text
        payload["source"] = result.source
        if let page = result.page {
            payload["page"] = String(page)
        }
        if !result.headings.isEmpty {
            payload["headings"] = result.headings.joined(separator: " > ")
        }
        self.id = result.id
        self.score = Double(result.score)
        self.text = result.text
        self.source = result.source
        self.page = result.page
        self.headings = result.headings
        self.payload = payload
    }

    init(id: String, score: Double, text: String, source: String, page: Int?, headings: [String], payload: [String: String]) {
        self.id = id
        self.score = score
        self.text = text
        self.source = source
        self.page = page
        self.headings = headings
        self.payload = payload
    }
}

struct RetrievalPage: Equatable, Sendable {
    var hits: [RetrievalHit]
    var limit: Int
    var offset: Int
    var nextOffset: Int?
    var embeddingModel: String
    var embeddingBackend: String
    var embeddingDim: Int
    var collection: String
    var route: RetrievalRoute
    var reranked: Bool = false

    var statusLine: String {
        let next = nextOffset.map { "next offset \($0)" } ?? "end"
        let rerankNote = reranked ? " · reranked" : ""
        return "\(hits.count) results · limit \(limit) · offset \(offset) · \(next) · \(route.displayName) · \(embeddingBackend) \(embeddingModel) (\(embeddingDim))\(rerankNote). Browse loads at most \(CollectionBrowse.pointLimit) points."
    }
}

struct RerankConfig: Equatable, Sendable {
    var url: String
    var model: String
    var apiKey: String
}

struct RerankScore: Equatable, Sendable {
    var index: Int
    var score: Double
}

enum RerankRequest {
    static func json(model: String, query: String, documents: [String], topN: Int) -> [String: Any] {
        [
            "model": model,
            "query": query,
            "documents": documents,
            "top_n": topN,
        ]
    }

    static func scores(from data: Data) throws -> [RerankScore] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RetrievalError.unreadableResponse
        }
        guard let rows = object["results"] as? [[String: Any]] else {
            throw RetrievalError.rerankFailed("Rerank response did not include a results array.")
        }
        guard !rows.isEmpty else {
            throw RetrievalError.rerankFailed("Rerank response included no results.")
        }
        var scores: [RerankScore] = []
        for row in rows {
            guard let index = (row["index"] as? NSNumber)?.intValue else {
                throw RetrievalError.rerankFailed("Rerank response included a result without an index.")
            }
            guard let score = (row["relevance_score"] as? NSNumber)?.doubleValue
                ?? (row["score"] as? NSNumber)?.doubleValue
            else {
                throw RetrievalError.rerankFailed("Rerank response included a result without a score.")
            }
            scores.append(RerankScore(index: index, score: score))
        }
        return scores
    }
}

protocol RerankTransport {
    func post(url: URL, apiKey: String, body: Data) async throws -> (status: Int, body: Data)
}

protocol Reranker {
    func rerank(config: RerankConfig, query: String, documents: [String], topN: Int) async throws -> [RerankScore]
}

struct URLSessionRerankTransport: RerankTransport {
    var session: URLSession = .shared

    func post(url: URL, apiKey: String, body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

struct LiveReranker: Reranker {
    var transport: any RerankTransport = URLSessionRerankTransport()

    func rerank(config: RerankConfig, query: String, documents: [String], topN: Int) async throws -> [RerankScore] {
        guard let endpoint = URL(string: config.url), endpoint.host != nil else {
            throw RetrievalError.rerankFailed("Rerank URL is not a valid http(s) address.")
        }
        let payload = try JSONSerialization.data(withJSONObject: RerankRequest.json(
            model: config.model,
            query: query,
            documents: documents,
            topN: topN
        ))
        let response = try await transport.post(url: endpoint, apiKey: config.apiKey, body: payload)
        guard (200..<300).contains(response.status) else {
            let detail = String(data: response.body, encoding: .utf8) ?? ""
            throw RetrievalError.rerankFailed("Rerank endpoint returned HTTP \(response.status). \(detail)")
        }
        return try RerankRequest.scores(from: response.body)
    }
}

enum RetrievalError: LocalizedError, Equatable {
    case emptyQuery
    case invalidLimit(Int)
    case invalidOffset
    case invalidWeights
    case notConnected
    case missingWorker
    case missingCollection(String)
    case dimensionMismatch(collection: String, existing: Int?, probed: Int?, detail: String)
    case worker(status: Int, detail: String)
    case unreadableResponse
    case rerankFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter a query."
        case .invalidLimit(let limit):
            return "Limit \(limit) is outside 1...\(RetrievalLimits.maximum)."
        case .invalidOffset:
            return "Offset must be zero or greater."
        case .invalidWeights:
            return "RRF weights must be two non-negative numbers, or left empty."
        case .notConnected:
            return "Local Qdrant is not connected."
        case .missingWorker:
            return "Devbox search needs a worker URL and bearer token."
        case .missingCollection(let name):
            return "Collection \(name) was not found."
        case .dimensionMismatch(_, _, _, let detail):
            return detail
        case .worker(let status, let detail):
            return "Worker returned HTTP \(status). \(detail)"
        case .unreadableResponse:
            return "Search response was not a JSON object."
        case .rerankFailed(let detail):
            return detail
        }
    }
}

protocol RetrievalEmbedding {
    func probe(backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> Int
    func embed(text: String, backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> [Float]
}

protocol RetrievalIndex {
    func vectorSize(collection: String) async throws -> Int?
    func vectorName(collection: String) async throws -> String?
    func denseSearch(
        collection: String,
        vector: [Float],
        limit: Int,
        offset: Int,
        filter: Filter?,
        vectorName: String?
    ) async throws -> [SearchResult]
    func hybridRRF(collection: String, url: String, apiKey: String, body: [String: Any]) async throws -> [SearchResult]
}

enum HybridQuery {
    static let textField = "text"

    static func body(
        vector: [Float],
        text: String,
        denseUsing: String?,
        limit: Int,
        offset: Int,
        weights: [Double]?,
        filters: [RetrievalFilter] = []
    ) -> [String: Any] {
        let prefetchLimit = max(limit + max(offset, 0), 1)
        var dense: [String: Any] = ["query": vector, "limit": prefetchLimit]
        let filter = restFilter(filters)
        if let filter {
            dense["filter"] = filter
        }
        if let denseUsing {
            dense["using"] = denseUsing
        }
        var lexical: [String: Any] = [
            "query": ["text": text],
            "using": textField,
            "limit": prefetchLimit,
        ]
        if let filter {
            lexical["filter"] = filter
        }
        var rrf: [String: Any] = [:]
        if let weights {
            rrf["weights"] = weights
        }
        var body: [String: Any] = [
            "prefetch": [dense, lexical],
            "query": ["rrf": rrf],
            "limit": limit,
            "offset": offset,
            "with_payload": true,
            "with_vector": false,
        ]
        if let filter {
            body["filter"] = filter
        }
        return body
    }

    static func restFilter(_ filters: [RetrievalFilter]) -> [String: Any]? {
        var must: [[String: Any]] = []
        for item in filters {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let match = item.match {
                let value: Any
                switch match {
                case .text(let text):
                    value = text
                case .integer(let number):
                    value = number
                case .boolean(let flag):
                    value = flag
                }
                must.append(["key": key, "match": ["value": value]])
            }
            if item.hasRange {
                var range: [String: Any] = [:]
                if let value = item.gt { range["gt"] = value }
                if let value = item.gte { range["gte"] = value }
                if let value = item.lt { range["lt"] = value }
                if let value = item.lte { range["lte"] = value }
                must.append(["key": key, "range": range])
            }
        }
        return must.isEmpty ? nil : ["must": must]
    }

    static func indexBody() -> [String: Any] {
        [
            "field_name": textField,
            "field_schema": ["type": "text", "scoring": ["type": "bm25"]],
        ]
    }

    static func restURL(qdrantURL: String, collection: String) -> URL? {
        guard var components = URLComponents(string: qdrantURL), components.host != nil else { return nil }
        if components.port == 6334 {
            components.port = 6333
        }
        guard var url = components.url else { return nil }
        url.appendPathComponent("collections")
        url.appendPathComponent(collection)
        url.appendPathComponent("points")
        url.appendPathComponent("query")
        return url
    }

    static func indexURL(qdrantURL: String, collection: String) -> URL? {
        guard var components = URLComponents(string: qdrantURL), components.host != nil else { return nil }
        if components.port == 6334 {
            components.port = 6333
        }
        guard var url = components.url else { return nil }
        url.appendPathComponent("collections")
        url.appendPathComponent(collection)
        url.appendPathComponent("index")
        return url
    }

    static func hits(from data: Data) throws -> [SearchResult] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RetrievalError.unreadableResponse
        }
        let result = object["result"] as? [String: Any] ?? object
        let rows = result["points"] as? [[String: Any]] ?? object["result"] as? [[String: Any]] ?? []
        return rows.map { row in
            let hit = RetrievalHit(workerRow: row)
            return SearchResult(
                id: hit.id,
                score: Float(hit.score),
                text: hit.text,
                source: hit.source,
                page: hit.page,
                headings: hit.headings,
                metadata: hit.payload
            )
        }
    }
}

protocol RetrievalWorker {
    func search(baseURL: String, token: String, json: [String: Any]) async throws -> (status: Int, body: Data)
}

struct LiveRetrievalEmbedding: RetrievalEmbedding {
    func probe(backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> Int {
        try await EmbeddingDimensionProbe.probe(backend: backend, model: model, ollamaURL: ollamaURL, apiURL: apiURL)
    }

    func embed(text: String, backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> [Float] {
        if backend == EmbeddingBackendKind.openai.rawValue {
            return try await Self.openAIEmbed(url: apiURL, model: model, text: text)
        }
        let service = try OllamaService(baseURL: ollamaURL)
        return try await service.embed(text: text, model: model)
    }

    private static func openAIEmbed(url: String, model: String, text: String) async throws -> [Float] {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(string: trimmed + "/v1/embeddings") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": [text]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = object?["data"] as? [[String: Any]]
        let embedding = rows?.first?["embedding"] as? [Any] ?? []
        let vector = embedding.compactMap { ($0 as? NSNumber)?.floatValue }
        guard vector.count == embedding.count, !vector.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return vector
    }
}

struct QdrantRetrievalIndex: RetrievalIndex {
    var service: QdrantService

    func vectorSize(collection: String) async throws -> Int? {
        guard try await service.collectionExists(collection) else { return nil }
        return try await service.getCollectionInfo(collection).vectorSize
    }

    func vectorName(collection: String) async throws -> String? {
        guard try await service.collectionExists(collection) else { return nil }
        return try await service.getCollectionInfo(collection).vectorName
    }

    func denseSearch(
        collection: String,
        vector: [Float],
        limit: Int,
        offset: Int,
        filter: Filter?,
        vectorName: String?
    ) async throws -> [SearchResult] {
        try await service.search(
            collectionName: collection,
            vector: vector,
            limit: limit,
            filter: filter,
            offset: offset,
            vectorName: vectorName
        )
    }

    func hybridRRF(collection: String, url: String, apiKey: String, body: [String: Any]) async throws -> [SearchResult] {
        guard let endpoint = HybridQuery.restURL(qdrantURL: url, collection: collection) else {
            throw QdrantServiceError.invalidURL(url)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RetrievalError.worker(status: status, detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try HybridQuery.hits(from: data)
    }
}

struct LiveRetrievalWorker: RetrievalWorker {
    var session: URLSession = .shared

    func search(baseURL: String, token: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
        guard let root = URL(string: baseURL), root.host != nil else {
            throw DevboxClientError.invalidURL(baseURL)
        }
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("search")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DevboxClientError.unreachable(url: endpoint.absoluteString, reason: "No HTTP response")
        }
        return (http.statusCode, data)
    }
}

struct RetrievalService {
    var embedding: any RetrievalEmbedding
    var worker: any RetrievalWorker
    var reranker: any Reranker

    init(
        embedding: any RetrievalEmbedding = LiveRetrievalEmbedding(),
        worker: any RetrievalWorker = LiveRetrievalWorker(),
        reranker: any Reranker = LiveReranker()
    ) {
        self.embedding = embedding
        self.worker = worker
        self.reranker = reranker
    }

    func search(_ request: RetrievalRequest, index: (any RetrievalIndex)?) async throws -> RetrievalPage {
        guard !request.text.isEmpty else { throw RetrievalError.emptyQuery }
        guard (1...RetrievalLimits.maximum).contains(request.limit) else {
            throw RetrievalError.invalidLimit(request.limit)
        }
        guard request.offset >= 0 else { throw RetrievalError.invalidOffset }
        if let weights = request.rrfWeights, request.mode == .hybrid, weights.count != 2 || weights.contains(where: { $0 < 0 }) {
            throw RetrievalError.invalidWeights
        }
        guard !request.collection.isEmpty else { throw RetrievalError.missingCollection(request.collection) }

        let page: RetrievalPage
        switch request.route {
        case .localQdrant:
            guard let index else { throw RetrievalError.notConnected }
            page = try await searchLocal(request, index: index)
        case .worker:
            guard !request.workerURL.isEmpty, !request.workerToken.isEmpty else {
                throw RetrievalError.missingWorker
            }
            page = try await searchWorker(request)
        }
        return try await applyRerank(page, request: request)
    }

    private func applyRerank(_ page: RetrievalPage, request: RetrievalRequest) async throws -> RetrievalPage {
        guard let config = request.rerank else { return page }
        let trimmedURL = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !model.isEmpty else {
            throw RetrievalError.rerankFailed("Rerank needs a URL and a model.")
        }
        let scores = try await reranker.rerank(
            config: RerankConfig(url: trimmedURL, model: model, apiKey: config.apiKey),
            query: request.text,
            documents: page.hits.map(\.text),
            topN: request.limit
        )
        var ordered: [RetrievalHit] = []
        for score in scores.sorted(by: { $0.score > $1.score }) {
            guard page.hits.indices.contains(score.index) else { continue }
            var hit = page.hits[score.index]
            hit.score = score.score
            ordered.append(hit)
        }
        guard !ordered.isEmpty else {
            throw RetrievalError.rerankFailed("Rerank response did not match any retrieved hits.")
        }
        var updated = page
        updated.hits = ordered
        updated.reranked = true
        return updated
    }

    private func searchLocal(_ request: RetrievalRequest, index: any RetrievalIndex) async throws -> RetrievalPage {
        let ollamaURL = request.embeddingBackend == EmbeddingBackendKind.openai.rawValue ? "" : request.embeddingURL
        let apiURL = request.embeddingBackend == EmbeddingBackendKind.openai.rawValue ? request.embeddingURL : ""
        let probed = try await embedding.probe(
            backend: request.embeddingBackend,
            model: request.embeddingModel,
            ollamaURL: ollamaURL,
            apiURL: apiURL
        )
        guard let existing = try await index.vectorSize(collection: request.collection) else {
            throw RetrievalError.missingCollection(request.collection)
        }
        if existing != probed {
            throw RetrievalError.dimensionMismatch(
                collection: request.collection,
                existing: existing,
                probed: probed,
                detail: "Collection \(request.collection) has vector size \(existing), but \(request.embeddingModel) probes \(probed). Refusing to search."
            )
        }
        let vector = try await embedding.embed(
            text: request.text,
            backend: request.embeddingBackend,
            model: request.embeddingModel,
            ollamaURL: ollamaURL,
            apiURL: apiURL
        )
        if vector.count != probed {
            throw RetrievalError.dimensionMismatch(
                collection: request.collection,
                existing: existing,
                probed: vector.count,
                detail: "Collection \(request.collection) has vector size \(existing), but \(request.embeddingModel) produced \(vector.count). Refusing to search."
            )
        }
        let vectorName = try await index.vectorName(collection: request.collection)
        let hits: [RetrievalHit]
        if request.mode == .hybrid {
            let body = HybridQuery.body(
                vector: vector,
                text: request.text,
                denseUsing: vectorName,
                limit: request.limit,
                offset: request.offset,
                weights: request.rrfWeights,
                filters: request.filters
            )
            hits = try await index.hybridRRF(
                collection: request.collection,
                url: request.qdrantURL,
                apiKey: request.qdrantAPIKey,
                body: body
            ).map(RetrievalHit.init(result:))
        } else {
            hits = try await index.denseSearch(
                collection: request.collection,
                vector: vector,
                limit: request.limit,
                offset: request.offset,
                filter: RetrievalFilter.qdrantFilter(request.filters),
                vectorName: vectorName
            ).map(RetrievalHit.init(result:))
        }
        let nextOffset: Int? = hits.count == request.limit ? request.offset + request.limit : nil
        return RetrievalPage(
            hits: hits,
            limit: request.limit,
            offset: request.offset,
            nextOffset: nextOffset,
            embeddingModel: request.embeddingModel,
            embeddingBackend: request.embeddingBackend,
            embeddingDim: vector.count,
            collection: request.collection,
            route: .localQdrant
        )
    }

    private func searchWorker(_ request: RetrievalRequest) async throws -> RetrievalPage {
        let response = try await worker.search(
            baseURL: request.workerURL,
            token: request.workerToken,
            json: request.workerJSON()
        )
        let detail = String(data: response.body, encoding: .utf8) ?? ""
        if response.status == 401 {
            throw RetrievalError.worker(status: 401, detail: "Worker rejected the token.")
        }
        if response.status == 404 {
            throw RetrievalError.missingCollection(request.collection)
        }
        if response.status == 409 || detail.contains("dimension_mismatch") {
            throw RetrievalError.dimensionMismatch(
                collection: request.collection,
                existing: Self.firstInteger(after: "vector size ", in: detail),
                probed: Self.lastInteger(after: "size ", in: detail),
                detail: Self.detailText(detail) ?? detail
            )
        }
        guard (200..<300).contains(response.status) else {
            throw RetrievalError.worker(status: response.status, detail: Self.detailText(detail) ?? detail)
        }
        return try Self.page(from: response.body, route: .worker)
    }

    static func page(from data: Data, route: RetrievalRoute) throws -> RetrievalPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RetrievalError.unreadableResponse
        }
        let rows = object["results"] as? [[String: Any]] ?? []
        let hits = rows.map(RetrievalHit.init(workerRow:))
        let limit = (object["limit"] as? NSNumber)?.intValue ?? hits.count
        let offset = (object["offset"] as? NSNumber)?.intValue ?? 0
        let nextOffset = (object["next_offset"] as? NSNumber)?.intValue
        return RetrievalPage(
            hits: hits,
            limit: limit,
            offset: offset,
            nextOffset: nextOffset,
            embeddingModel: object["embedding_model"] as? String ?? "",
            embeddingBackend: object["embedding_backend"] as? String ?? "",
            embeddingDim: (object["embedding_dim"] as? NSNumber)?.intValue ?? 0,
            collection: object["collection"] as? String ?? "",
            route: route
        )
    }

    private static func detailText(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let detail = object["detail"] as? String { return detail }
        if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String {
            return message
        }
        return nil
    }

    private static func firstInteger(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func lastInteger(after marker: String, in text: String) -> Int? {
        var search = text[...]
        var found: Int?
        while let range = search.range(of: marker) {
            let tail = search[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let value = Int(digits) {
                found = value
            }
            search = tail
        }
        return found
    }
}

extension RetrievalHit {
    init(workerRow: [String: Any]) {
        let payloadObject = workerRow["payload"] as? [String: Any] ?? [:]
        let flat = Self.flatten(payloadObject)
        let headings = Self.headings(from: payloadObject["headings"])
        let page = Self.pageNumber(payloadObject["page"])
        let identifier: String
        if let text = workerRow["id"] as? String {
            identifier = text
        } else if let number = workerRow["id"] as? NSNumber {
            identifier = number.stringValue
        } else {
            identifier = UUID().uuidString
        }
        self.init(
            id: identifier,
            score: (workerRow["score"] as? NSNumber)?.doubleValue ?? 0,
            text: flat["text"] ?? "",
            source: flat["source"] ?? "",
            page: page,
            headings: headings,
            payload: flat
        )
    }

    private static func flatten(_ payload: [String: Any]) -> [String: String] {
        var flat: [String: String] = [:]
        for (key, value) in payload {
            if key == "headings" {
                flat[key] = headings(from: value).joined(separator: " > ")
            } else if let text = stringValue(value) {
                flat[key] = text
            }
        }
        return flat
    }

    private static func headings(from value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] {
            return list.compactMap { stringValue($0) }
        }
        if let text = value as? String, !text.isEmpty {
            return text.components(separatedBy: " > ")
        }
        return []
    }

    private static func pageNumber(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func stringValue(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let list as [Any]:
            let parts = list.compactMap { stringValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: " > ")
        default:
            return nil
        }
    }
}
