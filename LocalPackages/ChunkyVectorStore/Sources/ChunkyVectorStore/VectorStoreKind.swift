public enum VectorStoreKind: String, CaseIterable, Sendable, Equatable {
    case qdrant
    case pgvector
    case weaviate
    case milvus
    case chroma

    public var displayName: String {
        switch self {
        case .qdrant: return "Qdrant"
        case .pgvector: return "Postgres pgvector"
        case .weaviate: return "Weaviate"
        case .milvus: return "Milvus"
        case .chroma: return "Chroma"
        }
    }

    public var usesPostgresURL: Bool { self == .pgvector }

    public static func resolved(stored: String?) -> VectorStoreKind {
        guard let stored, let kind = VectorStoreKind(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .qdrant
        }
        return kind
    }
}

public struct StoreCapabilities: Sendable, Equatable {
    public var snapshots: Bool
    public var localRuntime: Bool
    public var papersFirst: Bool
    public var sectionExpansion: Bool
    public var tenantIndex: Bool
    public var quantization: Bool
    public var hybrid: Bool
    public var directFromMac: Bool

    public static func of(_ kind: VectorStoreKind) -> StoreCapabilities {
        switch kind {
        case .qdrant:
            return StoreCapabilities(
                snapshots: true,
                localRuntime: true,
                papersFirst: true,
                sectionExpansion: true,
                tenantIndex: true,
                quantization: true,
                hybrid: true,
                directFromMac: true
            )
        case .pgvector:
            return StoreCapabilities(
                snapshots: false,
                localRuntime: false,
                papersFirst: false,
                sectionExpansion: false,
                tenantIndex: false,
                quantization: false,
                hybrid: true,
                directFromMac: true
            )
        case .weaviate:
            return StoreCapabilities(
                snapshots: false,
                localRuntime: false,
                papersFirst: false,
                sectionExpansion: false,
                tenantIndex: false,
                quantization: false,
                hybrid: true,
                directFromMac: false
            )
        case .milvus, .chroma:
            return StoreCapabilities(
                snapshots: false,
                localRuntime: false,
                papersFirst: false,
                sectionExpansion: false,
                tenantIndex: false,
                quantization: false,
                hybrid: false,
                directFromMac: false
            )
        }
    }
}

public enum StoreRoute: Sendable, Equatable {
    case qdrant
    case pgvector
    case worker(VectorStoreKind)
    case needsWorker(VectorStoreKind)
}

public enum StoreRouting {
    public static func route(kind: VectorStoreKind, devbox: Bool) -> StoreRoute {
        switch kind {
        case .qdrant:
            return .qdrant
        case .pgvector:
            return devbox ? .worker(.pgvector) : .pgvector
        case .weaviate, .milvus, .chroma:
            return devbox ? .worker(kind) : .needsWorker(kind)
        }
    }
}

public enum VectorStoreKeychain {
    public static let url = "vector_store_url"
    public static let apiKey = "vector_store_api_key"
    public static let qdrantURL = "qdrant_url"
    public static let qdrantAPIKey = "qdrant_api_key"
}

public enum VectorStoreDefaults {
    public static let kindKey = "chunky.vectorStore"
}

public struct WorkerStoreRequest: Sendable, Equatable {
    public var fields: [String: String]

    public static func fields(kind: VectorStoreKind, url: String, apiKey: String) -> [String: String] {
        guard kind != .qdrant else { return [:] }
        var fields = [
            "vector_store": kind.rawValue,
            "vector_store_url": url,
        ]
        if !apiKey.isEmpty {
            fields["vector_store_api_key"] = apiKey
        }
        return fields
    }
}
