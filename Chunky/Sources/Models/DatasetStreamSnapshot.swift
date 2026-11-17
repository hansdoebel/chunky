import CryptoKit
import Foundation

nonisolated enum DatasetStreamStop: String, Codable, Sendable {
    case byteBudget, rowLimit, sourceExhausted, legacyRowLimit
}

nonisolated struct DatasetStreamManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var datasetID: String
    var revision: String
    var config: String
    var split: String
    var sourceURL: String
    var license: String?
    var downloadedAt: Date
    var rowCount: Int
    var totalRows: Int
    var sha256: String
    var requestedByteBudget: Int
    var maximumRows: Int
    var stopReason: DatasetStreamStop

    func validate() throws {
        guard schemaVersion == 2, DatasetSnapshot.validDatasetID(datasetID), DatasetSnapshot.validRevision(revision),
              sourceURL == "https://huggingface.co/datasets/" + datasetID,
              !config.isEmpty, !split.isEmpty, rowCount > 0, rowCount <= maximumRows,
              maximumRows <= DatasetStreamSnapshot.maximumRows, totalRows >= rowCount,
              requestedByteBudget > 0, requestedByteBudget <= DatasetStreamSnapshot.maximumBytes,
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              stopReason != .sourceExhausted || rowCount == totalRows,
              stopReason != .rowLimit || rowCount == maximumRows else { throw DatasetError.invalidSnapshot }
    }

    var legacyManifest: DatasetManifest {
        DatasetManifest(schemaVersion: 2, datasetID: datasetID, revision: revision, config: config, split: split, sourceURL: sourceURL, license: license, downloadedAt: downloadedAt, rowCount: rowCount, requestedRows: rowCount, totalRows: totalRows, sha256: sha256)
    }
}

nonisolated enum DatasetStreamSnapshot {
    static let maximumBytes = 1024 * 1024 * 1024
    static let maximumRows = 1_000_000
    static let maximumLineBytes = 5 * 1024 * 1024
    static let blockBytes = 64 * 1024

    @concurrent static func validate(from directory: URL) async throws -> DatasetValidatedSnapshot {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try regularFile(manifestURL, maximum: 64 * 1024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try DatasetSnapshot.readBounded(manifestURL, limit: 64 * 1024)
        let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
        let manifest: DatasetStreamManifest
        if version == 1 {
            let legacy = try decoder.decode(DatasetManifest.self, from: data)
            guard legacy.requestedRows >= legacy.rowCount, legacy.requestedRows <= DatasetSnapshot.maximumRows else { throw DatasetError.invalidSnapshot }
            manifest = DatasetStreamManifest(schemaVersion: 2, datasetID: legacy.datasetID, revision: legacy.revision, config: legacy.config, split: legacy.split, sourceURL: legacy.sourceURL, license: legacy.license, downloadedAt: legacy.downloadedAt, rowCount: legacy.rowCount, totalRows: legacy.totalRows, sha256: legacy.sha256, requestedByteBudget: DatasetSnapshot.maximumBytes, maximumRows: DatasetSnapshot.maximumRows, stopReason: .legacyRowLimit)
        } else {
            manifest = try decoder.decode(DatasetStreamManifest.self, from: data)
        }
        try manifest.validate()
        let rowsURL = directory.appendingPathComponent("rows.jsonl")
        try regularFile(rowsURL, maximum: manifest.requestedByteBudget)
        let file = try FileHandle(forReadingFrom: rowsURL)
        defer { try? file.close() }
        var hash = SHA256()
        var blocks: [Data] = []
        var parser = DatasetLineParser()
        var count = 0
        var bytes = 0
        while let block = try readBlock(file), !block.isEmpty {
            try Task.checkCancellation()
            bytes += block.count
            guard bytes <= manifest.requestedByteBudget else { throw DatasetError.invalidSnapshot }
            hash.update(data: block)
            blocks.append(Data(SHA256.hash(data: block)))
            for row in try parser.consume(block) {
                guard (try JSONSerialization.jsonObject(with: row)) is [String: Any] else { throw DatasetError.invalidSnapshot }
                count += 1
                guard count <= manifest.rowCount else { throw DatasetError.invalidSnapshot }
            }
        }
        guard parser.pending.isEmpty, count == manifest.rowCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw DatasetError.invalidSnapshot }
        return DatasetValidatedSnapshot(manifest: manifest, directory: directory, byteCount: bytes, blockDigests: blocks)
    }

    static func readBlock(_ file: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < blockBytes {
            guard let part = try file.read(upToCount: blockBytes - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        return data.isEmpty ? nil : data
    }

    static func regularFile(_ url: URL, maximum: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximum else { throw DatasetError.invalidSnapshot }
    }
}

nonisolated struct DatasetValidatedSnapshot: Sendable {
    let manifest: DatasetStreamManifest
    let directory: URL
    let byteCount: Int
    fileprivate let blockDigests: [Data]

    @concurrent func forEachRow(_ handler: @Sendable (Int, Data) async throws -> Void) async throws {
        let url = directory.appendingPathComponent("rows.jsonl")
        try DatasetStreamSnapshot.regularFile(url, maximum: byteCount)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var parser = DatasetLineParser()
        var index = 0
        var bytes = 0
        for digest in blockDigests {
            try Task.checkCancellation()
            guard let block = try DatasetStreamSnapshot.readBlock(file), !block.isEmpty,
                  Data(SHA256.hash(data: block)) == digest else { throw DatasetError.invalidSnapshot }
            bytes += block.count
            for row in try parser.consume(block) {
                try Task.checkCancellation()
                try await handler(index, row)
                index += 1
            }
        }
        guard bytes == byteCount, parser.pending.isEmpty, index == manifest.rowCount,
              (try file.read(upToCount: 1) ?? Data()).isEmpty else { throw DatasetError.invalidSnapshot }
    }
}

nonisolated private struct DatasetLineParser {
    var pending = Data()

    mutating func consume(_ block: Data) throws -> [Data] {
        var rows: [Data] = []
        let parts = block.split(separator: 10, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            guard pending.count + part.count <= DatasetStreamSnapshot.maximumLineBytes else { throw DatasetError.invalidSnapshot }
            pending.append(contentsOf: part)
            if index < parts.count - 1 {
                guard !pending.isEmpty else { throw DatasetError.invalidSnapshot }
                rows.append(pending)
                pending = Data()
            }
        }
        return rows
    }
}
