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
    case contains(String)
    case anyText([String])
}

struct RetrievalFilter: Equatable, Sendable {
    var key: String
    var match: RetrievalMatch?
    var gt: Double?
    var gte: Double?
    var lt: Double?
    var lte: Double?
    var negated: Bool = false
    var should: Bool = false
    var matchEmpty: Bool = false

    var hasRange: Bool {
        gt != nil || gte != nil || lt != nil || lte != nil
    }

    var exactMatch: String? {
        if case .text(let value) = match { return value }
        return nil
    }

    var containsMatch: String? {
        if case .contains(let value) = match { return value }
        return nil
    }

    func conditions() -> [Condition] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var items: [Condition] = []
        if matchEmpty {
            items.append(.isEmpty(key: trimmed))
        }
        if let match {
            if trimmed == "content_type", let clause = Self.elementClause(match) {
                items.append(clause)
            } else {
                let encoded: Match
                switch match {
                case .text(let value):
                    encoded = .keyword(value)
                case .integer(let value):
                    encoded = .integer(Int64(value))
                case .boolean(let value):
                    encoded = .boolean(value)
                case .contains(let value):
                    encoded = .text(value)
                case .anyText(let values):
                    encoded = .anyKeyword(values)
                }
                items.append(.field(key: trimmed, match: encoded))
            }
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
        case .contains(let value):
            object["text"] = value
        case .anyText(let values):
            object["any"] = values
        case nil:
            break
        }
        if negated {
            object["negate"] = true
        }
        if should {
            object["should"] = true
        }
        if matchEmpty {
            object["empty"] = true
        }
        if let gt { object["gt"] = gt }
        if let gte { object["gte"] = gte }
        if let lt { object["lt"] = lt }
        if let lte { object["lte"] = lte }
        return object
    }

    private static let elementAliases: [String: String] = [
        "paragraph": "text", "section": "text", "list": "text", "title": "text",
        "caption": "text", "narrative": "text", "narrativetext": "text",
        "picture": "figure", "image": "figure", "chart": "figure",
        "equation": "formula",
    ]

    private static let canonicalTypes: Set<String> = ["text", "table", "formula", "figure", "code"]

    private static func elementStored(for raw: String) -> (stored: [String], canonical: String)? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonical = elementAliases[name] ?? (canonicalTypes.contains(name) ? name : nil)
        guard let canonical else { return nil }
        var stored = [canonical]
        for (alias, target) in elementAliases where target == canonical && !stored.contains(alias) {
            stored.append(alias)
        }
        return (stored, canonical)
    }

    private static func elementClause(_ match: RetrievalMatch) -> Condition? {
        let raw: [String]
        switch match {
        case .text(let value):
            raw = [value]
        case .anyText(let values):
            raw = values
        default:
            return nil
        }
        var stored: [String] = []
        var kinds: [String] = []
        for value in raw {
            guard let item = elementStored(for: value) else { return nil }
            for alias in item.stored where !stored.contains(alias) {
                stored.append(alias)
            }
            if !kinds.contains(item.canonical) {
                kinds.append(item.canonical)
            }
        }
        guard !stored.isEmpty else { return nil }
        return .filter(Filter(should: [
            .field(key: "content_type", match: .anyKeyword(stored)),
            .field(key: "content_types", match: .anyKeyword(kinds)),
        ]))
    }

    private static func elementMatches(_ payload: [String: Any], _ match: RetrievalMatch) -> Bool {
        guard let clause = elementClause(match), case .filter(let nested) = clause else { return false }
        let primary = payload["content_type"]
        let extras = payload["content_types"]
        return nested.should.contains { condition in
            guard case .field(let field) = condition, let match = field.match else { return false }
            let value = field.key == "content_types" ? extras : primary
            if case .anyKeyword(let expected) = match {
                return equalsAny(value, expected)
            }
            return false
        }
    }

    static func qdrantFilter(_ filters: [RetrievalFilter]) -> Filter? {
        var must = filters.filter { !$0.negated && !$0.should }.flatMap { $0.conditions() }
        let should = filters.filter { $0.should && !$0.negated }.flatMap { $0.conditions() }
        let mustNot = filters.filter(\.negated).flatMap { $0.conditions() }
        if !should.isEmpty {
            must.append(.filter(Filter(should: should)))
        }
        guard !must.isEmpty || !mustNot.isEmpty else { return nil }
        return Filter(must: must, mustNot: mustNot)
    }

    static func encodedSummaries(_ filters: [RetrievalFilter]) -> [EncodedFilterSummary] {
        filters.flatMap { $0.conditions() }.map { condition in
            if case .filter(let nested) = condition {
                guard let first = nested.should.first, case .field(let field) = first else {
                    return EncodedFilterSummary(key: "content_type")
                }
                var summary = EncodedFilterSummary(key: field.key)
                if case .anyKeyword(let values) = field.match {
                    summary.keyword = values.first
                }
                return summary
            }
            guard case .field(let field) = condition else {
                return EncodedFilterSummary(key: "")
            }
            var summary = EncodedFilterSummary(key: field.key)
            if case .keyword(let value) = field.match {
                summary.keyword = value
            }
            if case .anyKeyword(let values) = field.match {
                summary.keyword = values.first
            }
            if case .text(let value) = field.match {
                summary.text = value
            }
            if case .integer(let value) = field.match {
                summary.integer = Int(value)
            }
            summary.gte = field.range?.gte
            summary.lte = field.range?.lte
            return summary
        }
    }

    static func playground(
        source: String,
        page: String,
        contentType: String,
        yearFrom: String = "",
        yearTo: String = "",
        author: String = "",
        doi: String = "",
        title: String = "",
        heading: String = ""
    ) -> [RetrievalFilter] {
        var filters: [RetrievalFilter] = []
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceText.isEmpty {
            filters.append(RetrievalFilter(key: "source", match: .text(sourceText)))
        }
        if let pageNumber = Int(page.trimmingCharacters(in: .whitespacesAndNewlines)) {
            filters.append(RetrievalFilter(key: "page", match: .integer(pageNumber)))
        }
        filters += scope(
            yearFrom: yearFrom,
            yearTo: yearTo,
            author: author,
            doi: doi,
            title: title,
            heading: heading,
            contentType: contentType
        )
        return filters
    }

    static func scope(
        yearFrom: String = "",
        yearTo: String = "",
        author: String = "",
        doi: String = "",
        title: String = "",
        heading: String = "",
        contentType: String = ""
    ) -> [RetrievalFilter] {
        var filters: [RetrievalFilter] = []
        let from = Int(yearFrom.trimmingCharacters(in: .whitespacesAndNewlines))
        let to = Int(yearTo.trimmingCharacters(in: .whitespacesAndNewlines))
        if from != nil || to != nil {
            filters.append(RetrievalFilter(key: "year", gte: from.map(Double.init), lte: to.map(Double.init)))
        }
        let authorText = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authorText.isEmpty {
            filters.append(RetrievalFilter(key: "authors", match: .contains(authorText)))
        }
        let doiText = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        if !doiText.isEmpty {
            filters.append(RetrievalFilter(key: "doi", match: .text(doiText)))
        }
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleText.isEmpty {
            filters.append(RetrievalFilter(key: "doc_title", match: .contains(titleText)))
        }
        let headingText = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headingText.isEmpty {
            filters.append(RetrievalFilter(key: "headings", match: .contains(headingText)))
        }
        let kind = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kind.isEmpty {
            filters.append(RetrievalFilter(key: "content_type", match: .text(kind)))
        }
        return filters
    }

    static func scopeLabel(_ filters: [RetrievalFilter]) -> String {
        filters.map(\.labelToken).joined(separator: ",")
    }

    var labelToken: String {
        var parts = [key]
        switch match {
        case .text(let value):
            parts.append(value)
        case .integer(let value):
            parts.append(String(value))
        case .boolean(let value):
            parts.append(value ? "true" : "false")
        case .contains(let value):
            parts.append("~\(value)")
        case .anyText(let values):
            parts.append(values.joined(separator: "|"))
        case nil:
            break
        }
        if let gt { parts.append("gt\(gt)") }
        if let gte { parts.append("gte\(gte)") }
        if let lt { parts.append("lt\(lt)") }
        if let lte { parts.append("lte\(lte)") }
        return parts.joined(separator: ":")
    }

    static func keeps(_ payload: [String: Any], filters: [RetrievalFilter]) -> Bool {
        let required = filters.filter { !$0.should }
        let optional = filters.filter(\.should)
        let requiredMatch = required.allSatisfy { filter in
            let matched = filter.matches(payload)
            return filter.negated ? !matched : matched
        }
        guard requiredMatch else { return false }
        guard !optional.isEmpty else { return true }
        return optional.contains { $0.matches(payload) }
    }

    func matches(_ payload: [String: Any]) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let value = payload[trimmed]
        if matchEmpty {
            let text = value as? String
            let missing = value == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            if !missing { return false }
        }
        if let match {
            if trimmed == "content_type", Self.elementClause(match) != nil {
                return Self.elementMatches(payload, match)
            }
            switch match {
            case .text(let expected):
                if !Self.equals(value, expected) { return false }
            case .integer(let expected):
                if Self.intValue(value) != expected { return false }
            case .boolean(let expected):
                if (value as? Bool) != expected { return false }
            case .contains(let expected):
                if !Self.contains(value, expected) { return false }
            case .anyText(let expected):
                if !Self.equalsAny(value, expected) { return false }
            }
        }
        if hasRange {
            guard let number = Self.doubleValue(value) else { return false }
            if let gt, number <= gt { return false }
            if let gte, number < gte { return false }
            if let lt, number >= lt { return false }
            if let lte, number > lte { return false }
        }
        return true
    }

    private static func equalsAny(_ value: Any?, _ expected: [String]) -> Bool {
        if let text = value as? String { return expected.contains(text) }
        if let values = value as? [String] { return values.contains { expected.contains($0) } }
        return false
    }

    private static func equals(_ value: Any?, _ expected: String) -> Bool {
        if let text = value as? String { return text == expected }
        if let values = value as? [String] { return values.contains(expected) }
        if let values = value as? [Any] {
            return values.contains { ($0 as? String) == expected }
        }
        return false
    }

    private static func contains(_ value: Any?, _ expected: String) -> Bool {
        let needle = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if let text = value as? String {
            return text.lowercased().contains(needle)
        }
        if let values = value as? [String] {
            return values.contains { $0.lowercased().contains(needle) }
        }
        if let values = value as? [Any] {
            return values.contains { (($0 as? String) ?? "").lowercased().contains(needle) }
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

struct EncodedFilterSummary: Equatable, Sendable {
    var key: String
    var keyword: String? = nil
    var text: String? = nil
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
    var papersFirst: Bool = false
    var expandPapers: Bool = false
    var expandSection: Bool = false
    var sectionRatio: Double = SectionExpansion.defaultThreshold
    var libraryID: String = PaperLibrary.defaultID
    var libraryIDs: [String] = []
    var librarySearch: LibrarySearch = .active
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
        papersFirst: Bool = false,
        expandPapers: Bool = false,
        expandSection: Bool = false,
        sectionRatio: Double = SectionExpansion.defaultThreshold,
        libraryIDs: [String] = [],
        librarySearch: LibrarySearch = .active,
        rrfWeights: [Double]? = nil,
        rerank: RerankConfig? = nil,
        libraryID: String? = nil,
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
            papersFirst: papersFirst,
            expandPapers: expandPapers,
            expandSection: expandSection,
            sectionRatio: sectionRatio,
            libraryID: LibraryFilter.assignedID(libraryID ?? settings.activeLibraryID),
            libraryIDs: libraryIDs,
            librarySearch: librarySearch,
            rrfWeights: rrfWeights,
            rerank: rerank
        )
    }

    func scopedFilters() -> [RetrievalFilter] {
        var items = filters.filter { $0.key != "record_type" }
        if papersFirst {
            items = items.filter { !DocumentSummary.passageOnlyKeys.contains($0.key) }
            items.append(RetrievalFilter(key: "record_type", match: .text(DocumentSummary.documentRecord)))
        } else {
            items.append(RetrievalFilter(key: "record_type", match: .text(DocumentSummary.documentRecord), negated: true))
        }
        return items + LibraryFilter.filters(
            activeID: libraryID,
            selectedIDs: libraryIDs,
            scope: librarySearch
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
            "filters": (filters + LibraryFilter.filters(activeID: libraryID, selectedIDs: libraryIDs, scope: librarySearch)).map { $0.jsonObject() },
            "papers_first": papersFirst,
            "expand_documents": expandPapers,
            "expand_section": expandSection,
            "section_ratio": sectionRatio,
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
    var docTitle: String
    var page: Int?
    var pageEnd: Int?
    var headings: [String]
    var pageLabels: [String]
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
        self.docTitle = result.metadata["doc_title"] ?? ""
        self.page = result.page
        self.pageEnd = Int(result.metadata["page_end"] ?? "")
        self.headings = result.headings
        self.pageLabels = Self.pageLabels(from: result.metadata["page_labels"])
        self.payload = payload
    }

    init(
        id: String,
        score: Double,
        text: String,
        source: String,
        page: Int?,
        headings: [String],
        payload: [String: String],
        docTitle: String = "",
        pageEnd: Int? = nil,
        pageLabels: [String] = []
    ) {
        self.id = id
        self.score = score
        self.text = text
        self.source = source
        self.docTitle = docTitle.isEmpty ? (payload["doc_title"] ?? "") : docTitle
        self.page = page
        self.pageEnd = pageEnd ?? Int(payload["page_end"] ?? "")
        self.headings = headings
        self.pageLabels = pageLabels.isEmpty ? Self.pageLabels(from: payload["page_labels"]) : pageLabels
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
    func sectionChunks(collection: String, sources: [String]) async throws -> [SectionSibling]
}

extension RetrievalIndex {
    func sectionChunks(collection: String, sources: [String]) async throws -> [SectionSibling] {
        []
    }
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
        var should: [[String: Any]] = []
        var mustNot: [[String: Any]] = []
        for item in filters {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if item.matchEmpty {
                let condition: [String: Any] = ["is_empty": ["key": key]]
                if item.should {
                    should.append(condition)
                } else if item.negated {
                    mustNot.append(condition)
                } else {
                    must.append(condition)
                }
            }
            if let match = item.match {
                let condition: [String: Any]
                switch match {
                case .text(let text):
                    condition = ["key": key, "match": ["value": text]]
                case .integer(let number):
                    condition = ["key": key, "match": ["value": number]]
                case .boolean(let flag):
                    condition = ["key": key, "match": ["value": flag]]
                case .contains(let text):
                    condition = ["key": key, "match": ["text": text]]
                case .anyText(let values):
                    condition = ["key": key, "match": ["any": values]]
                }
                if item.should {
                    should.append(condition)
                } else if item.negated {
                    mustNot.append(condition)
                } else {
                    must.append(condition)
                }
            }
            if item.hasRange {
                var range: [String: Any] = [:]
                if let value = item.gt { range["gt"] = value }
                if let value = item.gte { range["gte"] = value }
                if let value = item.lt { range["lt"] = value }
                if let value = item.lte { range["lte"] = value }
                let condition: [String: Any] = ["key": key, "range": range]
                if item.negated {
                    mustNot.append(condition)
                } else {
                    must.append(condition)
                }
            }
        }
        if !should.isEmpty {
            must.append(["should": should])
        }
        var body: [String: Any] = [:]
        if !must.isEmpty { body["must"] = must }
        if !mustNot.isEmpty { body["must_not"] = mustNot }
        return body.isEmpty ? nil : body
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
        await service.ensureRetrievalIndexes(collection: collection)
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

    func sectionChunks(collection: String, sources: [String]) async throws -> [SectionSibling] {
        var siblings: [SectionSibling] = []
        for source in sources where !source.isEmpty {
            let points = try await service.loadPointsBySource(collectionName: collection, source: source)
            for point in points where point.metadata["record_type"] != DocumentSummary.documentRecord {
                siblings.append(
                    SectionSibling(
                        id: point.id,
                        source: point.source,
                        headings: point.headings,
                        page: point.page,
                        pageEnd: Int(point.metadata["page_end"] ?? ""),
                        text: point.text,
                        chunkIndex: Int(point.metadata["chunk_index"] ?? ""),
                        libraryID: point.metadata[PaperLibrary.field]
                    )
                )
            }
        }
        return siblings
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
    var sectionSiblings: @Sendable (RetrievalRequest, [RetrievalHit], (any RetrievalIndex)?) async -> [SectionSibling] = { request, hits, index in
        let sources = Array(Set(hits.map(\.source))).filter { !$0.isEmpty }
        if let index, !sources.isEmpty {
            if let loaded = try? await index.sectionChunks(collection: request.collection, sources: sources), !loaded.isEmpty {
                return SectionExpansion.restricting(loaded, filters: request.scopedFilters())
            }
        }
        return SectionExpansion.restricting(hits.map {
            SectionSibling(
                id: $0.id,
                source: $0.source,
                headings: $0.headings,
                page: $0.page,
                pageEnd: $0.pageEnd,
                text: $0.text,
                chunkIndex: Int($0.payload["chunk_index"] ?? ""),
                libraryID: $0.payload[PaperLibrary.field]
            )
        }, filters: request.scopedFilters())
    }

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
            if request.papersFirst && request.expandPapers {
                page = try await searchPapersThenChunks(request, index: index)
            } else {
                page = try await searchLocal(request, index: index)
            }
        case .worker:
            guard !request.workerURL.isEmpty, !request.workerToken.isEmpty else {
                throw RetrievalError.missingWorker
            }
            page = try await searchWorker(request)
        }
        var expanded = page
        if request.expandSection && request.route != .worker {
            expanded.hits = SectionExpansion.merge(
                hits: expanded.hits,
                siblings: await sectionSiblings(request, expanded.hits, index),
                threshold: request.sectionRatio
            )
        }
        return try await applyRerank(expanded, request: request)
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

    private func searchPapersThenChunks(_ request: RetrievalRequest, index: any RetrievalIndex) async throws -> RetrievalPage {
        var papersRequest = request
        papersRequest.expandPapers = false
        let papers = try await searchLocal(papersRequest, index: index)
        let sources = Array(Set(papers.hits.map(\.source))).filter { !$0.isEmpty }
        guard !sources.isEmpty else { return papers }
        var chunksRequest = request
        chunksRequest.papersFirst = false
        chunksRequest.expandPapers = false
        chunksRequest.offset = 0
        chunksRequest.filters.append(RetrievalFilter(key: "source", match: .anyText(sources)))
        let chunks = try await searchLocal(chunksRequest, index: index)
        var page = papers
        page.hits = papers.hits + chunks.hits
        return page
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
                filters: request.scopedFilters()
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
                filter: RetrievalFilter.qdrantFilter(request.scopedFilters()),
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
        let pageEnd = Self.pageNumber(payloadObject["page_end"])
        let docTitle = payloadObject["doc_title"] as? String ?? ""
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
            payload: flat,
            docTitle: docTitle,
            pageEnd: pageEnd,
            pageLabels: Self.pageLabels(from: payloadObject["page_labels"])
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

    static func pageLabels(from value: Any?) -> [String] {
        if let list = value as? [String] {
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let list = value as? [Any] {
            return list.compactMap { stringValue($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let text = value as? String {
            return text
                .components(separatedBy: "\n")
                .flatMap { $0.components(separatedBy: " > ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
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
            if list.contains(where: { !($0 is String) && !($0 is NSNumber) }),
               JSONSerialization.isValidJSONObject(list),
               let data = try? JSONSerialization.data(withJSONObject: list),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
            let parts = list.compactMap { stringValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: " > ")
        default:
            return nil
        }
    }
}
