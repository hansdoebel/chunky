import Foundation

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
