import Combine
import Foundation
import QdrantCore
import QdrantGRPC

@MainActor
class QdrantService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionError: String?
    @Published private(set) var serverVersion: String?

    @Published private(set) var indexError: String?
    private var handle: QdrantClientHandle?
    private var connectingHandle: QdrantClientHandle?
    private var connectingTask: Task<Void, Error>?
    private var connectingTimeout: Int?
    private var connectedTimeout: Int?
    private var connectionWaiters: Set<UUID> = []
    private var deliveredConnection = false
    var pendingConnectionCount: Int { connectionWaiters.count }
    private var client: QdrantGRPCClient? { handle?.client }
    private let makeClient: (QdrantConfiguration) async throws -> QdrantClientHandle
    private var generation = 0
    private var pendingUrl: String?
    private var pendingApiKey: String?
    private var indexedCollections: Set<String> = []
    private var indexErrors: [String: String] = [:]
    private var collectionGenerations: [String: Int] = [:]

    init(makeClient: @escaping (QdrantConfiguration) async throws -> QdrantClientHandle = QdrantClientHandle.live) {
        self.makeClient = makeClient
    }

    private func invalidateConnection() {
        generation += 1
        connectingTask?.cancel()
        connectingTask = nil
        connectingTimeout = nil
        connectedTimeout = nil
        connectionWaiters.removeAll()
        deliveredConnection = false
        connectingHandle?.close()
        connectingHandle = nil
        handle?.close()
        handle = nil
        indexedCollections.removeAll()
        collectionGenerations.removeAll()
        isConnected = false
        serverVersion = nil
        connectionError = nil
        indexErrors.removeAll()
        indexError = nil
    }

    private func updateIndexError(collection: String, message: String?) {
        indexErrors[collection] = message
        let messages = indexErrors.keys.sorted().compactMap { indexErrors[$0] }
        indexError = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func configure(url: String, apiKey: String?) async throws {
        if pendingUrl != url || pendingApiKey != apiKey { invalidateConnection() }
        pendingUrl = url
        pendingApiKey = apiKey
    }

    func connect(timeout: Int = 30) async throws {
        try Task.checkCancellation()
        if let task = connectingTask, connectingTimeout == timeout {
            try await waitForConnection(task, started: generation)
            return
        }
        if isConnected, connectedTimeout == timeout { return }
        guard let url = pendingUrl else { throw QdrantServiceError.notConfigured }
        let apiKey = pendingApiKey
        invalidateConnection()
        let started = generation
        let task = Task { try await performConnect(url: url, apiKey: apiKey, timeout: timeout, started: started) }
        connectingTask = task
        connectingTimeout = timeout
        try await waitForConnection(task, started: started)
    }

    private func waitForConnection(_ task: Task<Void, Error>, started: Int) async throws {
        let waiter = UUID()
        connectionWaiters.insert(waiter)
        defer {
            if started == generation {
                connectionWaiters.remove(waiter)
                if connectionWaiters.isEmpty {
                    connectingTask = nil
                    connectingTimeout = nil
                }
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelConnectionWaiter(waiter, started: started) }
            }
            deliveredConnection = true
        } catch {
            if Task.isCancelled {
                cancelConnectionWaiter(waiter, started: started)
                throw CancellationError()
            }
            throw error
        }
    }

    private func cancelConnectionWaiter(_ waiter: UUID, started: Int) {
        guard started == generation else { return }
        guard connectionWaiters.remove(waiter) != nil else { return }
        if connectionWaiters.isEmpty, !deliveredConnection { invalidateConnection() }
    }

    private func performConnect(url: String, apiKey: String?, timeout: Int, started: Int) async throws {
        try Task.checkCancellation()
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            throw QdrantServiceError.invalidURL(url)
        }
        var candidate: QdrantClientHandle?
        do {
            let config = try QdrantConfiguration(host: host, port: components.port ?? 6334,
                apiKey: apiKey, useTLS: components.scheme?.lowercased() == "https", timeout: .seconds(timeout))
            let created = try await makeClient(config)
            candidate = created
            guard started == generation else { throw CancellationError() }
            try Task.checkCancellation()
            connectingHandle = created
            let health = try await created.healthCheck()
            try Task.checkCancellation()
            guard started == generation else { throw CancellationError() }
            connectingHandle = nil
            handle = created
            serverVersion = health.version
            isConnected = true
            connectedTimeout = timeout
            connectionError = nil
        } catch {
            candidate?.close()
            guard started == generation else { throw CancellationError() }
            connectingHandle = nil
            isConnected = false
            serverVersion = nil
            if error is CancellationError { throw error }
            let message = PreferenceDiagnostic.message(error.localizedDescription, secrets: [apiKey ?? ""])
            connectionError = message
            throw QdrantServiceError.connectionFailed(message)
        }
    }

    func disconnect() async {
        invalidateConnection()
    }

    func testConnection() async -> Bool {
        guard let handle else { return false }
        let started = generation
        do {
            _ = try await handle.healthCheck()
            return started == generation && isConnected
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
            indexedCollections.remove(name)
            collectionGenerations[name, default: 0] += 1
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
        let started = generation
        let collectionStarted = collectionGenerations[collection, default: 0]
        do {
            try await createPayloadIndexes(collection: collection)
        } catch {
            guard started == generation, collectionStarted == collectionGenerations[collection, default: 0], !(error is CancellationError) else { return }
            updateIndexError(collection: collection, message: PreferenceDiagnostic.message("Payload indexes for \(collection): \(error.localizedDescription)", secrets: [pendingApiKey ?? ""]))
        }
    }

    func createPayloadIndexes(collection: String) async throws {
        guard let handle else { throw QdrantServiceError.notConnected }
        let started = generation
        let collectionStarted = collectionGenerations[collection, default: 0]
        let apiKey = pendingApiKey ?? ""
        let fields: [(String, FieldType)] =
            ["source", "content_type", "content_types", "language", "doi", "picture_class", "record_type"].map { ($0, .keyword) }
            + ["doc_title", "authors", "headings", "picture_description", "table_markdown", "embedding_text"].map { ($0, .text) }
            + ["page", "page_end", "year"].map { ($0, .integer) }
            + [(PaperLibrary.field, .keyword)]
        for (field, type) in fields {
            try Task.checkCancellation()
            guard started == generation, collectionStarted == collectionGenerations[collection, default: 0] else { throw CancellationError() }
            do {
                try await handle.createFieldIndex(collection, field, type, field == PaperLibrary.field)
            } catch QdrantGRPC.QdrantError.collectionAlreadyExists {
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = PreferenceDiagnostic.message(error.localizedDescription, secrets: [apiKey])
                throw QdrantServiceError.operationFailed("Could not create index \(field): \(message)")
            }
        }
        try Task.checkCancellation()
        guard started == generation, collectionStarted == collectionGenerations[collection, default: 0] else { throw CancellationError() }
        indexedCollections.insert(collection)
        updateIndexError(collection: collection, message: nil)
    }

    func deleteCollection(_ name: String) async throws {
        guard let handle else { throw QdrantServiceError.notConnected }
        let started = generation
        indexedCollections.remove(name)
        collectionGenerations[name, default: 0] += 1
        defer {
            if started == generation {
                indexedCollections.remove(name)
                collectionGenerations[name, default: 0] += 1
            }
        }
        try await handle.deleteCollection(name)
        if started == generation { updateIndexError(collection: name, message: nil) }
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
        guard let handle else { throw QdrantServiceError.notConnected }
        guard !ids.isEmpty, !fields.isEmpty else { return }
        try await handle.setPayload(
            collectionName,
            ids.map { StoredPointID.parse($0) },
            fields.mapValues { PayloadValue.string($0) }
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
        guard let handle else { throw QdrantServiceError.notConnected }
        try await handle.deletePoints(collectionName, ids.map { StoredPointID.parse($0) })
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
