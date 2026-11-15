import Foundation

enum CollectionTarget: String, Codable, CaseIterable, Identifiable {
    case localDocker
    case qdrantCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localDocker: return "Local Docker"
        case .qdrantCloud: return "Qdrant Cloud"
        }
    }
}

enum CollectionDistance: String, Codable, CaseIterable, Identifiable {
    case cosine
    case dot
    case euclid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cosine: return "Cosine"
        case .dot: return "Dot"
        case .euclid: return "Euclid"
        }
    }

    // https://qdrant.tech/documentation/concepts/search/#metrics
    var hint: String {
        switch self {
        case .cosine:
            return "Default for normalized text embeddings such as qwen3-embedding."
        case .dot:
            return "Use only when the model documentation says the vectors are not normalized."
        case .euclid:
            return "Rare for text embeddings."
        }
    }
}

enum CollectionQuantization: String, Codable, CaseIterable, Identifiable {
    case none
    case scalarInt8
    case binary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .scalarInt8: return "Scalar int8"
        case .binary: return "Binary"
        }
    }

    // https://qdrant.tech/documentation/guides/quantization/
    var hint: String {
        switch self {
        case .none:
            return "Full float32 vectors."
        case .scalarInt8:
            return "About 4× smaller. Qdrant can rescore the original vectors."
        case .binary:
            return "Only for high-dimensional models that document binary quantization."
        }
    }

    func bytesPerDimension(vectorSize: Int) -> Double {
        switch self {
        case .none: return 4
        case .scalarInt8: return 1
        case .binary: return vectorSize > 0 ? 1.0 / 8.0 : 0
        }
    }
}

enum CollectionPreset: String, Codable, CaseIterable, Identifiable {
    case recommended
    case smallFastLocal
    case largeCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recommended: return "Recommended"
        case .smallFastLocal: return "Small / fast local"
        case .largeCloud: return "Large Cloud corpus"
        }
    }
}

struct CollectionPlan: Codable, Equatable {
    var name: String
    var target: CollectionTarget
    var embeddingBackend: String
    var embeddingModel: String
    var vectorSize: Int
    var distance: CollectionDistance
    var hybrid: Bool
    var quantization: CollectionQuantization
    var onDisk: Bool
    var expectedChunks: Int
    var payloadIndexes: [String]

    static let defaultIndexes = [
        "source", "doc_title", "authors", "content_type", "language", "doi",
        "page", "year", "picture_class", "picture_description", "table_markdown", "embedding_text",
    ]

    static func preset(
        _ preset: CollectionPreset,
        name: String,
        vectorSize: Int,
        embeddingBackend: String,
        embeddingModel: String
    ) -> CollectionPlan {
        switch preset {
        case .recommended:
            return CollectionPlan(
                name: name, target: .localDocker, embeddingBackend: embeddingBackend,
                embeddingModel: embeddingModel, vectorSize: vectorSize, distance: .cosine,
                hybrid: true, quantization: .scalarInt8, onDisk: false, expectedChunks: 10_000,
                payloadIndexes: defaultIndexes
            )
        case .smallFastLocal:
            return CollectionPlan(
                name: name, target: .localDocker, embeddingBackend: embeddingBackend,
                embeddingModel: embeddingModel, vectorSize: vectorSize, distance: .cosine,
                hybrid: false, quantization: .none, onDisk: false, expectedChunks: 1_000,
                payloadIndexes: defaultIndexes
            )
        case .largeCloud:
            return CollectionPlan(
                name: name, target: .qdrantCloud, embeddingBackend: embeddingBackend,
                embeddingModel: embeddingModel, vectorSize: vectorSize, distance: .cosine,
                hybrid: true, quantization: .scalarInt8, onDisk: true, expectedChunks: 100_000,
                payloadIndexes: defaultIndexes
            )
        }
    }

    // Collection names: letters, numbers, hyphens, and underscores.
    static func nameError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a collection name." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use only letters, numbers, hyphens, and underscores."
        }
        return nil
    }

    func existsWarning(existingNames: [String]) -> String? {
        if existingNames.contains(name) {
            return "A collection named \(name) already exists."
        }
        return nil
    }

    var binaryWarning: String? {
        if quantization == .binary && vectorSize < 1024 {
            return "Binary quantization is for high-dimensional models. This vector size is \(vectorSize)."
        }
        return nil
    }

    // https://qdrant.tech/documentation/concepts/storage/
    var storageHint: String {
        onDisk
            ? "On-disk vectors and payload suit large collections and the Qdrant Cloud free tier."
            : "In-memory storage is faster and uses more RAM."
    }

    // https://qdrant.tech/documentation/concepts/hybrid-queries/
    var hybridHint: String {
        "Named dense plus a sparse BM25 vector. Better keyword and exact-term recall, with a small amount of extra storage. Query-time fusion is PER-84."
    }

    var vectorSizeHint: String {
        "Size is fixed after creation. Changing models means a new collection."
    }

    struct Estimate: Equatable {
        var ramBytes: Double
        var diskBytes: Double
        var isEstimate: Bool { true }
    }

    func estimate() -> Estimate {
        let dense = Double(max(expectedChunks, 0) * max(vectorSize, 0)) * quantization.bytesPerDimension(vectorSize: vectorSize)
        let sparse = hybrid ? dense * 0.1 : 0
        let payload = Double(max(expectedChunks, 0)) * 512
        let total = dense + sparse + payload
        if onDisk {
            return Estimate(ramBytes: total * 0.1, diskBytes: total)
        }
        return Estimate(ramBytes: total, diskBytes: total * 0.2)
    }

    func mismatch(existingVectorSize: Int?, existingHybrid: Bool?) -> String? {
        if let existingVectorSize, existingVectorSize != vectorSize {
            return "Collection \(name) has vector size \(existingVectorSize), but this plan uses \(vectorSize)."
        }
        if let existingHybrid, existingHybrid != hybrid {
            return "Collection \(name) \(existingHybrid ? "has" : "does not have") a sparse vector, but this plan \(hybrid ? "enables" : "disables") hybrid search."
        }
        return nil
    }
}

enum CollectionPlanStore {
    private static let prefix = "chunky.collectionPlan."

    static func save(_ plan: CollectionPlan, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(plan) {
            defaults.set(data, forKey: prefix + plan.name)
        }
    }

    static func load(name: String, defaults: UserDefaults = .standard) -> CollectionPlan? {
        guard let data = defaults.data(forKey: prefix + name) else { return nil }
        return try? JSONDecoder().decode(CollectionPlan.self, from: data)
    }
}
