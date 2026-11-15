import Foundation

struct SnapshotRecord: Equatable, Sendable, Identifiable {
    var name: String
    var creationTime: String
    var size: Int

    var id: String { name }
}

struct SnapshotCall: Equatable, Sendable {
    var method: String
    var path: String
    var query: String
}

protocol SnapshotTransport: Sendable {
    func send(method: String, url: URL, apiKey: String, body: Data?) async throws -> (status: Int, body: Data)
    func download(url: URL, apiKey: String, to destination: URL) async throws
    func upload(url: URL, apiKey: String, file: URL) async throws -> (status: Int, body: Data)
}

enum CollectionSnapshots {
    static func restBase(qdrantURL: String) -> URL? {
        guard var components = URLComponents(string: qdrantURL), components.host != nil else { return nil }
        if components.port == 6334 {
            components.port = 6333
        }
        return components.url
    }

    static func endpoint(settings: AppSettings) -> (url: String, apiKey: String) {
        (settings.qdrantURL, settings.qdrantAPIKey)
    }

    static func confirmOverwrite(collection: String, server: String) -> String {
        "Replace \(collection) on \(server) with this snapshot? Existing points in that collection are overwritten."
    }
}

struct CollectionSnapshotClient: Sendable {
    var transport: any SnapshotTransport

    func list(baseURL: String, apiKey: String, collection: String) async throws -> [SnapshotRecord] {
        let url = try Self.url(baseURL: baseURL, collection: collection, snapshot: nil, query: "")
        let response = try await transport.send(method: "GET", url: url, apiKey: apiKey, body: nil)
        guard (200..<300).contains(response.status) else {
            throw SnapshotClientError.http(response.status, String(data: response.body, encoding: .utf8) ?? "")
        }
        return try Self.records(from: response.body)
    }

    func create(baseURL: String, apiKey: String, collection: String) async throws -> SnapshotRecord {
        let url = try Self.url(baseURL: baseURL, collection: collection, snapshot: nil, query: "wait=true")
        let response = try await transport.send(method: "POST", url: url, apiKey: apiKey, body: Data("{}".utf8))
        guard (200..<300).contains(response.status) else {
            throw SnapshotClientError.http(response.status, String(data: response.body, encoding: .utf8) ?? "")
        }
        let records = try Self.records(from: response.body)
        guard let record = records.first else { throw SnapshotClientError.empty }
        return record
    }

    func download(baseURL: String, apiKey: String, collection: String, snapshot: String, to destination: URL) async throws {
        let url = try Self.url(baseURL: baseURL, collection: collection, snapshot: snapshot, query: "")
        try await transport.download(url: url, apiKey: apiKey, to: destination)
    }

    func restore(baseURL: String, apiKey: String, collection: String, file: URL) async throws {
        let url = try Self.url(baseURL: baseURL, collection: collection, snapshot: nil, query: "priority=snapshot", upload: true)
        let response = try await transport.upload(url: url, apiKey: apiKey, file: file)
        guard (200..<300).contains(response.status) else {
            throw SnapshotClientError.http(response.status, String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    static func url(baseURL: String, collection: String, snapshot: String?, query: String, upload: Bool = false) throws -> URL {
        guard let base = CollectionSnapshots.restBase(qdrantURL: baseURL) else {
            throw SnapshotClientError.invalidURL(baseURL)
        }
        var url = base
        url.appendPathComponent("collections")
        url.appendPathComponent(collection)
        url.appendPathComponent("snapshots")
        if upload {
            url.appendPathComponent("upload")
        } else if let snapshot, !snapshot.isEmpty {
            url.appendPathComponent(snapshot)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SnapshotClientError.invalidURL(baseURL)
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query
        }
        guard let built = components.url else { throw SnapshotClientError.invalidURL(baseURL) }
        return built
    }

    static func records(from data: Data) throws -> [SnapshotRecord] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let one = object?["result"] as? [String: Any], let name = one["name"] as? String {
            return [record(one, name: name)]
        }
        let rows = object?["result"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return record(row, name: name)
        }
    }

    private static func record(_ row: [String: Any], name: String) -> SnapshotRecord {
        let created = row["creation_time"] as? String ?? ""
        let size = (row["size"] as? NSNumber)?.intValue ?? (row["size"] as? Int) ?? 0
        return SnapshotRecord(name: name, creationTime: created, size: size)
    }
}

enum SnapshotClientError: LocalizedError, Equatable {
    case invalidURL(String)
    case empty
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Snapshot URL is not valid: \(url)"
        case .empty:
            return "Qdrant did not return a snapshot."
        case .http(let status, let detail):
            return "Snapshot request failed with HTTP \(status). \(detail)"
        }
    }
}

struct LiveSnapshotTransport: SnapshotTransport {
    func send(method: String, url: URL, apiKey: String, body: Data?) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.upload(for: request, from: body ?? Data())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    func download(url: URL, apiKey: String, to destination: URL) async throws {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        let (temporary, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SnapshotClientError.http(status, "Snapshot download failed.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func upload(url: URL, apiKey: String, file: URL) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        let boundary = "chunky-snapshot"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let temporary = try streamingUpload(file: file, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: temporary)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    private func streamingUpload(file: URL, boundary: String) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let header = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"snapshot\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            let footer = Data("\r\n--\(boundary)--\r\n".utf8)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let output = try FileHandle(forWritingTo: temporary)
            try output.write(contentsOf: header)
            let input = try FileHandle(forReadingFrom: file)
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: footer)
            try input.close()
            try output.close()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
