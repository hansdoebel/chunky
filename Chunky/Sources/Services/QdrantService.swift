import Combine
import Foundation
import QdrantCore
import QdrantGRPC

@MainActor
class QdrantService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionError: String?
    @Published private(set) var serverVersion: String?

    private var client: QdrantGRPCClient?
    private var pendingUrl: String?
    private var pendingApiKey: String?
    private var indexedCollections: Set<String> = []

    func configure(url: String, apiKey: String?) async throws {

        self.pendingUrl = url
        self.pendingApiKey = apiKey
    }

    func connect(timeout: Int = 30) async throws {
        guard let url = pendingUrl else {
            throw QdrantServiceError.notConfigured
        }

        guard let urlComponents = URLComponents(string: url),
            let host = urlComponents.host, !host.isEmpty
        else {
            throw QdrantServiceError.invalidURL(url)
        }

        let useTLS = urlComponents.scheme == "https"
        let port = urlComponents.port ?? 6334

        do {

            client?.close()

            let config = try QdrantConfiguration(
                host: host,
                port: port,
                apiKey: pendingApiKey,
                useTLS: useTLS,
                timeout: .seconds(timeout)
            )
            let newClient = try await QdrantGRPCClient(configuration: config)

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
            status: status,
            vectorSize: info.vectorSize.map { Int($0) },
            vectorName: info.vectorName
        )
    }

    func createDatasetTestCollection(name: String, vectorSize: Int, productionCollection: String) async throws {
        try DatasetBenchmarkSafety.validateCollection(name, production: productionCollection)
        guard (1...16384).contains(vectorSize) else {
            throw DatasetBenchmarkError.invalid("Invalid dataset embedding dimensions.")
        }
        guard let client else { throw QdrantServiceError.notConnected }
        try await client.collections.create(name: name, vectorSize: vectorSize, distance: .cosine)
    }

    func createCollectionIfNeeded(
        name: String,
        vectorSize: Int,
        hybrid: Bool = false,
        distance: Distance = .cosine,
        onDiskVectors: Bool? = nil,
        onDiskPayload: Bool? = nil,
        quantizationConfig: QuantizationConfig? = nil
    ) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        let exists = try await client.collections.exists(name: name)
        if !exists {
            let payloadOnDisk = onDiskPayload ?? (hybrid ? true : nil)
            let dense = VectorConfig(size: vectorSize, distance: distance, onDisk: onDiskVectors)
            if hybrid {
                try await client.collections.create(
                    name: name,
                    vectors: .named(["dense": dense]),
                    sparseVectors: ["sparse": SparseVectorParams(modifier: .idf)],
                    onDiskPayload: payloadOnDisk,
                    quantizationConfig: quantizationConfig
                )
            } else if onDiskVectors != nil {
                try await client.collections.create(
                    name: name,
                    vectors: .single(dense),
                    onDiskPayload: payloadOnDisk,
                    quantizationConfig: quantizationConfig
                )
            } else {
                try await client.collections.create(
                    name: name,
                    vectorSize: UInt64(vectorSize),
                    distance: distance,
                    onDiskPayload: payloadOnDisk,
                    quantizationConfig: quantizationConfig
                )
            }
        }
        try await createPayloadIndexes(collection: name)
        if hybrid {
            try await ensureBM25TextIndex(collection: name)
        }
    }

    func ensureBM25TextIndex(collection: String) async throws {
        guard let base = pendingUrl, let endpoint = HybridQuery.indexURL(qdrantURL: base, collection: collection) else {
            throw QdrantServiceError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = pendingApiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: HybridQuery.indexBody())
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QdrantServiceError.operationFailed("No HTTP response while creating the BM25 text index")
        }
        if (200..<300).contains(http.statusCode) || http.statusCode == 409 {
            return
        }
        let detail = String(data: data, encoding: .utf8) ?? ""
        if detail.lowercased().contains("already exists") {
            return
        }
        throw QdrantServiceError.operationFailed("BM25 text index failed with HTTP \(http.statusCode). \(detail)")
    }

    func ensureRetrievalIndexes(collection: String) async {
        if indexedCollections.contains(collection) { return }
        try? await createPayloadIndexes(collection: collection)
        indexedCollections.insert(collection)
    }

    func createPayloadIndexes(collection: String) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }

        let keywordFields = ["source", "content_type", "content_types", "language", "doi", "picture_class", "record_type"]
        let textFields = ["doc_title", "authors", "headings", "picture_description", "table_markdown", "embedding_text"]
        let integerFields = ["page", "page_end", "year"]

        for field in keywordFields {
            try? await client.points.createFieldIndex(
                collection: collection, fieldName: field, fieldType: .keyword, wait: false
            )
        }
        for field in textFields {
            try? await client.points.createFieldIndex(
                collection: collection, fieldName: field, fieldType: .text, wait: false
            )
        }
        for field in integerFields {
            try? await client.points.createFieldIndex(
                collection: collection, fieldName: field, fieldType: .integer, wait: false
            )
        }
        try? await client.points.createFieldIndex(
            collection: collection,
            fieldName: PaperLibrary.field,
            fieldType: .keyword,
            wait: false,
            isTenant: true
        )
    }

    func deleteCollection(_ name: String) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        try await client.collections.delete(name: name)
    }

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
        sourceFilter: String? = nil,
        filter: Filter? = nil,
        offset: Int? = nil,
        vectorName: String? = nil
    ) async throws -> [SearchResult] {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        await ensureRetrievalIndexes(collection: collectionName)

        let resolved: Filter?
        if let filter {
            resolved = filter
        } else if let sourceFilter, !sourceFilter.isEmpty {
            resolved = Filter(
                must: [
                    .field(
                        FieldCondition(
                            key: "source",
                            match: .keyword(sourceFilter)
                        ))
                ]
            )
        } else {
            resolved = nil
        }

        let results = try await client.points.search(
            collection: collectionName,
            vector: vector,
            limit: UInt64(limit),
            filter: resolved,
            scoreThreshold: nil,
            offset: offset.map { UInt64($0) },
            withPayload: true,
            withVectors: false,
            vectorName: vectorName
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
            query: .nearest(.dense(denseVector)),
            using: "dense",
            filter: filter,
            limit: UInt64(limit)
        )

        let sparsePrefetch = PrefetchQuery(
            query: .nearest(.sparse(indices: sparseVector.indices, values: sparseVector.values)),
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

            if allPoints.count >= limit {
                break
            }
        } while offset != nil

        return Array(allPoints.prefix(limit))
    }

    func getSources(collectionName: String) async throws -> [String] {
        let points = try await loadPoints(collectionName: collectionName, limit: 10000)
        let sources = Set(points.map { $0.source })
        return Array(sources).sorted()
    }

    func setPayload(collectionName: String, ids: [String], fields: [String: String]) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        guard !ids.isEmpty, !fields.isEmpty else { return }
        try await client.points.setPayload(
            collection: collectionName,
            ids: ids.map { PointID.uuid($0) },
            payload: fields.mapValues { PayloadValue.string($0) },
            wait: true
        )
    }

    func movePoints(collectionName: String, ids: [String], libraryID: String) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        let plan = LibraryMove.plan(ids: ids, libraryID: libraryID)
        guard !plan.ids.isEmpty, !plan.reembed else { return }
        let payload = plan.payload.mapValues { PayloadValue.string($0) }
        try await client.points.setPayload(
            collection: collectionName,
            ids: plan.ids.map { StoredPointID.parse($0) },
            payload: payload,
            wait: true
        )
    }

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

    func deleteBySource(collectionName: String, source: String, libraryID: String? = nil) async throws {
        guard let client = client else {
            throw QdrantServiceError.notConnected
        }
        var must: [Condition] = [.field(key: "source", match: .keyword(source))]
        if let libraryID, let library = RetrievalFilter.qdrantFilter(LibraryFilter.membership(ids: [libraryID])) {
            must.append(contentsOf: library.must)
        }
        let filter = Filter(must: must)
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

enum StoredPointID {
    static func parse(_ raw: String) -> PointID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let number = UInt64(trimmed) {
            return .integer(number)
        }
        return .uuid(trimmed)
    }

    static func wire(_ raw: String) -> String {
        switch parse(raw) {
        case .integer(let number):
            return "integer:\(number)"
        case .uuid(let value):
            return "uuid:\(value)"
        }
    }
}

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

extension QdrantService {

    static func create(url: String, apiKey: String?) async throws -> QdrantService {
        let service = QdrantService()
        try await service.configure(url: url, apiKey: apiKey)
        try await service.connect()
        return service
    }
}
