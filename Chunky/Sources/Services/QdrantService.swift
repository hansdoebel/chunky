import Combine
import Foundation
import QdrantCore
import QdrantGRPC

/// Business logic layer for Qdrant operations
@MainActor
class QdrantService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionError: String?
    @Published private(set) var serverVersion: String?

    private var client: QdrantGRPCClient?
    private var pendingUrl: String?
    private var pendingApiKey: String?

    // MARK: - Connection Management

    func configure(url: String, apiKey: String?) async throws {
        // Store for later connection
        self.pendingUrl = url
        self.pendingApiKey = apiKey
    }

    func connect(timeout: Int = 30) async throws {
        guard let url = pendingUrl else {
            throw QdrantServiceError.notConfigured
        }

        // Parse URL to extract host and port
        guard let urlComponents = URLComponents(string: url),
            let host = urlComponents.host, !host.isEmpty
        else {
            throw QdrantServiceError.invalidURL(url)
        }

        let useTLS = urlComponents.scheme == "https"
        let port = urlComponents.port ?? 6334

        do {
            // Close existing client if any
            client?.close()

            let config = try QdrantConfiguration(
                host: host,
                port: port,
                apiKey: pendingApiKey,
                useTLS: useTLS,
                timeout: .seconds(timeout)
            )
            let newClient = try await QdrantGRPCClient(configuration: config)

            // Test connection with health check
            let health = try await newClient.healthCheck()

            self.client = newClient
            self.serverVersion = health.version
            self.isConnected = true
            self.connectionError = nil
        } catch {
            isConnected = false
            connectionError = error.localizedDescription
            throw QdrantServiceError.connectionFailed(error.localizedDescription)
        }
    }

    func disconnect() async {
        client?.close()
        client = nil
        isConnected = false
        serverVersion = nil
    }

    func testConnection() async -> Bool {
        guard let client = client else { return false }
        do {
            _ = try await client.healthCheck()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Collections

    func listCollections() async throws -> [String] {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        let collections = try await client.collections.list()
        return collections.map { $0.name }
    }

    func collectionExists(_ name: String) async throws -> Bool {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        return try await client.collections.exists(name: name)
    }

    func getCollectionInfo(_ name: String) async throws -> CollectionInfo {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        let info = try await client.collections.get(name: name)

        let status: CollectionInfo.CollectionStatus
        switch info.status {
        case .green: status = .green
        case .yellow: status = .yellow
        case .red: status = .red
        case .grey, .unknown: status = .unknown
        }

        return CollectionInfo(
            name: name,
            vectorsCount: info.indexedVectorsCount ?? 0,
            pointsCount: info.pointsCount ?? 0,
            status: status
        )
    }

    func createCollectionIfNeeded(name: String, vectorSize: Int, hybrid: Bool = false, distance: Distance = .cosine, quantizationConfig: QuantizationConfig? = nil) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        let exists = try await client.collections.exists(name: name)
        if !exists {
            if hybrid {
                try await client.collections.create(
                    name: name,
                    vectors: .named(["dense": VectorConfig(size: vectorSize, distance: distance)]),
                    sparseVectors: ["sparse": SparseVectorParams(modifier: .idf)],
                    onDiskPayload: true,
                    quantizationConfig: quantizationConfig
                )
            } else {
                try await client.collections.create(
                    name: name,
                    vectorSize: UInt64(vectorSize),
                    distance: distance,
                    onDiskPayload: nil,
                    quantizationConfig: quantizationConfig
                )
            }
        }
        try await createPayloadIndexes(collection: name)
    }

    func createPayloadIndexes(collection: String) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        let keywordFields = ["source", "doc_title", "authors", "content_type", "language", "doi"]
        let integerFields = ["page", "year"]

        for field in keywordFields {
            try? await client.points.createFieldIndex(
                collection: collection, fieldName: field, fieldType: .keyword, wait: false
            )
        }
        for field in integerFields {
            try? await client.points.createFieldIndex(
                collection: collection, fieldName: field, fieldType: .integer, wait: false
            )
        }
    }

    func deleteCollection(_ name: String) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        try await client.collections.delete(name: name)
    }

    // MARK: - Points Operations

    /// Upsert points in batches with progress reporting
    func upsertPoints(
        collectionName: String,
        points: [ChunkPoint],
        batchSize: Int = 100,
        onProgress: ((UploadProgress) -> Void)? = nil
    ) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        guard !points.isEmpty else { return }

        let totalBatches = (points.count + batchSize - 1) / batchSize
        var completedPoints = 0

        for (batchIndex, batchStart) in stride(from: 0, to: points.count, by: batchSize)
            .enumerated()
        {
            let batchEnd = min(batchStart + batchSize, points.count)
            let batch = Array(points[batchStart..<batchEnd])

            // Convert ChunkPoints to QdrantCore.Points
            let qdrantPoints = batch.map { $0.toQdrantPoint() }

            try await client.points.upsert(
                collection: collectionName,
                points: qdrantPoints,
                wait: true
            )

            completedPoints += batch.count

            let progress = UploadProgress(
                completed: completedPoints,
                total: points.count,
                currentBatch: batchIndex + 1,
                totalBatches: totalBatches
            )
            onProgress?(progress)
        }
    }

    func search(
        collectionName: String,
        vector: [Float],
        limit: Int = 10,
        sourceFilter: String? = nil
    ) async throws -> [SearchResult] {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        var filter: Filter?
        if let sourceFilter = sourceFilter, !sourceFilter.isEmpty {
            filter = Filter(
                must: [
                    .field(
                        FieldCondition(
                            key: "source",
                            match: .keyword(sourceFilter)
                        ))
                ]
            )
        }

        let results = try await client.points.search(
            collection: collectionName,
            vector: vector,
            limit: UInt64(limit),
            filter: filter,
            scoreThreshold: nil,
            offset: nil,
            withPayload: true,
            withVectors: false,
            vectorName: nil
        )

        return results.map { $0.toSearchResult() }
    }

    func hybridSearch(
        collectionName: String,
        denseVector: [Float],
        sparseVector: SparseVector,
        limit: Int = 10,
        sourceFilter: String? = nil
    ) async throws -> [SearchResult] {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        var filter: Filter?
        if let sourceFilter = sourceFilter, !sourceFilter.isEmpty {
            filter = Filter(
                must: [
                    .field(
                        FieldCondition(
                            key: "source",
                            match: .keyword(sourceFilter)
                        ))
                ]
            )
        }

        let densePrefetch = PrefetchQuery(
            query: .nearest(denseVector),
            using: "dense",
            filter: filter,
            limit: UInt64(limit)
        )

        let sparsePrefetch = PrefetchQuery(
            query: .nearestSparse(sparseVector),
            using: "sparse",
            filter: filter,
            limit: UInt64(limit)
        )

        let results = try await client.points.query(
            collection: collectionName,
            query: .fusion(.rrf),
            prefetch: [densePrefetch, sparsePrefetch],
            limit: UInt64(limit),
            withPayload: true,
            withVectors: false
        )

        return results.map { $0.toSearchResult() }
    }

    /// Load all points from a collection (paginated)
    func loadPoints(
        collectionName: String,
        limit: Int = 1000
    ) async throws -> [QdrantPoint] {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        var allPoints: [QdrantPoint] = []
        var offset: PointID? = nil

        repeat {
            let result = try await client.points.scroll(
                collection: collectionName,
                filter: nil,
                limit: UInt32(min(limit, 100)),
                offset: offset,
                withPayload: true,
                withVectors: false
            )

            allPoints.append(contentsOf: result.points.map { $0.toQdrantPoint() })
            offset = result.nextPageOffset

            // Stop if we've reached the requested limit
            if allPoints.count >= limit {
                break
            }
        } while offset != nil

        return Array(allPoints.prefix(limit))
    }

    /// Get unique source values from collection
    func getSources(collectionName: String) async throws -> [String] {
        let points = try await loadPoints(collectionName: collectionName, limit: 10000)
        let sources = Set(points.map { $0.source })
        return Array(sources).sorted()
    }

    /// Delete points by IDs
    func deletePoints(collectionName: String, ids: [String]) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        let pointIds = ids.map { PointID.uuid($0) }
        try await client.points.delete(
            collection: collectionName,
            ids: pointIds,
            wait: true
        )
    }

    func deleteBySource(collectionName: String, source: String) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        let filter = Filter(
            must: [.field(key: "source", match: .keyword(source))]
        )
        try await client.points.delete(
            collection: collectionName,
            filter: filter,
            wait: true
        )
    }

    func loadPointsBySource(
        collectionName: String,
        source: String
    ) async throws -> [QdrantPoint] {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        let filter = Filter(
            must: [.field(key: "source", match: .keyword(source))]
        )

        var allPoints: [QdrantPoint] = []
        var offset: PointID? = nil

        repeat {
            let result = try await client.points.scroll(
                collection: collectionName,
                filter: filter,
                limit: 100,
                offset: offset,
                withPayload: true,
                withVectors: false
            )

            allPoints.append(contentsOf: result.points.map { $0.toQdrantPoint() })
            offset = result.nextPageOffset
        } while offset != nil

        return allPoints
    }

    func countPoints(collectionName: String) async throws -> Int {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        let count = try await client.points.count(
            collection: collectionName,
            filter: nil,
            exact: true
        )
        return Int(count)
    }
}

// MARK: - Errors

enum QdrantServiceError: LocalizedError, Sendable {
    case notConfigured
    case notConnected
    case invalidURL(String)
    case connectionFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "QdrantService not configured. Call configure() first."
        case .notConnected:
            return "Not connected to Qdrant server"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        }
    }
}

// MARK: - Convenience factory

extension QdrantService {
    /// Create a configured and connected QdrantService
    static func create(url: String, apiKey: String?) async throws -> QdrantService {
        let service = QdrantService()
        try await service.configure(url: url, apiKey: apiKey)
        try await service.connect()
        return service
    }
}
