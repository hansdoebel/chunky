import Foundation
import QdrantCore

// MARK: - Domain Types

/// A point to be stored in Qdrant with its embedding vector and metadata
struct ChunkPoint: Identifiable, Sendable {
    let id: String
    let vector: [Float]
    let sparseVector: SparseVector?
    let text: String
    let source: String
    let page: Int?
    let headings: [String]
    let year: Int?
    let metadata: [String: String]

    init(
        id: String = UUID().uuidString,
        vector: [Float],
        sparseVector: SparseVector? = nil,
        text: String,
        source: String,
        page: Int? = nil,
        headings: [String] = [],
        year: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.vector = vector
        self.sparseVector = sparseVector
        self.text = text
        self.source = source
        self.page = page
        self.headings = headings
        self.year = year
        self.metadata = metadata
    }
}

/// A point retrieved from Qdrant
struct QdrantPoint: Identifiable, Sendable {
    let id: String
    let text: String
    let source: String
    let page: Int?
    let headings: [String]
    let metadata: [String: String]

    init(
        id: String,
        text: String,
        source: String,
        page: Int? = nil,
        headings: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.page = page
        self.headings = headings
        self.metadata = metadata
    }
}

struct SearchResult: Identifiable, Sendable {
    let id: String
    let score: Float
    let text: String
    let source: String
    let page: Int?
    let headings: [String]
    let metadata: [String: String]

    init(
        id: String,
        score: Float,
        text: String,
        source: String,
        page: Int? = nil,
        headings: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.score = score
        self.text = text
        self.source = source
        self.page = page
        self.headings = headings
        self.metadata = metadata
    }
}

/// Collection information
struct CollectionInfo: Sendable {
    let name: String
    let vectorsCount: UInt64
    let pointsCount: UInt64
    let status: CollectionStatus
    /// Probed or stored dense vector width. Nil when the server did not report one.
    let vectorSize: Int?
    /// Named dense vector. Nil for a single unnamed vector.
    let vectorName: String?

    init(
        name: String,
        vectorsCount: UInt64,
        pointsCount: UInt64,
        status: CollectionStatus,
        vectorSize: Int? = nil,
        vectorName: String? = nil
    ) {
        self.name = name
        self.vectorsCount = vectorsCount
        self.pointsCount = pointsCount
        self.status = status
        self.vectorSize = vectorSize
        self.vectorName = vectorName
    }

    enum CollectionStatus: String, Sendable {
        case green
        case yellow
        case red
        case unknown
    }
}

// MARK: - Errors

enum QdrantError: LocalizedError, Sendable {
    case connectionFailed(String)
    case notConnected
    case invalidURL(String)
    case collectionNotFound(String)
    case collectionAlreadyExists(String)
    case operationFailed(String)
    case invalidResponse(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .notConnected:
            return "Not connected to Qdrant server"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .collectionNotFound(let name):
            return "Collection not found: \(name)"
        case .collectionAlreadyExists(let name):
            return "Collection already exists: \(name)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .timeout:
            return "Operation timed out"
        case .cancelled:
            return "Operation was cancelled"
        }
    }
}

// MARK: - Progress

struct UploadProgress: Sendable {
    let completed: Int
    let total: Int
    let currentBatch: Int
    let totalBatches: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var percentComplete: Int {
        Int(fraction * 100)
    }
}

// MARK: - QdrantCore Conversions

extension ChunkPoint {
    func toQdrantPoint() -> Point {
        var payload: [String: PayloadValue] = [
            "text": .string(text),
            "source": .string(source),
        ]

        if let page = page {
            payload["page"] = .integer(Int64(page))
        }

        if let year = year {
            payload["year"] = .integer(Int64(year))
        }

        if !headings.isEmpty {
            payload["headings"] = .array(headings.map { .string($0) })
        }

        for (key, value) in metadata {
            payload[key] = .string(value)
        }

        let vectorData: VectorData
        if let sparse = sparseVector {
            vectorData = .namedWithSparse(
                dense: ["dense": vector],
                sparse: ["sparse": sparse]
            )
        } else {
            vectorData = .dense(vector)
        }

        return Point(
            id: .uuid(id),
            vector: vectorData,
            payload: payload
        )
    }
}

private let reservedPayloadKeys: Set<String> = ["text", "source", "page", "headings"]

private func extractMetadata(from payload: [String: PayloadValue]?) -> [String: String] {
    guard let payload = payload else { return [:] }
    var meta: [String: String] = [:]
    for (key, value) in payload where !reservedPayloadKeys.contains(key) {
        if let s = value.stringValue {
            meta[key] = s
        }
    }
    return meta
}

extension ScoredPoint {
    func toSearchResult() -> SearchResult {
        let idString: String
        switch id {
        case .uuid(let uuid): idString = uuid
        case .integer(let num): idString = String(num)
        }

        return SearchResult(
            id: idString,
            score: score ?? 0,
            text: payload?["text"]?.stringValue ?? "",
            source: payload?["source"]?.stringValue ?? "",
            page: payload?["page"]?.integerValue.map { Int($0) },
            headings: payload?["headings"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            metadata: extractMetadata(from: payload)
        )
    }
}

extension RetrievedPoint {
    func toQdrantPoint() -> QdrantPoint {
        let idString: String
        switch id {
        case .uuid(let uuid): idString = uuid
        case .integer(let num): idString = String(num)
        }

        return QdrantPoint(
            id: idString,
            text: payload?["text"]?.stringValue ?? "",
            source: payload?["source"]?.stringValue ?? "",
            page: payload?["page"]?.integerValue.map { Int($0) },
            headings: payload?["headings"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            metadata: extractMetadata(from: payload)
        )
    }
}
