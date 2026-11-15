import CoreFoundation
import CryptoKit
import Foundation

enum ChunkCacheSchema {
    static let version = 1
}

struct ChunkCacheKey: Equatable, Sendable {
    var contentSHA256: String
    var doclingVersion: String
    var pipeline: String
    var tokenizer: String
    var maxTokens: Int
    var options: String = ""

    var canonical: String {
        [
            contentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            doclingVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            pipeline.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenizer.trimmingCharacters(in: .whitespacesAndNewlines),
            String(maxTokens),
            options.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "\n")
    }

    var id: String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ChunkCacheBox: Equatable, Sendable {
    var page: Int?
    var l: Double?
    var t: Double?
    var r: Double?
    var b: Double?
    var coordOrigin: String?
}

struct ChunkCacheChunk: Equatable, Sendable {
    var text: String
    var embeddingText: String
    var page: Int?
    var pageEnd: Int?
    var pages: [Int]
    var pageLabels: [String]
    var headings: [String]
    var bboxes: [ChunkCacheBox]
    var docTitle: String?
    var authors: [String]
    var year: Int?
    var doi: String?
    var source: String
    var url: String?
    var language: String?
    var contentType: String
    var chunkIndex: Int
    var tokenCount: Int
    var pictureDescription: String?
    var pictureClass: String?
    var tableMarkdown: String?

    static func normalize(_ raw: [String: Any]) -> ChunkCacheChunk {
        let pages = intList(raw["pages"])
        var page = intValue(raw["page"])
        var pageList = pages
        if page == nil {
            page = pageList.first
        }
        if let page, !pageList.contains(page) {
            pageList.insert(page, at: 0)
        }
        let pageEnd = intValue(raw["page_end"]) ?? pageList.last
        let boxes = (raw["bboxes"] as? [[String: Any]] ?? []).map { item in
            ChunkCacheBox(
                page: intValue(item["page"]),
                l: doubleValue(item["l"]),
                t: doubleValue(item["t"]),
                r: doubleValue(item["r"]),
                b: doubleValue(item["b"]),
                coordOrigin: text(item["coord_origin"])
            )
        }
        let rawText = string(raw["text"])
        return ChunkCacheChunk(
            text: rawText,
            embeddingText: string(raw["embedding_text"]).isEmpty ? rawText : string(raw["embedding_text"]),
            page: page,
            pageEnd: pageEnd,
            pages: pageList,
            pageLabels: strings(raw["page_labels"]),
            headings: strings(raw["headings"]),
            bboxes: boxes,
            docTitle: text(raw["doc_title"]),
            authors: strings(raw["authors"]),
            year: intValue(raw["year"]),
            doi: text(raw["doi"]),
            source: text(raw["source"]) ?? "",
            url: text(raw["url"]),
            language: text(raw["language"]),
            contentType: text(raw["content_type"]) ?? "text",
            chunkIndex: intValue(raw["chunk_index"]) ?? 0,
            tokenCount: intValue(raw["token_count"]) ?? 0,
            pictureDescription: text(raw["picture_description"]),
            pictureClass: text(raw["picture_class"]),
            tableMarkdown: text(raw["table_markdown"])
        )
    }

    func jsonObject() -> [String: Any] {
        [
            "text": text,
            "embedding_text": embeddingText,
            "page": page as Any? ?? NSNull(),
            "page_end": pageEnd as Any? ?? NSNull(),
            "pages": pages,
            "page_labels": pageLabels,
            "headings": headings,
            "bboxes": bboxes.map { box in
                [
                    "page": box.page as Any? ?? NSNull(),
                    "l": box.l as Any? ?? NSNull(),
                    "t": box.t as Any? ?? NSNull(),
                    "r": box.r as Any? ?? NSNull(),
                    "b": box.b as Any? ?? NSNull(),
                    "coord_origin": box.coordOrigin as Any? ?? NSNull(),
                ]
            },
            "doc_title": docTitle as Any? ?? NSNull(),
            "authors": authors,
            "year": year as Any? ?? NSNull(),
            "doi": doi as Any? ?? NSNull(),
            "source": source,
            "url": url as Any? ?? NSNull(),
            "language": language as Any? ?? NSNull(),
            "content_type": contentType,
            "chunk_index": chunkIndex,
            "token_count": tokenCount,
            "picture_description": pictureDescription as Any? ?? NSNull(),
            "picture_class": pictureClass as Any? ?? NSNull(),
            "table_markdown": tableMarkdown as Any? ?? NSNull(),
        ]
    }

