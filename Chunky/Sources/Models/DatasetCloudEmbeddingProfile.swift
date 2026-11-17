import CoreFoundation
import Foundation

nonisolated struct DatasetCloudPreembeddedRow: Sendable {
    let sourceID: String
    let text: String
    let vector: [Float]
}

nonisolated struct DatasetCloudEmbeddingProfile: Equatable, Sendable {
    let id: String
    let datasetID: String
    let revision: String
    let config: String
    let split: String
    let textField: String
    let vectorField: String
    let backend: String
    let model: String
    let dimensions: Int

    static let dbpedia = Self(
        id: "qdrant-dbpedia-openai-small-1536-v1",
        datasetID: "Qdrant/dbpedia-entities-openai3-text-embedding-3-small-1536-100K",
        revision: "0d5fd00fbc5a9c0c836d70cd409f7e461255e572",
        config: "default", split: "train", textField: "combined_text",
        vectorField: "text-embedding-3-small-1536-embedding",
        backend: "openai", model: "text-embedding-3-small", dimensions: 1536
    )

    static let all = [dbpedia]

    static func matching(datasetID: String, revision: String, config: String, split: String) -> Self? {
        all.first { $0.datasetID == datasetID && $0.revision == revision && $0.config == config && $0.split == split }
    }

    func validateConfiguration(backend: String, model: String, dimensions: Int? = nil) throws {
        guard backend == self.backend, model == self.model, dimensions == nil || dimensions == self.dimensions else {
            throw DatasetCloudEmbeddingError.invalid("This dataset requires \(self.backend) / \(self.model) with \(self.dimensions) dimensions. Matching dimensions alone do not establish model compatibility.")
        }
    }

    func decodeRow(_ data: Data) throws -> DatasetCloudPreembeddedRow {
        guard data.count <= 5 * 1024 * 1024,
              let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceID = row["_id"] as? String, !sourceID.isEmpty, sourceID.utf8.count <= 16_384,
              let text = row[textField] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatasetCloudEmbeddingError.invalid("The pre-embedded row is missing its declared source ID or complete embedding input text.")
        }
        return DatasetCloudPreembeddedRow(sourceID: sourceID, text: text, vector: try decodeVector(row[vectorField]))
    }

    func decodeQueryResponse(_ data: Data) throws -> [Float] {
        guard data.count <= 512 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["model"] as? String == model,
              let rows = object["data"] as? [[String: Any]], rows.count == 1,
              let index = rows[0]["index"] as? NSNumber,
              CFGetTypeID(index) != CFBooleanGetTypeID(), index.doubleValue == 0 else {
            throw DatasetCloudEmbeddingError.invalid("The query provider did not confirm the exact dataset model and a single indexed embedding. Use a compatible gateway that returns its model identity.")
        }
        return try decodeVector(rows[0]["embedding"])
    }

    private func decodeVector(_ value: Any?) throws -> [Float] {
        guard let values = value as? [Any], values.count == dimensions else {
            throw DatasetCloudEmbeddingError.invalid("The declared embedding column must contain exactly \(dimensions) dimensions. Legacy or alternate columns are never substituted.")
        }
        let vector = try values.map { value -> Float in
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, Float(number.doubleValue).isFinite else {
                throw DatasetCloudEmbeddingError.invalid("Dataset embeddings must contain finite numeric values, not booleans or strings.")
            }
            return Float(number.doubleValue)
        }
        guard vector.contains(where: { $0 != 0 }) else {
            throw DatasetCloudEmbeddingError.invalid("The dataset contains a zero embedding vector.")
        }
        return vector
    }
}

nonisolated enum DatasetCloudEmbeddingError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

@MainActor
enum DatasetCloudCollectionIdentity {
    private static let key = "chunky.datasetCloud.embeddingProfiles"

    static func register(collection: String, profile: DatasetCloudEmbeddingProfile, defaults: UserDefaults = .standard) throws {
        guard collection.hasPrefix("chunky-dataset-test-"),
              UUID(uuidString: String(collection.dropFirst("chunky-dataset-test-".count))) != nil,
              DatasetCloudEmbeddingProfile.all.contains(profile) else {
            throw DatasetCloudEmbeddingError.invalid("Only a newly created dataset test collection can receive a verified embedding profile.")
        }
        if defaults.object(forKey: key) != nil, defaults.dictionary(forKey: key) == nil {
            throw DatasetCloudEmbeddingError.invalid("The saved dataset embedding identity registry is invalid and will not be overwritten.")
        }
        var records = defaults.dictionary(forKey: key) ?? [:]
        if let previous = records[collection], previous as? String != profile.id {
            throw DatasetCloudEmbeddingError.invalid("The collection already has another embedding identity; it will not be overwritten.")
        }
        records[collection] = profile.id
        defaults.set(records, forKey: key)
    }

    static func profile(collection: String, defaults: UserDefaults = .standard) throws -> DatasetCloudEmbeddingProfile? {
        if defaults.object(forKey: key) != nil, defaults.dictionary(forKey: key) == nil {
            throw DatasetCloudEmbeddingError.invalid("The saved dataset embedding identity registry is invalid.")
        }
        guard let record = defaults.dictionary(forKey: key)?[collection] else { return nil }
        guard let id = record as? String, let profile = DatasetCloudEmbeddingProfile.all.first(where: { $0.id == id }) else {
            throw DatasetCloudEmbeddingError.invalid("The saved dataset embedding identity is invalid. Refusing to mix or query unknown vectors.")
        }
        return profile
    }

    static func validate(collection: String, backend: String, model: String, defaults: UserDefaults = .standard) throws {
        try profile(collection: collection, defaults: defaults)?.validateConfiguration(backend: backend, model: model)
    }
}
