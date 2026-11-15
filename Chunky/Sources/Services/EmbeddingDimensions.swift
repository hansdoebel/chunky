import Foundation

nonisolated enum EmbeddingWidth {
    static let defaultModel = "qwen3-embedding:0.6b"
    static let defaultDimensions = 1024

    static func expected(for modelName: String) -> Int {
        let name = modelName.lowercased()
        if name.contains("qwen3"), name.contains("embed") {
            if name.contains("0.6") { return 1024 }
            if name.contains("4b") { return 2560 }
            if name.contains("8b") || name.hasSuffix(":latest") { return 4096 }
            return defaultDimensions
        }
        if name.contains("snowflake") || name.contains("arctic") || name.contains("mxbai")
            || name.contains("bge-m3") || name.contains("bge-large") || name.contains("e5-large")
            || name.contains("gte-large")
        {
            return 1024
        }
        if name.contains("minilm") || name.contains("e5-small") || name.contains("bge-small") {
            return 384
        }
        if name.contains("large") { return 1024 }
        return 768
    }
}

nonisolated enum EmbeddingDimensionError: Error, LocalizedError, Equatable {
    case mismatch(collection: String, existing: Int, probed: Int, model: String)
    case emptyProbe(String)
    case batchMismatch(model: String, probed: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .mismatch(let collection, let existing, let probed, let model):
            return "Collection \(collection) has vector size \(existing), but \(model) produces vectors of size \(probed). Refusing to upsert."
        case .emptyProbe(let model):
            return "Embedding probe for \(model) returned an empty vector."
        case .batchMismatch(let model, let probed, let actual):
            return "Embedding probe for \(model) returned size \(probed), but the batch returned size \(actual)."
        }
    }

    static func validate(existing: Int?, probed: Int, collection: String, model: String) throws {
        if let existing, existing != probed {
            throw EmbeddingDimensionError.mismatch(
                collection: collection,
                existing: existing,
                probed: probed,
                model: model
            )
        }
    }
}

nonisolated final class EmbeddingDimensionCache: @unchecked Sendable {
    static let probeText = "chunky"

    private let lock = NSLock()
    private var sizes: [String: Int] = [:]

    func cached(_ model: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return sizes[model]
    }

    func store(model: String, vector: [Float]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sizes[model] {
            return existing
        }
        guard !vector.isEmpty else {
            throw EmbeddingDimensionError.emptyProbe(model)
        }
        sizes[model] = vector.count
        return vector.count
    }
}