    private static func string(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        return ""
    }

    private static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func strings(_ value: Any?) -> [String] {
        if let text = text(value) {
            return [text]
        }
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { text($0) }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        return nil
    }

    private static func intList(_ value: Any?) -> [Int] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { intValue($0) }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double {
            return number
        }
        if let number = value as? Int {
            return Double(number)
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return nil
    }
}

struct ChunkCacheManifestEntry {
    var id: String
    var contentSHA256: String
    var doclingVersion: String
    var pipeline: String
    var tokenizer: String
    var maxTokens: Int
    var bytes: Int
    var lastUsedAt: String
    var vectors: [[String: Any]]

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "content_sha256": contentSHA256,
            "docling_version": doclingVersion,
            "pipeline": pipeline,
            "tokenizer": tokenizer,
            "max_tokens": maxTokens,
            "bytes": bytes,
            "last_used_at": lastUsedAt,
            "vectors": vectors,
        ]
    }
}

struct ChunkCacheStats: Equatable {
    var entries: Int
    var bytes: Int
    var limitBytes: Int
}

enum ChunkCacheError: Error, Equatable {
    case invalidDocument
    case invalidChunks
    case invalidVectors
    case missingChunks
    case corruptManifest
    case unreadable
}

enum ChunkCacheLocation {
    static func macDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Chunky", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
    }
}

struct ChunkCacheStore {
    var directory: URL
    var limitBytes: Int

    init(directory: URL, limitBytes: Int = 0) {
        self.directory = directory
        self.limitBytes = max(0, limitBytes)
    }

    func stats() throws -> ChunkCacheStats {
        let manifest = try loadManifest()
        let bytes = manifest.reduce(0) { $0 + $1.bytes }
        return ChunkCacheStats(entries: manifest.count, bytes: bytes, limitBytes: limitBytes)
    }

    func lookup(
        _ key: ChunkCacheKey,
        embeddingModel: String? = nil,
        embeddingDimension: Int? = nil,
        includeDocument: Bool = false
    ) throws -> ChunkCacheHit? {
        var manifest = try loadManifest()
        guard let index = manifest.firstIndex(where: { $0.id == key.id }) else { return nil }
        let chunksURL = entryDirectory(key.id).appendingPathComponent("chunks.json")
        guard FileManager.default.fileExists(atPath: chunksURL.path) else { return nil }
        let chunks = try decodeChunks(chunksURL)
        manifest[index].lastUsedAt = Self.timestamp()
        try writeManifest(manifest)
        var vectors: [[Double]]?
        var vectorHit = false
        if let embeddingModel, let embeddingDimension, !embeddingModel.isEmpty, embeddingDimension > 0 {
            vectors = try readVectors(id: key.id, model: embeddingModel, dimension: embeddingDimension)
            vectorHit = vectors != nil
        }
        var document: Data?
        if includeDocument {
            let documentURL = entryDirectory(key.id).appendingPathComponent("document.json")
            document = try? Data(contentsOf: documentURL)
        }
        return ChunkCacheHit(id: key.id, chunks: chunks, vectorHit: vectorHit, vectors: vectors, document: document)
    }

