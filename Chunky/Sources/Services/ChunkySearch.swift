import Foundation

nonisolated protocol ChunkySearchProviding: Sendable {
    func listCollections() async throws -> [String]
    func search(_ request: ChunkySearchRequest) async throws -> ChunkySearchPage
}

nonisolated struct ChunkySearchFilter: Equatable, Sendable {
    var key: String
    var match: String?
    var gt: Double?
    var gte: Double?
    var lt: Double?
    var lte: Double?
}

nonisolated struct ChunkySearchRequest: Equatable, Sendable {
    var query: String
    var collection: String
    var topK: Int
    var filters: [ChunkySearchFilter]
}

nonisolated struct ChunkySearchHit: Equatable, Sendable {
    var id: String
    var score: Double
    var payload: [String: String]
}

nonisolated struct ChunkySearchPage: Equatable, Sendable {
    var results: [ChunkySearchHit]
    var collection: String
}

nonisolated enum ChunkySearchError: LocalizedError, Equatable {
    case unavailable
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Chunky search is not connected to retrieval yet"
        case .invalidArguments(let message):
            return message
        }
    }
}

nonisolated struct ChunkyMCPContext: Equatable, Sendable {
    var qdrantURL: String
    var qdrantAPIKey: String
    var qdrantCloudURL: String
    var embeddingBackend: String
    var embeddingModel: String
    var embeddingAPIURL: String
    var ollamaURL: String
    var workerURL: String
    var workerToken: String
    var defaultCollection: String
    var processingHost: String

    static func load(defaults: UserDefaults, secrets: SettingsSecretStore) -> ChunkyMCPContext {
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        return ChunkyMCPContext(
            qdrantURL: settings.qdrantURL,
            qdrantAPIKey: settings.qdrantAPIKey,
            qdrantCloudURL: settings.qdrantCloudURL,
            embeddingBackend: settings.embeddingBackend,
            embeddingModel: settings.embeddingModel,
            embeddingAPIURL: settings.embeddingAPIURL,
            ollamaURL: settings.ollamaURL,
            workerURL: settings.devboxWorkerURL,
            workerToken: settings.workerToken,
            defaultCollection: settings.defaultCollection,
            processingHost: settings.processingHost.rawValue
        )
    }

    func redactedSummary() -> String {
        "collection=\(defaultCollection) host=\(processingHost) backend=\(embeddingBackend) model=\(embeddingModel) qdrant=\(qdrantURL) worker=\(workerURL)"
    }

    var secrets: [String] {
        [qdrantAPIKey, workerToken].filter { !$0.isEmpty }
    }
}

nonisolated protocol ChunkyRetrievalCalling: Sendable {
    func search(_ request: RetrievalRequest) async throws -> RetrievalPage
    func listCollections(url: String, apiKey: String) async throws -> [String]
}

nonisolated struct RetrievalServiceSearch: ChunkySearchProviding {
    var settings: AppSettings
    var retrieval: any ChunkyRetrievalCalling

    func listCollections() async throws -> [String] {
        let route = RetrievalRequest.make(
            text: "collections",
            collection: settings.defaultCollection,
            limit: 1,
            settings: settings
        )
        return try await retrieval.listCollections(url: route.qdrantURL, apiKey: settings.qdrantAPIKey)
    }

    func search(_ request: ChunkySearchRequest) async throws -> ChunkySearchPage {
        let collection = request.collection.isEmpty ? settings.defaultCollection : request.collection
        let retrievalRequest = RetrievalRequest.make(
            text: request.query,
            collection: collection,
            limit: request.topK,
            filters: request.filters.map(Self.retrievalFilter),
            settings: settings
        )
        let page = try await retrieval.search(retrievalRequest)
        return ChunkySearchPage(
            results: page.hits.map {
                ChunkySearchHit(id: $0.id, score: $0.score, payload: $0.payload)
            },
            collection: page.collection
        )
    }

    private static func retrievalFilter(_ filter: ChunkySearchFilter) -> RetrievalFilter {
        RetrievalFilter(
            key: filter.key,
            match: filter.match.map { .text($0) },
            gt: filter.gt,
            gte: filter.gte,
            lt: filter.lt,
            lte: filter.lte
        )
    }
}

nonisolated struct LiveChunkyRetrieval: ChunkyRetrievalCalling {
    var apiKey: String

    func search(_ request: RetrievalRequest) async throws -> RetrievalPage {
        let index: (any RetrievalIndex)?
        if request.route == .localQdrant {
            let service = QdrantService()
            let key = request.qdrantAPIKey.isEmpty ? apiKey : request.qdrantAPIKey
            try await service.configure(url: request.qdrantURL, apiKey: key.isEmpty ? nil : key)
            try await service.connect(timeout: 30)
            index = QdrantRetrievalIndex(service: service)
        } else {
            index = nil
        }
        return try await RetrievalService().search(request, index: index)
    }

    func listCollections(url: String, apiKey: String) async throws -> [String] {
        let service = QdrantService()
        try await service.configure(url: url, apiKey: apiKey.isEmpty ? nil : apiKey)
        try await service.connect(timeout: 30)
        return try await service.listCollections()
    }
}

nonisolated enum ChunkySearchBackend {
    static func make(defaults: UserDefaults = .standard, secrets: SettingsSecretStore = KeychainSecretStore()) -> any ChunkySearchProviding {
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        return RetrievalServiceSearch(
            settings: settings,
            retrieval: LiveChunkyRetrieval(apiKey: settings.qdrantAPIKey)
        )
    }
}
