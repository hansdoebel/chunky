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

    var settingsValue: String {
        switch self {
        case .cosine: return DistanceMetric.cosine.rawValue
        case .dot: return DistanceMetric.dot.rawValue
        case .euclid: return DistanceMetric.euclidean.rawValue
        }
    }

    init(settingsValue: String) {
        switch settingsValue.lowercased() {
        case "dot", "dot product": self = .dot
        case "euclid", "euclidean": self = .euclid
        default: self = .cosine
        }
    }

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

    var settingsValue: String {
        switch self {
        case .none: return Compression.none.rawValue
        case .scalarInt8: return Compression.scalar.rawValue
        case .binary: return Compression.binary.rawValue
        }
    }

    var wireValue: String {
        switch self {
        case .none: return "none"
        case .scalarInt8: return "scalar"
        case .binary: return "binary"
        }
    }

    init(settingsValue: String) {
        switch settingsValue.lowercased() {
        case "scalar": self = .scalarInt8
        case "binary": self = .binary
        default: self = .none
        }
    }

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
        "headings", "page", "page_end", "year", "picture_class", "picture_description", "table_markdown", "embedding_text",
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

    var storageHint: String {
        onDisk
            ? "On-disk vectors and payload suit large collections and the Qdrant Cloud free tier."
            : "In-memory storage is faster and uses more RAM."
    }

    var hybridHint: String {
        "Named dense plus a sparse BM25 vector. Better keyword and exact-term recall, with a small amount of extra storage. Retrieval fuses the dense vector with BM25 using RRF."
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

    func connectionProblem(localURL: String, cloudURL: String, cloudAPIKey: String) -> String? {
        switch target {
        case .localDocker:
            if localURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Set the local Qdrant URL before saving a local collection."
            }
        case .qdrantCloud:
            if cloudURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloudAPIKey.isEmpty {
                return "Set the Qdrant Cloud URL and API key before saving a Cloud collection."
            }
        }
        return nil
    }

    static func canSave(name: String, vectorVerified: Bool, connectionProblem: String?) -> Bool {
        nameError(name) == nil && vectorVerified && connectionProblem == nil
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

struct CollectionCreateOptions: Equatable {
    var hybrid: Bool
    var distance: CollectionDistance
    var quantization: CollectionQuantization
    var onDiskVectors: Bool?
    var onDiskPayload: Bool?
    var target: CollectionTarget
    var expectedVectorSize: Int?

    var storesOnDisk: Bool { onDiskPayload == true }
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

    static func names(defaults: UserDefaults = .standard) -> [String] {
        defaults.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let name = String(key.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }.sorted()
    }

    static func mergedNames(server: [String], selected: String? = nil, defaults: UserDefaults = .standard) -> [String] {
        var seen = Set(server)
        var merged = server
        for name in names(defaults: defaults) where seen.insert(name).inserted {
            merged.append(name)
        }
        if let selected, !selected.isEmpty, seen.insert(selected).inserted {
            merged.append(selected)
        }
        return merged
    }

    static func options(collection: String, settings: AppSettings, defaults store: UserDefaults? = nil) -> CollectionCreateOptions {
        let defaults = store ?? settings.defaults
        if let plan = load(name: collection, defaults: defaults) {
            return CollectionCreateOptions(
                hybrid: plan.hybrid,
                distance: plan.distance,
                quantization: plan.quantization,
                onDiskVectors: plan.onDisk,
                onDiskPayload: plan.onDisk,
                target: plan.target,
                expectedVectorSize: plan.vectorSize
            )
        }
        return CollectionCreateOptions(
            hybrid: settings.hybridSearch,
            distance: CollectionDistance(settingsValue: settings.qdrantDistanceMetric),
            quantization: CollectionQuantization(settingsValue: settings.qdrantCompression),
            onDiskVectors: nil,
            onDiskPayload: settings.hybridSearch ? true : nil,
            target: settings.devboxIngestTarget == .qdrantCloud ? .qdrantCloud : .localDocker,
            expectedVectorSize: nil
        )
    }
}