    func store(key: ChunkCacheKey, document: Data, chunks: [ChunkCacheChunk]) throws -> ChunkCacheManifestEntry {
        guard !chunks.isEmpty else { throw ChunkCacheError.invalidChunks }
        guard (try? JSONSerialization.jsonObject(with: document)) is [String: Any] else {
            throw ChunkCacheError.invalidDocument
        }
        let folder = entryDirectory(key.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vectorsFolder = folder.appendingPathComponent("vectors", isDirectory: true)
        if FileManager.default.fileExists(atPath: vectorsFolder.path) {
            try FileManager.default.removeItem(at: vectorsFolder)
        }
        try atomicWrite(document, to: folder.appendingPathComponent("document.json"))
        try atomicWrite(try JSONSerialization.data(withJSONObject: chunks.map { $0.jsonObject() }), to: folder.appendingPathComponent("chunks.json"))
        var manifest = try loadManifest()
        manifest.removeAll { $0.id == key.id }
        let row = try row(key: key, vectors: [])
        manifest.append(row)
        let evicted = try evict(manifest, protect: key.id)
        try writeManifest(evicted)
        return evicted.first { $0.id == key.id } ?? row
    }

    func storeVectors(key: ChunkCacheKey, model: String, dimension: Int, vectors: [[Double]]) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dimension > 0 else { throw ChunkCacheError.invalidVectors }
        guard !vectors.isEmpty, vectors.allSatisfy({ $0.count == dimension }) else { throw ChunkCacheError.invalidVectors }
        let chunksURL = entryDirectory(key.id).appendingPathComponent("chunks.json")
        guard FileManager.default.fileExists(atPath: chunksURL.path) else { throw ChunkCacheError.missingChunks }
        let saved = try decodeChunks(chunksURL)
        guard vectors.count == saved.count else { throw ChunkCacheError.invalidVectors }
        let body: [String: Any] = ["model": trimmed, "dimension": dimension, "vectors": vectors]
        let path = vectorURL(id: key.id, model: trimmed, dimension: dimension)
        try atomicWrite(try JSONSerialization.data(withJSONObject: body), to: path)
        var manifest = try loadManifest()
        if let index = manifest.firstIndex(where: { $0.id == key.id }) {
            manifest[index].vectors.removeAll { vector in
                (vector["model"] as? String) == trimmed && Self.matches(vector["dimension"], dimension)
            }
            manifest[index].vectors.append([
                "model": trimmed,
                "dimension": dimension,
                "bytes": fileBytes(path),
            ])
            manifest[index].bytes = try entryBytes(key.id)
            manifest[index].lastUsedAt = Self.timestamp()
        }
        let evicted = try evict(manifest, protect: key.id)
        try writeManifest(evicted)
    }

    func clear() throws {
        let entries = directory.appendingPathComponent("entries", isDirectory: true)
        if FileManager.default.fileExists(atPath: entries.path) {
            try FileManager.default.removeItem(at: entries)
        }
        try writeManifest([])
    }

    private func row(key: ChunkCacheKey, vectors: [[String: Any]]) throws -> ChunkCacheManifestEntry {
        ChunkCacheManifestEntry(
            id: key.id,
            contentSHA256: key.contentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            doclingVersion: key.doclingVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            pipeline: key.pipeline.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenizer: key.tokenizer.trimmingCharacters(in: .whitespacesAndNewlines),
            maxTokens: key.maxTokens,
            bytes: try entryBytes(key.id),
            lastUsedAt: Self.timestamp(),
            vectors: vectors
        )
    }

