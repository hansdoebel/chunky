import Foundation

struct DevboxSSEEvent: Equatable {
    var type: String
    var message: String?
    var percent: Double?
    var status: String?
}

enum DevboxSSEParser {
    static func parse(line: String) -> DevboxSSEEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
            let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let percent: Double?
        if let value = object["percent"] as? Double {
            percent = value
        } else if let value = object["percent"] as? Int {
            percent = Double(value)
        } else if let value = object["percent"] as? NSNumber {
            percent = value.doubleValue
        } else {
            percent = nil
        }
        return DevboxSSEEvent(
            type: object["type"] as? String ?? "progress",
            message: object["message"] as? String,
            percent: percent,
            status: object["status"] as? String
        )
    }
}

enum DevboxClientError: LocalizedError, Equatable {
    case invalidURL(String)
    case unreachable(url: String, reason: String)
    case transportSecurity(url: String)
    case unauthorized(url: String)
    case dimensionMismatch(url: String, detail: String)
    case http(url: String, status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid worker URL: \(url)"
        case .unreachable(let url, let reason):
            return "Cannot reach \(url). \(reason) Check the worker address, that chunky-worker is running, and the firewall."
        case .transportSecurity(let url):
            return "App Transport Security blocked \(url). Private LAN addresses are allowed by NSAllowsLocalNetworking. Use a LAN address, or HTTPS for a public host."
        case .unauthorized(let url):
            return "Worker rejected the token (401) for \(url). Check the token in the Keychain."
        case .dimensionMismatch(let url, let detail):
            return "Embedding dimension mismatch at \(url). \(detail)"
        case .http(let url, let status, let detail):
            return "Worker returned HTTP \(status) for \(url). \(detail)"
        }
    }
}

enum DevboxErrorMapper {
    static func classify(url: String, status: Int, body: String) -> DevboxClientError {
        if status == 401 || status == 403 {
            return .unauthorized(url: url)
        }
        if body.contains("dimension_mismatch") || body.contains("vector size") {
            return .dimensionMismatch(url: url, detail: body)
        }
        return .http(url: url, status: status, detail: body)
    }

    static func classify(url: String, error: URLError) -> DevboxClientError {
        if error.code == .appTransportSecurityRequiresSecureConnection {
            return .transportSecurity(url: url)
        }
        let reason: String
        switch error.code {
        case .timedOut:
            reason = "The connection timed out."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            reason = "The host is unreachable."
        default:
            reason = error.localizedDescription
        }
        return .unreachable(url: url, reason: reason)
    }
}

struct ParsedWorkerJob {
    var status: String
    var error: String?
    var errorType: String?
    var chunks: [[String: Any]]
    var embeddings: [[Float]]
    var embeddingDim: Int?
    var docTitle: String?
    var authors: [String]
    var language: String?
    var year: Int?
    var ingestUpserted: Int?
    var ingestCollection: String?
    var pageCount: Int?
    var tokenCount: Int?
    var metrics: JobMetrics?
}

enum DevboxJobPayload {
    static func authorizationHeader(token: String) -> String {
        "Bearer \(token)"
    }

