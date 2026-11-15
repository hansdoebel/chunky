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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dense: return "Dense"
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

    static func make(
        text: String,
        collection: String,
        mode: RetrievalMode = .dense,
        limit: Int,
        offset: Int = 0,
        backend: String? = nil,
        model: String? = nil,
        filters: [RetrievalFilter] = [],
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
            qdrantAPIKey: route == .worker ? qdrantAPIKey : "",
            workerURL: settings.devboxWorkerURL,
            workerToken: settings.workerToken,
            filters: filters
        )
    }

    func workerJSON() -> [String: Any] {
        var body: [String: Any] = [
            "query": text,
            "collection": collection,
            "limit": limit,
            "offset": offset,
            "embedding_model": embeddingModel,
            "embedding_backend": embeddingBackend,
            "embedding_url": embeddingURL,
            "filters": filters.map { $0.jsonObject() },
        ]
        if !qdrantURL.isEmpty {
            body["qdrant_url"] = qdrantURL
        }
        if !qdrantAPIKey.isEmpty {
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

    var statusLine: String {
        let next = nextOffset.map { "next offset \($0)" } ?? "end"
        return "\(hits.count) results · limit \(limit) · offset \(offset) · \(next) · \(route.displayName) · \(embeddingBackend) \(embeddingModel) (\(embeddingDim)). Browse loads at most \(CollectionBrowse.pointLimit) points."
    }
}

enum RetrievalError: LocalizedError, Equatable {
    case emptyQuery
    case invalidLimit(Int)
    case invalidOffset
    case notConnected
    case missingWorker
    case missingCollection(String)
    case dimensionMismatch(collection: String, existing: Int?, probed: Int?, detail: String)
    case worker(status: Int, detail: String)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter a query."
        case .invalidLimit(let limit):
            return "Limit \(limit) is outside 1...\(RetrievalLimits.maximum)."
        case .invalidOffset:
            return "Offset must be zero or greater."
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

    init(
        embedding: any RetrievalEmbedding = LiveRetrievalEmbedding(),
        worker: any RetrievalWorker = LiveRetrievalWorker()
    ) {
        self.embedding = embedding
        self.worker = worker
    }

    func search(_ request: RetrievalRequest, index: (any RetrievalIndex)?) async throws -> RetrievalPage {
        guard !request.text.isEmpty else { throw RetrievalError.emptyQuery }
        guard (1...RetrievalLimits.maximum).contains(request.limit) else {
            throw RetrievalError.invalidLimit(request.limit)
        }
        guard request.offset >= 0 else { throw RetrievalError.invalidOffset }
        guard !request.collection.isEmpty else { throw RetrievalError.missingCollection(request.collection) }

        switch request.route {
        case .localQdrant:
            guard let index else { throw RetrievalError.notConnected }
            return try await searchLocal(request, index: index)
        case .worker:
            guard !request.workerURL.isEmpty, !request.workerToken.isEmpty else {
                throw RetrievalError.missingWorker
            }
            return try await searchWorker(request)
        }
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
        let hits = try await index.denseSearch(
            collection: request.collection,
            vector: vector,
            limit: request.limit,
            offset: request.offset,
            filter: RetrievalFilter.qdrantFilter(request.filters),
            vectorName: vectorName
        ).map(RetrievalHit.init(result:))
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