    private func evict(_ manifest: [ChunkCacheManifestEntry], protect: String) throws -> [ChunkCacheManifestEntry] {
        guard limitBytes > 0 else { return manifest }
        var rows = manifest
        func total() -> Int { rows.reduce(0) { $0 + $1.bytes } }
        for row in rows.sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            if total() <= limitBytes {
                break
            }
            if row.id == protect {
                if rows.count == 1 {
                    break
                }
                continue
            }
            let folder = entryDirectory(row.id)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            rows.removeAll { $0.id == row.id }
        }
        return rows
    }

    private func entryDirectory(_ id: String) -> URL {
        directory.appendingPathComponent("entries", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func vectorURL(id: String, model: String, dimension: Int) -> URL {
        let digest = SHA256.hash(data: Data("\(model)\n\(dimension)".utf8)).map { String(format: "%02x", $0) }.joined()
        let name = String(digest.prefix(16)) + ".json"
        return entryDirectory(id).appendingPathComponent("vectors", isDirectory: true).appendingPathComponent(name)
    }

    private func readVectors(id: String, model: String, dimension: Int) throws -> [[Double]]? {
        let url = vectorURL(id: id, model: model, dimension: dimension)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["model"] as? String == model,
              (object["dimension"] as? Int) == dimension || (object["dimension"] as? NSNumber)?.intValue == dimension,
              let rows = object["vectors"] as? [[Any]]
        else { return nil }
        return rows.map { row in row.compactMap { ChunkCacheChunk.doubleValuePublic($0) } }
    }

    private func decodeChunks(_ url: URL) throws -> [ChunkCacheChunk] {
        let data = try Data(contentsOf: url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ChunkCacheError.unreadable
        }
        return rows.map(ChunkCacheChunk.normalize)
    }

    private func loadManifest() throws -> [ChunkCacheManifestEntry] {
        let url = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["entries"] as? [[String: Any]]
        else { throw ChunkCacheError.corruptManifest }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return ChunkCacheManifestEntry(
                id: id,
                contentSHA256: row["content_sha256"] as? String ?? "",
                doclingVersion: row["docling_version"] as? String ?? "",
                pipeline: row["pipeline"] as? String ?? "",
                tokenizer: row["tokenizer"] as? String ?? "",
                maxTokens: (row["max_tokens"] as? Int) ?? (row["max_tokens"] as? NSNumber)?.intValue ?? 0,
                bytes: (row["bytes"] as? Int) ?? (row["bytes"] as? NSNumber)?.intValue ?? 0,
                lastUsedAt: row["last_used_at"] as? String ?? "",
                vectors: row["vectors"] as? [[String: Any]] ?? []
            )
        }
    }

    private func writeManifest(_ entries: [ChunkCacheManifestEntry]) throws {
        let body: [String: Any] = [
            "schema": ChunkCacheSchema.version,
            "entries": entries.map { $0.jsonObject() },
        ]
        try atomicWrite(try JSONSerialization.data(withJSONObject: body), to: directory.appendingPathComponent("manifest.json"))
    }

    private func entryBytes(_ id: String) throws -> Int {
        let folder = entryDirectory(id)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix(".tmp-") { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += values.fileSize ?? 0
            }
        }
        return total
    }

    private func fileBytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func matches(_ value: Any?, _ dimension: Int) -> Bool {
        if let number = value as? Int {
            return number == dimension
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue == dimension
        }
        return false
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

struct ChunkCacheHit: Equatable {
    var id: String
    var chunks: [ChunkCacheChunk]
    var vectorHit: Bool
    var vectors: [[Double]]?
    var document: Data?
}

extension ChunkCacheChunk {
    fileprivate static func doubleValuePublic(_ value: Any?) -> Double? {
        doubleValue(value)
    }
}

struct URLSessionChunkCacheHTTP: ChunkCacheHTTP {
    var baseURL: String
    var token: String

    func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + path) else { throw ChunkCacheError.unreadable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

protocol ChunkCacheHTTP {
    func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data)
}

struct WorkerChunkCache {
    var http: any ChunkCacheHTTP

    func lookup(
        _ key: ChunkCacheKey,
        embeddingModel: String? = nil,
        embeddingDimension: Int? = nil,
        includeDocument: Bool = false
    ) async throws -> ChunkCacheHit {
        var body: [String: Any] = [
            "content_sha256": key.contentSHA256,
            "docling_version": key.doclingVersion,
            "pipeline": key.pipeline,
            "tokenizer": key.tokenizer,
            "max_tokens": key.maxTokens,
            "options": key.options,
            "include_document": includeDocument,
        ]
        if let embeddingModel, !embeddingModel.isEmpty {
            body["embedding_model"] = embeddingModel
        }
        if let embeddingDimension {
            body["embedding_dim"] = embeddingDimension
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.request(method: "POST", path: "/v1/cache/lookup", body: data)
        guard (200..<300).contains(response.status) else {
            throw ChunkCacheError.unreadable
        }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw ChunkCacheError.unreadable
        }
        let chunks = (object["chunks"] as? [[String: Any]] ?? []).map(ChunkCacheChunk.normalize)
        let vectors = object["vectors"] as? [[Any]]
        let document: Data?
        if let value = object["document"] as? [String: Any], JSONSerialization.isValidJSONObject(value) {
            document = try? JSONSerialization.data(withJSONObject: value)
        } else {
            document = nil
        }
        return ChunkCacheHit(
            id: object["id"] as? String ?? key.id,
            chunks: chunks,
            vectorHit: object["vector_hit"] as? Bool ?? false,
            vectors: vectors?.map { row in row.compactMap { ChunkCacheChunk.doubleValuePublic($0) } },
            document: document
        )
    }
}