    static func settings(from settings: AppSettings, mode: ProcessingMode, collection: String? = nil) -> [String: Any] {
        let collectionName = collection ?? settings.defaultCollection
        let options = CollectionPlanStore.options(collection: collectionName, settings: settings)
        let ingest: String
        switch (mode, options.target) {
        case (.chunkOnly, _):
            ingest = "none"
        case (.full, .qdrantCloud):
            ingest = "qdrant_cloud"
        case (.full, .localDocker):
            ingest = "return_vectors"
        }
        let model = DoclingModel.workerModelID(settings.doclingModel)
        var body: [String: Any] = [
            "mode": mode == .chunkOnly ? "chunk_only" : "chunk_and_embed",
            "ingest_target": ingest,
            "format": "json",
            "accelerator": settings.doclingAccelerator == "cpu" ? "cpu" : "cuda",
            "enable_ocr": settings.doOCR,
            "table_mode": settings.tableMode,
            "chunk": true,
            "chunk_max_tokens": settings.maxTokensPerChunk,
            "workers": settings.doclingWorkers,
            "ocr_batch_size": settings.ocrBatchSize,
            "layout_batch_size": settings.layoutBatchSize,
            "table_batch_size": settings.tableBatchSize,
            "chunk_merge_peers": settings.chunkMergePeers,
            "embedding_model": settings.embeddingModel,
            "embedding_backend": settings.embeddingBackend,
            "embedding_url": settings.embeddingBackend == EmbeddingBackendKind.openai.rawValue
                ? settings.embeddingAPIURL
                : settings.ollamaURL,
            "ollama_url": "http://127.0.0.1:11434",
            "do_picture_description": settings.doPictureDescription,
            "do_picture_classification": settings.doPictureClassification,
            "picture_description_preset": settings.resolvedPictureDescriptionPreset,
            "vlm_server_url": settings.vlmServerURL,
            "qdrant_collection": collectionName,
            "qdrant_distance": options.distance.rawValue,
            "qdrant_hybrid": options.hybrid,
            "qdrant_quantization": options.quantization.wireValue,
            "qdrant_on_disk": options.storesOnDisk,
            "qdrant_batch_size": settings.qdrantBatchSize,
        ]
        if let packing = CollectionPackingStore.load(name: collectionName, defaults: settings.defaults) {
            body["qdrant_vector_memory"] = packing.vectors.rawValue
            body["qdrant_hnsw_memory"] = packing.hnsw.rawValue
            body["qdrant_quantization_memory"] = packing.quantizationTier.rawValue
            body["qdrant_payload_memory"] = packing.payload.rawValue
            body["qdrant_quantization"] = packing.quantization.wireValue
            body["qdrant_on_disk"] = packing.vectors == .cold || packing.payload == .cold
        }
        if model != "standard" {
            body["vlm_model"] = model
        }
        if ingest == "qdrant_cloud" {
            body["qdrant_url"] = settings.qdrantCloudURL
            body["qdrant_api_key"] = settings.qdrantAPIKey
        }
        if let offset = settings.journalPageOffset {
            body["page_offset"] = offset
        }
        return body
    }

    static func settings(from settings: AppSettings, mode: ProcessingMode, bibliography: BibliographicMetadata?, collection: String? = nil) -> [String: Any] {
        var body = self.settings(from: settings, mode: mode, collection: collection)
        guard let bibliography else { return body }
        if !bibliography.title.isEmpty { body["bibliography_title"] = bibliography.title }
        if !bibliography.authors.isEmpty { body["bibliography_authors"] = bibliography.authors }
        if let year = bibliography.year { body["bibliography_year"] = year }
        if let doi = bibliography.doi, !doi.isEmpty { body["bibliography_doi"] = doi }
        if let venue = bibliography.venue, !venue.isEmpty { body["bibliography_venue"] = venue }
        if let abstract = bibliography.abstract, !abstract.isEmpty { body["bibliography_abstract"] = abstract }
        if !bibliography.citeKey.isEmpty { body["bibliography_cite_key"] = bibliography.citeKey }
        if !bibliography.source.isEmpty { body["bibliography_source"] = bibliography.source }
        return body
    }

    static func multipartBody(filename: String, fileData: Data, settings: [String: Any], boundary: String) throws -> Data {
        let settingsJSON = try JSONSerialization.data(withJSONObject: settings)
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"settings\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(settingsJSON)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func parseJob(_ data: Data) throws -> ParsedWorkerJob {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DevboxClientError.http(url: "", status: 0, detail: "Job response was not a JSON object")
        }
        let result = object["result"] as? [String: Any]
        let chunks = result?["chunks"] as? [[String: Any]] ?? []
        let embeddings = (result?["embeddings"] as? [[Any]] ?? []).map { row in
            row.compactMap { value -> Float? in
                (value as? NSNumber)?.floatValue
            }
        }
        let ingest = result?["ingest"] as? [String: Any]
        var metrics: JobMetrics?
        if let metricsObject = result?["metrics"],
           JSONSerialization.isValidJSONObject(metricsObject),
           let metricsData = try? JSONSerialization.data(withJSONObject: metricsObject) {
            metrics = try? JSONDecoder().decode(JobMetrics.self, from: metricsData)
        }
        return ParsedWorkerJob(
            status: object["status"] as? String ?? "",
            error: object["error"] as? String,
            errorType: object["error_type"] as? String,
            chunks: chunks,
            embeddings: embeddings,
            embeddingDim: (result?["embedding_dim"] as? NSNumber)?.intValue,
            docTitle: result?["doc_title"] as? String,
            authors: stringList(result?["authors"]),
            language: result?["language"] as? String,
            year: (result?["year"] as? NSNumber)?.intValue,
            ingestUpserted: (ingest?["upserted"] as? NSNumber)?.intValue,
            ingestCollection: ingest?["collection"] as? String,
            pageCount: (result?["page_count"] as? NSNumber)?.intValue,
            tokenCount: chunks.reduce(0) { $0 + (($1["token_count"] as? NSNumber)?.intValue ?? 0) },
            metrics: metrics
        )
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        if let text = value as? String, !text.isEmpty { return [text] }
        return []
    }
}

