import CryptoKit
import CoreFoundation
import Foundation

nonisolated struct DatasetHTTPResponse: Sendable {
    var data: Data
    var revision: String?
}

nonisolated protocol DatasetHTTP: Sendable {
    func get(_ url: URL, maximumBytes: Int) async throws -> DatasetHTTPResponse
}

nonisolated private final class DatasetRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}

nonisolated final class URLSessionDatasetHTTP: DatasetHTTP {
    private let session = URLSession(configuration: .ephemeral, delegate: DatasetRedirectPolicy(), delegateQueue: nil)

    @concurrent func get(_ url: URL, maximumBytes: Int) async throws -> DatasetHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DatasetError.unavailable }
        guard response.expectedContentLength <= maximumBytes else { throw DatasetError.responseLimit }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 16 * 1024) {
                try Task.checkCancellation()
                await Task.yield()
            }
            guard data.count < maximumBytes else { throw DatasetError.responseLimit }
            data.append(byte)
        }
        return DatasetHTTPResponse(data: data, revision: http.value(forHTTPHeaderField: "X-Revision"))
    }
}

nonisolated struct HuggingFaceDatasetService: Sendable {
    var http: any DatasetHTTP = URLSessionDatasetHTTP()
    var availableCapacity: @Sendable (URL) throws -> Int64? = { url in
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
    static let pageBytes = 5 * 1024 * 1024

    @concurrent func search(_ query: String) async throws -> [HuggingFaceDataset] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200 else { return [] }
        let response = try await http.get(Self.url(host: "huggingface.co", path: "/api/datasets", query: ["search": query, "limit": "30", "full": "true"]), maximumBytes: Self.pageBytes)
        guard response.data.count <= Self.pageBytes, let list = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { throw DatasetError.invalidResponse }
        guard list.count <= 30 else { throw DatasetError.invalidResponse }
        let datasets = list.compactMap { Self.dataset($0) }
        guard Set(datasets.map(\.id)).count == datasets.count else { throw DatasetError.invalidResponse }
        return datasets
    }

    @concurrent func details(_ id: String) async throws -> HuggingFaceDataset {
        guard DatasetSnapshot.validDatasetID(id) else { throw DatasetError.invalidDataset }
        let response = try await http.get(Self.url(host: "huggingface.co", path: "/api/datasets/" + id), maximumBytes: Self.pageBytes)
        guard response.data.count <= Self.pageBytes, let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], let dataset = Self.dataset(object), dataset.id == id, !dataset.restricted else { throw DatasetError.unavailable }
        return dataset
    }

    @concurrent func splits(for dataset: HuggingFaceDataset) async throws -> [DatasetSplit] {
        let object = try await viewer(path: "/splits", dataset: dataset, query: [:])
        guard let list = object["splits"] as? [[String: Any]], list.count <= 1000 else { throw DatasetError.invalidResponse }
        let splits = list.compactMap { row -> DatasetSplit? in
            guard let config = row["config"] as? String, let split = row["split"] as? String, !config.isEmpty, !split.isEmpty else { return nil }
            return DatasetSplit(config: config, split: split)
        }
        guard splits.count == list.count, Set(splits.map(\.id)).count == splits.count else { throw DatasetError.invalidResponse }
        return splits
    }

    @concurrent func size(for dataset: HuggingFaceDataset, split: DatasetSplit) async throws -> DatasetSizeInfo {
        let object = try await viewer(path: "/size", dataset: dataset, query: ["config": split.config])
        guard object["partial"] as? Bool == false,
              let size = object["size"] as? [String: Any],
              let splits = size["splits"] as? [[String: Any]] else { throw DatasetError.invalidResponse }
        let matching = splits.filter { $0["dataset"] as? String == dataset.id && $0["config"] as? String == split.config && $0["split"] as? String == split.split }
        guard matching.count == 1, let row = matching.first,
              let rows = Self.nonnegativeInteger(row["num_rows"]),
              let bytes = Self.nonnegativeInteger(row["num_bytes_parquet_files"]) else { throw DatasetError.invalidResponse }
        return DatasetSizeInfo(sourceRows: rows, parquetBytes: bytes)
    }

    @concurrent func estimate(for dataset: HuggingFaceDataset, split: DatasetSplit) async throws -> DatasetSampleEstimate {
        let object = try await viewer(path: "/rows", dataset: dataset, query: ["config": split.config, "split": split.split, "offset": "0", "length": "20"])
        try Task.checkCancellation()
        guard let total = Self.nonnegativeInteger(object["num_rows_total"]), total > 0,
              let rows = object["rows"] as? [[String: Any]], rows.count == min(total, 20) else { throw DatasetError.invalidResponse }
        var bytes = 0
        for (index, row) in rows.enumerated() {
            guard Self.nonnegativeInteger(row["row_idx"]) == index,
                  let value = row["row"] as? [String: Any],
                  let truncated = row["truncated_cells"] as? [Any], truncated.isEmpty else { throw DatasetError.invalidResponse }
            bytes += try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]).count + 1
        }
        return DatasetSampleEstimate(previewRows: rows.count, previewBytes: bytes, totalRows: total)
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0 else { return nil }
        return integer
    }

    @concurrent func downloadStream(dataset: HuggingFaceDataset, split: DatasetSplit, byteBudget: Int, maximumRows: Int = DatasetStreamSnapshot.maximumRows, folder: URL, progress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> DatasetStreamDownload {
        guard byteBudget > 0, byteBudget <= DatasetStreamSnapshot.maximumBytes,
              maximumRows > 0, maximumRows <= DatasetStreamSnapshot.maximumRows,
              folder.isFileURL, !split.config.isEmpty, !split.split.isEmpty else { throw DatasetError.streamLimit }
        try Task.checkCancellation()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capacity = try availableCapacity(folder)
        guard let capacity, capacity >= Int64(byteBudget) + 64 * 1024 * 1024 else { throw DatasetError.insufficientSpace }
        let token = UUID().uuidString
        let stage = folder.appendingPathComponent(".chunky-dataset-" + token, isDirectory: true)
        let destination = folder.appendingPathComponent(dataset.id.replacingOccurrences(of: "/", with: "--") + "-" + String(dataset.revision.prefix(8)) + "-" + token, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let rowsURL = stage.appendingPathComponent("rows.jsonl")
        try Data().write(to: rowsURL, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: rowsURL)
        defer { try? file.close() }
        var hash = SHA256()
        var count = 0
        var savedBytes = 0
        var total: Int?
        var stop = DatasetStreamStop.rowLimit
        var pageRows = 100
        downloadLoop: while count < min(maximumRows, total ?? maximumRows) {
            try Task.checkCancellation()
            var length = min(pageRows, maximumRows - count)
            let object: [String: Any]
            while true {
                do {
                    object = try await viewer(path: "/rows", dataset: dataset, query: ["config": split.config, "split": split.split, "offset": String(count), "length": String(length)])
                    break
                } catch let error as DatasetError where error == .responseLimit || error == .limitExceeded {
                    guard length > 1 else { throw DatasetError.responseLimit }
                    length = max(1, length / 2)
                    pageRows = length
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            guard let available = Self.nonnegativeInteger(object["num_rows_total"]),
                  let rows = object["rows"] as? [[String: Any]], total == nil || total == available,
                  rows.count == min(length, max(0, available - count)) else { throw DatasetError.invalidResponse }
            total = available
            for row in rows {
                try Task.checkCancellation()
                guard Self.nonnegativeInteger(row["row_idx"]) == count, let value = row["row"] as? [String: Any],
                      let truncated = row["truncated_cells"] as? [Any], truncated.isEmpty else { throw DatasetError.invalidResponse }
                var line = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                guard line.count <= DatasetStreamSnapshot.maximumLineBytes else { throw DatasetError.streamRowLimit }
                line.append(10)
                if savedBytes + line.count > byteBudget {
                    guard count > 0 else { throw DatasetError.sampleBudgetTooSmall }
                    stop = .byteBudget
                    break downloadLoop
                }
                try file.write(contentsOf: line)
                hash.update(data: line)
                savedBytes += line.count
                count += 1
            }
            await progress(count, savedBytes)
        }
        try Task.checkCancellation()
        guard count > 0, let total else { throw DatasetError.invalidResponse }
        if count == total { stop = .sourceExhausted }
        let manifest = DatasetStreamManifest(schemaVersion: 2, datasetID: dataset.id, revision: dataset.revision, config: split.config, split: split.split, sourceURL: dataset.cardURL.absoluteString, license: dataset.license, downloadedAt: Date(), rowCount: count, totalRows: total, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), requestedByteBudget: byteBudget, maximumRows: maximumRows, stopReason: stop)
        try manifest.validate()
        try file.synchronize()
        try file.close()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
        return DatasetStreamDownload(manifest: manifest, directory: destination, byteCount: savedBytes)
    }

    @concurrent func download(dataset: HuggingFaceDataset, split: DatasetSplit, rows requested: Int, folder: URL, progress: @MainActor @Sendable (Int) -> Void = { _ in }) async throws -> DatasetSnapshot {
        guard (1...DatasetSnapshot.maximumRows).contains(requested) else { throw DatasetError.limitExceeded }
        guard folder.isFileURL, !split.config.isEmpty, !split.split.isEmpty else { throw DatasetError.invalidDataset }
        var data = Data()
        var count = 0
        var total: Int?
        while count < min(requested, total ?? requested) {
            try Task.checkCancellation()
            let length = min(100, requested - count)
            let object = try await viewer(path: "/rows", dataset: dataset, query: ["config": split.config, "split": split.split, "offset": String(count), "length": String(length)])
            try Task.checkCancellation()
            guard let available = object["num_rows_total"] as? Int, available >= 0,
                  let rows = object["rows"] as? [[String: Any]], rows.count <= length,
                  total == nil || total == available, !rows.isEmpty || available == 0 else { throw DatasetError.invalidResponse }
            total = available
            guard rows.count == min(length, max(0, available - count)) else { throw DatasetError.invalidResponse }
            for row in rows {
                guard row["row_idx"] as? Int == count, let value = row["row"] as? [String: Any],
                      let truncated = row["truncated_cells"] as? [Any], truncated.isEmpty else { throw DatasetError.invalidResponse }
                let line = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                guard data.count + line.count + 1 <= DatasetSnapshot.maximumBytes else { throw DatasetError.limitExceeded }
                data.append(line)
                data.append(10)
                count += 1
            }
            await progress(count)
        }
        try Task.checkCancellation()
        guard count > 0 else { throw DatasetError.invalidResponse }
        let manifest = DatasetManifest(schemaVersion: 1, datasetID: dataset.id, revision: dataset.revision, config: split.config, split: split.split, sourceURL: dataset.cardURL.absoluteString, license: dataset.license, downloadedAt: Date(), rowCount: count, requestedRows: requested, totalRows: total ?? count, sha256: DatasetSnapshot.digest(data))
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let stage = folder.appendingPathComponent(".chunky-dataset-" + token, isDirectory: true)
        let destination = folder.appendingPathComponent(dataset.id.replacingOccurrences(of: "/", with: "--") + "-" + String(dataset.revision.prefix(8)) + "-" + token, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        try data.write(to: stage.appendingPathComponent("rows.jsonl"), options: .withoutOverwriting)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
        return DatasetSnapshot(manifest: manifest, directory: destination)
    }

    private func viewer(path: String, dataset: HuggingFaceDataset, query: [String: String]) async throws -> [String: Any] {
        guard DatasetSnapshot.validDatasetID(dataset.id), DatasetSnapshot.validRevision(dataset.revision), !dataset.restricted else { throw DatasetError.invalidDataset }
        var parameters = query
        parameters["dataset"] = dataset.id
        let response = try await http.get(Self.url(host: "datasets-server.huggingface.co", path: path, query: parameters), maximumBytes: Self.pageBytes)
        guard response.revision == dataset.revision else { throw DatasetError.revisionChanged }
        guard response.data.count <= Self.pageBytes, let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw DatasetError.invalidResponse }
        return object
    }

    private static func dataset(_ object: [String: Any]) -> HuggingFaceDataset? {
        guard let id = object["id"] as? String, DatasetSnapshot.validDatasetID(id), let revision = object["sha"] as? String, DatasetSnapshot.validRevision(revision) else { return nil }
        let licenses = (object["tags"] as? [String] ?? []).filter { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }
        let gated = object["gated"]
        return HuggingFaceDataset(id: id, revision: revision, downloads: object["downloads"] as? Int ?? 0, license: licenses.isEmpty ? nil : licenses.joined(separator: ", "), restricted: object["private"] as? Bool == true || object["disabled"] as? Bool == true || gated as? Bool == true || gated as? String != nil)
    }

    private static func url(host: String, path: String, query: [String: String] = [:]) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
}
