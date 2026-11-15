import Foundation

enum MemoryTier: String, Codable, CaseIterable, Identifiable {
    case cold
    case cached
    case pinned

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cold: return "Cold"
        case .cached: return "Cached"
        case .pinned: return "Pinned"
        }
    }
}

struct CollectionPacking: Equatable, Codable {
    var vectors: MemoryTier
    var hnsw: MemoryTier
    var quantizationTier: MemoryTier
    var payload: MemoryTier
    var quantization: CollectionQuantization

    static let freeTier = CollectionPacking(
        vectors: .cold,
        hnsw: .cold,
        quantizationTier: .pinned,
        payload: .cold,
        quantization: .scalarInt8
    )

    static let localDefault = CollectionPacking(
        vectors: .cached,
        hnsw: .cached,
        quantizationTier: .pinned,
        payload: .cold,
        quantization: .scalarInt8
    )

    var tierError: String? {
        if vectors == .pinned || payload == .pinned {
            return "Dense vectors and payload cannot be pinned. Use cached or cold."
        }
        return nil
    }

    var hint: String {
        "Cold stays on disk until it is read. Cached is warmed at startup. Pinned stays in RAM. Dense vectors and payload cannot be pinned."
    }

    func createBody(vectorSize: Int, distance: String) -> [String: Any] {
        var body: [String: Any] = [
            "vectors": [
                "size": vectorSize,
                "distance": distance,
                "memory": vectors.rawValue,
            ],
            "hnsw_config": ["memory": hnsw.rawValue],
            "payload": ["memory": payload.rawValue],
        ]
        if let quantization = quantizationBody() {
            body["quantization_config"] = quantization
        }
        return body
    }

    func updateBody(vectorName: String = "") -> [String: Any] {
        var body: [String: Any] = [
            "vectors": [vectorName: ["memory": vectors.rawValue]],
            "hnsw_config": ["memory": hnsw.rawValue],
            "payload": ["memory": payload.rawValue],
            "quantization_config": quantizationBody() ?? NSNull(),
        ]
        return body
    }

    static func vectorName(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let result = (object["result"] as? [String: Any]) ?? object
        guard let config = result["config"] as? [String: Any],
              let params = config["params"] as? [String: Any],
              let vectors = params["vectors"] as? [String: Any]
        else { return "" }
        if vectors["size"] != nil { return "" }
        if vectors["dense"] != nil { return "dense" }
        return vectors.keys.sorted().first ?? ""
    }

    private func quantizationBody() -> [String: Any]? {
        switch quantization {
        case .none:
            return nil
        case .scalarInt8:
            return ["scalar": ["type": "int8", "memory": quantizationTier.rawValue]]
        case .binary:
            return ["binary": ["memory": quantizationTier.rawValue]]
        }
    }
}

enum CollectionPackingStore {
    private static let prefix = "chunky.collectionPacking."

    static func save(_ packing: CollectionPacking, name: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(packing) else { return }
        defaults.set(data, forKey: prefix + name)
    }

    static func load(name: String, defaults: UserDefaults = .standard) -> CollectionPacking? {
        guard let data = defaults.data(forKey: prefix + name) else { return nil }
        return try? JSONDecoder().decode(CollectionPacking.self, from: data)
    }
}

protocol CollectionPackingTransport: Sendable {
    func send(method: String, url: URL, apiKey: String, body: Data) async throws -> (status: Int, body: Data)
}

enum CollectionPackingError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

struct CollectionPackingClient: Sendable {
    var transport: any CollectionPackingTransport

    func update(baseURL: String, apiKey: String, collection: String, packing: CollectionPacking) async throws {
        if let error = packing.tierError { throw CollectionPackingError.invalid(error) }
        guard var infoURL = CollectionSnapshots.restBase(qdrantURL: baseURL) else {
            throw QdrantHealthError.invalidURL(baseURL)
        }
        infoURL.appendPathComponent("collections")
        infoURL.appendPathComponent(collection)
        let info = try await transport.send(method: "GET", url: infoURL, apiKey: apiKey, body: Data())
        guard (200..<300).contains(info.status) else {
            throw QdrantHealthError.http(info.status)
        }
        let name = CollectionPacking.vectorName(in: info.body)
        try await send(method: "PATCH", baseURL: baseURL, apiKey: apiKey, collection: collection, body: packing.updateBody(vectorName: name))
    }

    func create(baseURL: String, apiKey: String, collection: String, packing: CollectionPacking, vectorSize: Int, distance: String) async throws {
        if let error = packing.tierError { throw CollectionPackingError.invalid(error) }
        try await send(
            method: "PUT",
            baseURL: baseURL,
            apiKey: apiKey,
            collection: collection,
            body: packing.createBody(vectorSize: vectorSize, distance: distance)
        )
    }

    private func send(method: String, baseURL: String, apiKey: String, collection: String, body: [String: Any]) async throws {
        guard var url = CollectionSnapshots.restBase(qdrantURL: baseURL) else {
            throw QdrantHealthError.invalidURL(baseURL)
        }
        url.appendPathComponent("collections")
        url.appendPathComponent(collection)
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.send(method: method, url: url, apiKey: apiKey, body: data)
        guard (200..<300).contains(response.status) else {
            throw QdrantHealthError.http(response.status)
        }
    }
}

struct LiveCollectionPackingTransport: CollectionPackingTransport {
    func send(method: String, url: URL, apiKey: String, body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum SnapshotReminder {
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    static func message(records: [SnapshotRecord], now: Date) -> String {
        let latest = records.compactMap { date($0.creationTime) }.max()
        if let latest, now.timeIntervalSince(latest) < interval {
            return ""
        }
        return "No snapshot in the last 7 days. Free Qdrant Cloud has no scheduled backups. Create one here and download it."
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