final class DevboxWorkerService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func probe(baseURL: String, token: String) async -> WorkerProbeReport {
        let started = Date()
        func finish(
            healthStatus: Int?,
            healthFailedSecure: Bool,
            healthUnreachable: Bool,
            modelsStatus: Int?,
            modelsFailedSecure: Bool,
            modelsUnreachable: Bool
        ) -> WorkerProbeReport {
            WorkerProbe.classify(
                url: baseURL,
                healthStatus: healthStatus,
                healthFailedSecure: healthFailedSecure,
                healthUnreachable: healthUnreachable,
                modelsStatus: modelsStatus,
                modelsFailedSecure: modelsFailedSecure,
                modelsUnreachable: modelsUnreachable,
                elapsed: Date().timeIntervalSince(started)
            )
        }
        guard WorkerProbe.accepts(url: baseURL), let root = URL(string: baseURL) else {
            return finish(healthStatus: nil, healthFailedSecure: false, healthUnreachable: true, modelsStatus: nil, modelsFailedSecure: false, modelsUnreachable: false)
        }
        let health = root.appendingPathComponent("v1").appendingPathComponent("health")
        var healthStatus: Int?
        var healthSecure = false
        var healthDown = false
        do {
            let (data, response) = try await session.data(from: health)
            if let http = response as? HTTPURLResponse {
                healthStatus = http.statusCode
                if http.statusCode != 200 {
                    _ = data
                }
            } else {
                healthDown = true
            }
        } catch let error as URLError {
            if error.code == .appTransportSecurityRequiresSecureConnection {
                healthSecure = true
            } else {
                healthDown = true
            }
        } catch {
            healthDown = true
        }
        if healthSecure || healthDown || healthStatus != 200 {
            return finish(healthStatus: healthStatus, healthFailedSecure: healthSecure, healthUnreachable: healthDown, modelsStatus: nil, modelsFailedSecure: false, modelsUnreachable: false)
        }
        let models = root.appendingPathComponent("v1").appendingPathComponent("models")
        var request = URLRequest(url: models)
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return finish(healthStatus: healthStatus, healthFailedSecure: false, healthUnreachable: false, modelsStatus: status, modelsFailedSecure: false, modelsUnreachable: status == nil)
        } catch let error as URLError {
            let secure = error.code == .appTransportSecurityRequiresSecureConnection
            return finish(healthStatus: healthStatus, healthFailedSecure: false, healthUnreachable: false, modelsStatus: nil, modelsFailedSecure: secure, modelsUnreachable: !secure)
        } catch {
            return finish(healthStatus: healthStatus, healthFailedSecure: false, healthUnreachable: false, modelsStatus: nil, modelsFailedSecure: false, modelsUnreachable: true)
        }
    }

    func testConnection(baseURL: String, token: String) async -> String {
        guard let root = URL(string: baseURL), let scheme = root.scheme, scheme == "http" || scheme == "https", root.host != nil else {
            return DevboxClientError.invalidURL(baseURL).errorDescription ?? "Invalid worker URL"
        }
        let health = root.appendingPathComponent("v1").appendingPathComponent("health")
        do {
            let (data, response) = try await session.data(from: health)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                return DevboxErrorMapper.classify(url: health.absoluteString, status: http.statusCode, body: body)
                    .errorDescription ?? "Health check failed"
            }
        } catch let error as URLError {
            return DevboxErrorMapper.classify(url: health.absoluteString, error: error).errorDescription ?? error.localizedDescription
        } catch {
            return DevboxClientError.unreachable(url: health.absoluteString, reason: error.localizedDescription).errorDescription
                ?? error.localizedDescription
        }

        let models = root.appendingPathComponent("v1").appendingPathComponent("models")
        var request = URLRequest(url: models)
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "No HTTP response from \(models.absoluteString)"
            }
            if http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                return DevboxErrorMapper.classify(url: models.absoluteString, status: http.statusCode, body: body)
                    .errorDescription ?? "Models check failed"
            }
            let count = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["embeddings"] as? [Any])?.count ?? 0
            return "Connected to \(root.absoluteString). Embeddings reported: \(count)."
        } catch let error as URLError {
            return DevboxErrorMapper.classify(url: models.absoluteString, error: error).errorDescription ?? error.localizedDescription
        } catch {
            return DevboxClientError.unreachable(url: models.absoluteString, reason: error.localizedDescription).errorDescription
                ?? error.localizedDescription
        }
    }

    func run(
        fileURL: URL,
        settings: [String: Any],
        baseURL: String,
        token: String,
        onCreated: @escaping (String) -> Void,
        onEvent: @escaping (DevboxSSEEvent) -> Void
    ) async throws -> ParsedWorkerJob {
        guard let root = URL(string: baseURL), root.host != nil else {
            throw DevboxClientError.invalidURL(baseURL)
        }
        let created = try await createJob(fileURL: fileURL, settings: settings, root: root, token: token)
        onCreated(created)
        try await stream(jobID: created, root: root, token: token, onEvent: onEvent)
        return try await fetchJob(id: created, root: root, token: token)
    }

    func fetchInstalledModels(baseURL: String, token: String) async throws -> [ManagedModel] {
        let data = try await authorizedData(baseURL: baseURL, token: token, path: ["v1", "models"], method: "GET", body: nil)
        return try ModelCatalog.installedModels(fromWorker: data)
    }

    func startModelDownload(baseURL: String, token: String, repoID: String, kind: String) async throws -> String {
        guard let root = URL(string: baseURL), root.host != nil else {
            throw DevboxClientError.invalidURL(baseURL)
        }
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("models").appendingPathComponent("download")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["repo_id": repoID, "kind": kind])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DevboxClientError.unreachable(url: endpoint.absoluteString, reason: "No HTTP response")
        }
        if http.statusCode == 401 {
            throw DevboxClientError.unauthorized(url: endpoint.absoluteString)
        }
        guard http.statusCode == 202 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DevboxClientError.http(url: endpoint.absoluteString, status: http.statusCode, detail: body)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["id"] as? String ?? ""
    }

    func waitForModelDownload(baseURL: String, token: String, jobID: String) async throws -> String {
        guard !jobID.isEmpty else { return "succeeded" }
        for _ in 0..<180 {
            let data = try await authorizedData(
                baseURL: baseURL,
                token: token,
                path: ["v1", "models", "download", jobID],
                method: "GET",
                body: nil
            )
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = object?["status"] as? String ?? ""
            if status == "failed" {
                throw DevboxClientError.http(
                    url: baseURL,
                    status: 200,
                    detail: object?["message"] as? String ?? "Download failed"
                )
            }
            if status == "succeeded" || status == "canceled" {
                return status
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "downloading"
    }

    private func authorizedData(baseURL: String, token: String, path: [String], method: String, body: Data?) async throws -> Data {
        guard var root = URL(string: baseURL), root.host != nil else {
            throw DevboxClientError.invalidURL(baseURL)
        }
        for part in path {
            root.appendPathComponent(part)
        }
        var request = URLRequest(url: root)
        request.httpMethod = method
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DevboxClientError.unreachable(url: root.absoluteString, reason: "No HTTP response")
        }
        if http.statusCode == 401 {
            throw DevboxClientError.unauthorized(url: root.absoluteString)
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DevboxClientError.http(url: root.absoluteString, status: http.statusCode, detail: detail)
        }
        return data
    }

    func fetchVerification(jobID: String, baseURL: String, token: String) async throws -> VerificationReport {
        let data = try await authorizedData(
            baseURL: baseURL,
            token: token,
            path: ["v1", "jobs", jobID, "verification"],
            method: "GET",
            body: nil
        )
        return try JSONDecoder().decode(VerificationReport.self, from: data)
    }

    func reverifyJob(
        jobID: String,
        baseURL: String,
        token: String,
        qdrantURL: String,
        qdrantKey: String,
        collection: String
    ) async throws -> VerificationReport {
        var body: [String: Any] = [:]
        if !collection.isEmpty { body["qdrant_collection"] = collection }
        if !qdrantURL.isEmpty { body["qdrant_url"] = qdrantURL }
        if !qdrantKey.isEmpty { body["qdrant_api_key"] = qdrantKey }
        let data = try await authorizedData(
            baseURL: baseURL,
            token: token,
            path: ["v1", "jobs", jobID, "verify"],
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
        return try JSONDecoder().decode(VerificationReport.self, from: data)
    }

    func verifyFile(
        fileURL: URL,
        chunks: [ChunkingService.DocumentChunk],
        baseURL: String,
        token: String,
        qdrantURL: String,
        qdrantKey: String,
        collection: String,
        embeddingModel: String
    ) async throws -> VerificationReport {
        guard let root = URL(string: baseURL), root.host != nil else {
            throw DevboxClientError.invalidURL(baseURL)
        }
        var settings: [String: Any] = [
            "chunks": VerificationPayload.chunkRows(chunks),
            "qdrant_collection": collection,
            "embedding_model": embeddingModel,
        ]
        if !qdrantURL.isEmpty { settings["qdrant_url"] = qdrantURL }
        if !qdrantKey.isEmpty { settings["qdrant_api_key"] = qdrantKey }
        let boundary = "ChunkyBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let fileData = try Data(contentsOf: fileURL)
        let body = try DevboxJobPayload.multipartBody(
            filename: fileURL.lastPathComponent,
            fileData: fileData,
            settings: settings,
            boundary: boundary
        )
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("verify")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DevboxClientError.unreachable(url: endpoint.absoluteString, reason: "No HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = VerificationPayload.redact(String(data: data, encoding: .utf8) ?? "", secrets: [qdrantKey, token])
            throw DevboxErrorMapper.classify(url: endpoint.absoluteString, status: http.statusCode, body: text)
        }
        return try JSONDecoder().decode(VerificationReport.self, from: data)
    }

    func cancel(jobID: String, baseURL: String, token: String) async {
        guard let root = URL(string: baseURL) else { return }
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("jobs").appendingPathComponent(jobID).appendingPathComponent("cancel")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func createJob(fileURL: URL, settings: [String: Any], root: URL, token: String) async throws -> String {
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("jobs")
        let boundary = "ChunkyBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let fileData = try Data(contentsOf: fileURL)
        let body = try DevboxJobPayload.multipartBody(
            filename: fileURL.lastPathComponent,
            fileData: fileData,
            settings: settings,
            boundary: boundary
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DevboxClientError.http(url: endpoint.absoluteString, status: 0, detail: "No HTTP response")
        }
        if http.statusCode != 202 && http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw DevboxErrorMapper.classify(url: endpoint.absoluteString, status: http.statusCode, body: text)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        else {
            throw DevboxClientError.http(url: endpoint.absoluteString, status: http.statusCode, detail: "Missing job id")
        }
        return id
    }

    private func stream(jobID: String, root: URL, token: String, onEvent: (DevboxSSEEvent) -> Void) async throws {
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("jobs").appendingPathComponent(jobID).appendingPathComponent("events")
        var request = URLRequest(url: endpoint)
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DevboxErrorMapper.classify(url: endpoint.absoluteString, status: http.statusCode, body: "")
        }
        for try await line in bytes.lines {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard let event = DevboxSSEParser.parse(line: line) else { continue }
            onEvent(event)
            if event.type == "complete" || event.type == "error" || event.type == "canceled" {
                break
            }
        }
    }

    private func fetchJob(id: String, root: URL, token: String) async throws -> ParsedWorkerJob {
        let endpoint = root.appendingPathComponent("v1").appendingPathComponent("jobs").appendingPathComponent(id)
        var request = URLRequest(url: endpoint)
        request.setValue(DevboxJobPayload.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw DevboxErrorMapper.classify(url: endpoint.absoluteString, status: http.statusCode, body: text)
        }
        return try DevboxJobPayload.parseJob(data)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw DevboxErrorMapper.classify(url: request.url?.absoluteString ?? "", error: error)
        }
    }

    private func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let error as URLError {
            throw DevboxErrorMapper.classify(url: request.url?.absoluteString ?? "", error: error)
        }
    }
}
