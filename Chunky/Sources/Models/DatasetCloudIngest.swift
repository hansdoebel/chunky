import CryptoKit
import Foundation

nonisolated struct DatasetCloudSource: Sendable {
    var datasetID: String
    var revision: String
    var config: String
    var split: String
    var sha256: String
    var rows: Int
    var visit: @Sendable (@escaping @Sendable (Int, Data) async throws -> Void) async throws -> Void
}

nonisolated enum DatasetCloudTier: String, CaseIterable, Identifiable, Sendable {
    case free = "Free"
    case standard = "Standard / Premium"
    var id: String { rawValue }
}

nonisolated struct DatasetCloudBudget: Equatable, Sendable {
    var tier: DatasetCloudTier
    var ram: Double
    var disk: Double

    func validate() throws {
        guard ram.isFinite, disk.isFinite, ram > 0, disk > 0 else {
            throw DatasetBenchmarkError.invalid("Enter positive available RAM and disk bytes from the least-free Cloud node.")
        }
        if tier == .free && (ram > 1_000_000_000 || disk > 4_000_000_000) {
            throw DatasetBenchmarkError.invalid("Free Cloud has at most 1 GB RAM and 4 GB disk. Enter available capacity, after existing usage.")
        }
    }

    func require(_ estimate: DatasetCloudEstimate) throws {
        try validate()
        guard estimate.ram <= ram, estimate.disk <= disk else {
            throw DatasetBenchmarkError.invalid("The import estimate exceeds the available per-node budget. Choose a smaller sample or adjust capacity in Qdrant Cloud.")
        }
    }
}

nonisolated struct DatasetCloudEstimate: Equatable, Codable, Sendable {
    var points: Int
    var payloadBytes: Int
    var dimensions: Int
    var vectorBytes: Double { Double(points) * Double(dimensions) * 4 }
    var payloadStorageBytes: Double { Double(payloadBytes) * 1.5 }
    var graphAndIDs: Double { Double(points) * (16 * 2 * 4 + 52) }
    var persistentDisk: Double { vectorBytes + payloadStorageBytes + graphAndIDs }
    var ram: Double { (vectorBytes + payloadStorageBytes * 3 + graphAndIDs) * 1.2 + 64 * 1024 * 1024 }
    var disk: Double { persistentDisk * 2 + 64 * 1024 * 1024 }
    var vectorCap: Int { Int(ceil(vectorBytes * 1.2)) }
    var payloadCap: Int { Int(ceil(payloadStorageBytes * 1.2)) }
}

nonisolated struct DatasetCloudChunk: Sendable {
    var row: Int
    var offset: Int
    var text: String

    static func split(row: Int, data: Data, field: String, maximumBytes: Int) throws -> [Self] {
        guard (512...8192).contains(maximumBytes),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object[field] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatasetBenchmarkError.invalid("Row \(row + 1) must contain nonempty text in the selected field. No rows are skipped.")
        }
        let bytes = Array(text.utf8)
        var result: [Self] = []
        var start = 0
        while start < bytes.count {
            try Task.checkCancellation()
            var end = min(start + maximumBytes, bytes.count)
            while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
            guard end > start, let value = String(bytes: bytes[start..<end], encoding: .utf8) else {
                throw DatasetBenchmarkError.invalid("Cannot split the dataset text at a UTF-8 boundary.")
            }
            result.append(Self(row: row, offset: start, text: value))
            start = end
        }
        return result
    }

    func payload(source: DatasetCloudSource, field: String, backend: String, model: String, dimensions: Int) -> [String: String] {
        ["text": text, "source": "hf://\(source.datasetID)/\(source.config)/\(source.split)@\(source.revision)",
         "record_type": "chunk", "chunky_test_data": "true", "dataset_id": source.datasetID,
         "dataset_revision": source.revision, "dataset_sha256": source.sha256,
         "dataset_config": source.config, "dataset_split": source.split,
         "dataset_row": String(row), "dataset_text_field": field,
         "dataset_byte_offset": String(offset), "dataset_byte_length": String(text.utf8.count),
         "dataset_chunking": "utf8-fixed-bytes-v1", "embedding_backend": backend,
         "embedding_model": model, "embedding_dim": String(dimensions)]
    }

    func id(source: DatasetCloudSource, field: String, maximumBytes: Int) -> String {
        let input = "\(source.sha256)|\(field)|\(maximumBytes)|\(row)|\(offset)"
        let hex = SHA256.hash(data: Data(input.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }

    func budgetedPayloadBytes(source: DatasetCloudSource, field: String, backend: String, model: String) throws -> Int {
        let bytes = try JSONSerialization.data(withJSONObject: payload(source: source, field: field, backend: backend, model: model, dimensions: 16384)).count
        return ((bytes + 255) / 128) * 128
    }
}

nonisolated struct DatasetCloudPlan: Sendable {
    var source: DatasetCloudSource
    var field: String
    var chunkBytes: Int
    var backend: String
    var model: String
    var estimate: DatasetCloudEstimate
    var budget: DatasetCloudBudget
}

nonisolated struct DatasetCloudResult: Codable, Sendable {
    var datasetID: String
    var revision: String
    var sha256: String
    var collection: String
    var plannedPoints: Int
    var acknowledgedPoints: Int = 0
    var creationAttempted = false
    var completed = false
    var message = ""
}

actor DatasetCloudPlanner {
    var points = 0
    var payloadBytes = 0
    var firstText = ""

    func add(row: Int, data: Data, source: DatasetCloudSource, field: String, chunkBytes: Int, backend: String, model: String) throws {
        for chunk in try DatasetCloudChunk.split(row: row, data: data, field: field, maximumBytes: chunkBytes) {
            if firstText.isEmpty { firstText = chunk.text }
            points += 1
            guard points <= 2_000_000 else { throw DatasetBenchmarkError.invalid("This import exceeds two million chunks. Choose a smaller sample or larger chunks.") }
            payloadBytes += try chunk.budgetedPayloadBytes(source: source, field: field, backend: backend, model: model)
        }
    }

    func summary() -> (Int, Int, String) { (points, payloadBytes, firstText) }
}
