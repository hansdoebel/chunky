import CryptoKit
import Foundation

struct DatasetBenchmarkCorpus {
    var datasetID: String
    var revision: String
    var config: String
    var split: String
    var sha256: String
    var textField: String
    var texts: [String]

    static func fields(in snapshot: DatasetSnapshot) throws -> [String] {
        let rows = try readRows(snapshot)
        return Set(rows.flatMap { $0.compactMap { $0.value is String ? $0.key : nil } }).sorted()
    }

    static func load(snapshot: DatasetSnapshot, field: String, limit: Int) throws -> Self {
        guard (1...1000).contains(limit), !field.isEmpty else {
            throw DatasetBenchmarkError.invalid("Choose a text field and between 1 and 1,000 rows.")
        }
        let rows = try readRows(snapshot)
        let selected = Array(rows.prefix(limit))
        guard !selected.isEmpty else { throw DatasetBenchmarkError.invalid("The snapshot has no rows.") }
        let texts = try selected.enumerated().map { index, row -> String in
            guard let text = row[field] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DatasetBenchmarkError.invalid("Row \(index + 1) has no nonempty string in \(field). Choose another field or snapshot.")
            }
            guard text.utf8.count <= 32_768 else {
                throw DatasetBenchmarkError.invalid("Row \(index + 1) exceeds the 32 KiB text limit. Text is never silently truncated.")
            }
            return text
        }
        guard texts.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1024 * 1024 else {
            throw DatasetBenchmarkError.invalid("Selected text exceeds 8 MiB. Choose fewer rows.")
        }
        let manifest = snapshot.manifest
        return Self(datasetID: manifest.datasetID, revision: manifest.revision, config: manifest.config, split: manifest.split, sha256: manifest.sha256, textField: field, texts: texts)
    }

    private static func readRows(_ snapshot: DatasetSnapshot) throws -> [[String: Any]] {
        let checked = try DatasetSnapshot.load(from: snapshot.directory)
        guard checked.manifest == snapshot.manifest else {
            throw DatasetBenchmarkError.invalid("The snapshot changed after selection. Import it again.")
        }
        let data = try DatasetSnapshot.readBounded(checked.rowsURL, limit: DatasetSnapshot.maximumBytes)
        guard DatasetSnapshot.digest(data) == checked.manifest.sha256 else {
            throw DatasetBenchmarkError.invalid("The snapshot changed while reading. Import it again.")
        }
        return try data.split(separator: 10).map { line in
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw DatasetBenchmarkError.invalid("Dataset rows must be JSON objects.")
            }
            return row
        }
    }

    func point(index: Int, vector: [Float], backend: String, model: String) -> ChunkPoint {
        let hex = SHA256.hash(data: Data("\(sha256)|\(textField)|\(index)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let bytes = Array(hex)
        let id = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(bytes[$0]) }.joined(separator: "-")
        return ChunkPoint(id: id, vector: vector, text: texts[index], source: "hf://\(datasetID)/\(config)/\(split)@\(revision)", metadata: [
            "record_type": "chunk", "chunky_test_data": "true", "dataset_id": datasetID,
            "dataset_revision": revision, "dataset_config": config, "dataset_split": split,
            "dataset_sha256": sha256, "dataset_row": String(index), "dataset_text_field": textField,
            "embedding_model": model, "embedding_backend": backend, "embedding_dim": String(vector.count),
        ])
    }
}

struct DatasetBenchmarkReport: Codable, Equatable {
    var schemaVersion = 1
    var createdAt: Date
    var datasetID: String
    var revision: String
    var config: String
    var split: String
    var sha256: String
    var textField: String
    var rows: Int
    var backend: String
    var model: String
    var dimensions: Int
    var warmupSeconds: Double
    var embeddingSeconds: Double
    var indexingSeconds: Double?
    var collection: String?
    var rowsPerSecond: Double { embeddingSeconds > 0 ? Double(rows) / embeddingSeconds : 0 }
}

enum DatasetBenchmarkError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum DatasetBenchmarkSafety {
    static func collectionName() -> String { "chunky-dataset-test-" + UUID().uuidString.lowercased() }

    static func validateCollection(_ name: String, production: String) throws {
        let prefix = "chunky-dataset-test-"
        guard name != production, name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else {
            throw DatasetBenchmarkError.invalid("Only a new, uniquely named dataset test collection is allowed.")
        }
    }

    static func validateVectors(_ vectors: [[Float]], count: Int, dimensions: Int? = nil) throws -> Int {
        guard vectors.count == count, let size = vectors.first?.count, (1...16384).contains(size),
              dimensions == nil || dimensions == size,
              vectors.allSatisfy({ $0.count == size && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }) else {
            throw DatasetBenchmarkError.invalid("Embedding count, dimensions or finite nonzero vector validation failed. No collection will be reconfigured.")
        }
        return size
    }
}
