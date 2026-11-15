import Foundation

protocol ChunkySearchProviding: Sendable {
    func listCollections() async throws -> [String]
    func search(_ request: ChunkySearchRequest) async throws -> ChunkySearchPage
}

struct ChunkySearchFilter: Equatable, Sendable {
    var key: String
    var match: String?
    var gt: Double?
    var gte: Double?
    var lt: Double?
    var lte: Double?
}

struct ChunkySearchRequest: Equatable, Sendable {
    var query: String
    var collection: String
    var topK: Int
    var filters: [ChunkySearchFilter]
}

struct ChunkySearchHit: Equatable, Sendable {
    var id: String
    var score: Double
    var payload: [String: String]
}

struct ChunkySearchPage: Equatable, Sendable {
    var results: [ChunkySearchHit]
    var collection: String
}

enum ChunkySearchError: LocalizedError, Equatable {
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

struct ChunkyMCPContext: Equatable, Sendable {
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

enum ChunkySearchBackend {
    static func make(context: ChunkyMCPContext) -> any ChunkySearchProviding {
        _ = context
        return UnavailableChunkySearch()
    }
}

struct UnavailableChunkySearch: ChunkySearchProviding {
    func listCollections() async throws -> [String] {
        throw ChunkySearchError.unavailable
    }

    func search(_ request: ChunkySearchRequest) async throws -> ChunkySearchPage {
        _ = request
        throw ChunkySearchError.unavailable
    }
}
