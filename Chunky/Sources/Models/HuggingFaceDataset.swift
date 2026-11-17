import CryptoKit
import Foundation

nonisolated struct HuggingFaceDataset: Identifiable, Equatable, Sendable {
    var id: String
    var revision: String
    var downloads: Int
    var license: String?
    var restricted: Bool

    var cardURL: URL { URL(string: "https://huggingface.co/datasets/\(id)")! }
}

nonisolated struct DatasetSplit: Identifiable, Equatable, Sendable {
    var config: String
    var split: String
    var id: String { config + "/" + split }
}

nonisolated struct DatasetRecommendation: Identifiable, Sendable {
    let title: String
    let config: String
    var id: String { config }
    var datasetID: String { "wikimedia/wikipedia" }
    var split: DatasetSplit { DatasetSplit(config: config, split: "train") }

    static let wikipedia = [
        Self(title: "English Wikipedia", config: "20231101.en"),
        Self(title: "German Wikipedia", config: "20231101.de")
    ]
}

nonisolated enum DatasetSampleSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large, custom
    var id: String { rawValue }
    var rows: Int? {
        switch self {
        case .small: return 100
        case .medium: return 1_000
        case .large: return 10_000
        case .custom: return nil
        }
    }
    var title: String {
        switch self {
        case .small: return "Small · 100 rows"
        case .medium: return "Medium · 1,000 rows"
        case .large: return "Large · 10,000 rows"
        case .custom: return "Custom"
        }
    }
}

nonisolated struct DatasetSizeInfo: Equatable, Sendable {
    let sourceRows: Int
    let parquetBytes: Int
}

nonisolated struct DatasetSampleEstimate: Equatable, Sendable {
    let previewRows: Int
    let previewBytes: Int
    let totalRows: Int

    func bytes(for rows: Int) -> Int? {
        guard rows > 0, rows <= DatasetSnapshot.maximumRows, previewRows > 0,
              previewBytes >= 0, totalRows >= previewRows else { return nil }
        let product = previewBytes.multipliedReportingOverflow(by: min(rows, totalRows))
        guard !product.overflow else { return nil }
        return product.partialValue / previewRows + (product.partialValue % previewRows == 0 ? 0 : 1)
    }
}

nonisolated struct DatasetManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var datasetID: String
    var revision: String
    var config: String
    var split: String
    var sourceURL: String
    var license: String?
    var downloadedAt: Date
    var rowCount: Int
    var requestedRows: Int
    var totalRows: Int
    var sha256: String
}

nonisolated struct DatasetSnapshot: Sendable {
    var manifest: DatasetManifest
    var directory: URL
    var rowsURL: URL { directory.appendingPathComponent("rows.jsonl") }

    static let maximumBytes = 50 * 1024 * 1024
    static let maximumRows = 10_000

    static func load(from directory: URL) throws -> Self {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let rowsURL = directory.appendingPathComponent("rows.jsonl")
        for (url, limit) in [(manifestURL, 64 * 1024), (rowsURL, maximumBytes)] {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else {
                throw DatasetError.invalidSnapshot
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifestData = try readBounded(manifestURL, limit: 64 * 1024)
        let version = (try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])?["schemaVersion"] as? Int
        let manifest: DatasetManifest
        var byteBudget = maximumBytes
        if version == 2 {
            let streaming = try decoder.decode(DatasetStreamManifest.self, from: manifestData)
            try streaming.validate()
            manifest = streaming.legacyManifest
            byteBudget = min(maximumBytes, streaming.requestedByteBudget)
        } else {
            manifest = try decoder.decode(DatasetManifest.self, from: manifestData)
        }
        let data = try readBounded(rowsURL, limit: maximumBytes)
        guard (1...2).contains(manifest.schemaVersion), validDatasetID(manifest.datasetID), validRevision(manifest.revision),
              manifest.rowCount > 0, manifest.rowCount <= maximumRows,
              manifest.requestedRows >= manifest.rowCount, manifest.requestedRows <= maximumRows,
              manifest.totalRows >= manifest.rowCount, !manifest.config.isEmpty, !manifest.split.isEmpty,
              manifest.sourceURL == "https://huggingface.co/datasets/" + manifest.datasetID,
              manifest.sha256 == digest(data), data.count <= byteBudget else { throw DatasetError.invalidSnapshot }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true, lines.count - 1 == manifest.rowCount else { throw DatasetError.invalidSnapshot }
        for line in lines.dropLast() {
            try Task.checkCancellation()
            guard (try JSONSerialization.jsonObject(with: Data(line))) is [String: Any] else { throw DatasetError.invalidSnapshot }
        }
        return Self(manifest: manifest, directory: directory)
    }

    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DatasetError.limitExceeded }
        return data
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func validDatasetID(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
        }
    }

    static func validRevision(_ value: String) -> Bool { value.count == 40 && value.allSatisfy(\.isHexDigit) }
}

nonisolated enum DatasetError: LocalizedError {
    case invalidDataset, unavailable, revisionChanged, invalidResponse, limitExceeded, invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .invalidDataset: return "Choose a public dataset with a valid immutable revision."
        case .unavailable: return "This public dataset is unavailable in the Hugging Face Dataset Viewer. Private or gated datasets are not supported."
        case .revisionChanged: return "Dataset revision changed or could not be verified. Search again before downloading; no snapshot was saved."
        case .invalidResponse: return "The dataset server returned an incomplete or invalid response. No snapshot was saved."
        case .limitExceeded: return "Snapshot exceeds the limit of 10,000 rows or 50 MiB. Choose fewer rows."
        case .invalidSnapshot: return "This is not a valid, complete Chunky dataset snapshot."
        }
    }
}

struct DatasetFolderStore {
    var defaults: UserDefaults = .standard
    private let key = "chunky.datasets.folderBookmark"

    var defaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Chunky Datasets", isDirectory: true)
    }

    func folder() throws -> URL {
        guard let data = defaults.data(forKey: key) else { return defaultFolder }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { try setFolder(url) }
        return url
    }

    func setFolder(_ url: URL) throws {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadInvalidFileName) }
        defaults.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key)
    }

    func reset() { defaults.removeObject(forKey: key) }
}
