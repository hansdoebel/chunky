import Foundation

actor OllamaService {

    struct EmbeddingRequest: Codable {
        let model: String
        let input: [String]
        var truncate: Bool? = nil
    }

    struct EmbeddingResponse: Codable {
        let model: String
        let embeddings: [[Float]]
    }

    struct ModelInfo: Codable, Identifiable, Sendable {
        let name: String
        let modifiedAt: String?
        let size: Int64?

        var id: String { name }

        var displayName: String {
            name.components(separatedBy: ":").first ?? name
        }

        var sizeFormatted: String {
            guard let size = size else { return "Unknown" }
            let gb = Double(size) / 1_000_000_000
            if gb >= 1 {
                return String(format: "%.1f GB", gb)
            }
            let mb = Double(size) / 1_000_000
            return String(format: "%.0f MB", mb)
        }

        enum CodingKeys: String, CodingKey {
            case name
            case modifiedAt = "modified_at"
            case size
        }
    }

    struct ModelsResponse: Codable {
        let models: [ModelInfo]
    }

    enum OllamaError: LocalizedError, Sendable {
        case connectionFailed(String)
        case invalidResponse
        case embeddingFailed(String)
        case modelNotFound(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message):
                return "Failed to connect to Ollama: \(message)"
            case .invalidResponse:
                return "Invalid response from Ollama"
            case .embeddingFailed(let message):
                return "Embedding generation failed: \(message)"
            case .modelNotFound(let model):
                return "Model not found: \(model)"
            }
        }
    }

    private let baseURL: URL

    nonisolated let configuredURL: String
    private let session: URLSession
    private var dimensionCache = EmbeddingDimensionCache()

    init(baseURL: String = "http://localhost:11434") throws {
        guard let url = URL(string: baseURL) else {
            throw OllamaError.connectionFailed("Invalid URL: \(baseURL)")
        }
        self.baseURL = url
        self.configuredURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func tagsData() async throws -> Data {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw OllamaError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
        return data
    }

    func listModels() async throws -> [ModelInfo] {
        let data = try await tagsData()
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.models
    }

    func probeDimension(model: String) async throws -> Int {
        if let cached = dimensionCache.cached(model) {
            return cached
        }
        let vector = try await embed(text: EmbeddingDimensionCache.probeText, model: model)
        return try dimensionCache.store(model: model, vector: vector)
    }

    func embed(text: String, model: String) async throws -> [Float] {
        let embeddings = try await embedBatch(texts: [text], model: model)
        guard let first = embeddings.first else {
            throw OllamaError.invalidResponse
        }
        return first
    }

    func embedBatch(texts: [String], model: String, truncate: Bool? = nil) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let url = baseURL.appendingPathComponent("api/embed")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = EmbeddingRequest(model: model, input: texts, truncate: truncate)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw OllamaError.modelNotFound(model)
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OllamaError.embeddingFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let embeddingResponse = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return embeddingResponse.embeddings
    }

    func embedWithProgress(
        texts: [String],
        model: String,
        batchSize: Int = 32,
        concurrency: Int = 1,
        onProgress: @Sendable (Int, Int) -> Void
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let totalBatches = (texts.count + batchSize - 1) / batchSize
        let maxConcurrency = max(1, min(concurrency, totalBatches))

        if maxConcurrency <= 1 {
            var allEmbeddings: [[Float]] = []
            allEmbeddings.reserveCapacity(texts.count)

            for (batchIndex, startIndex) in stride(from: 0, to: texts.count, by: batchSize).enumerated() {
                let endIndex = min(startIndex + batchSize, texts.count)
                let batch = Array(texts[startIndex..<endIndex])
                let embeddings = try await embedBatch(texts: batch, model: model)
                allEmbeddings.append(contentsOf: embeddings)
                onProgress(batchIndex + 1, totalBatches)
            }
            return allEmbeddings
        }

        var results = Array<[[Float]]?>(repeating: nil, count: totalBatches)
        let completedCount = UnsafeSendableCounter()

        try await withThrowingTaskGroup(of: (Int, [[Float]]).self) { group in
            var launched = 0

            for (batchIndex, startIndex) in stride(from: 0, to: texts.count, by: batchSize).enumerated() {
                if launched >= maxConcurrency {
                    if let (idx, embeddings) = try await group.next() {
                        results[idx] = embeddings
                        let done = completedCount.increment()
                        onProgress(done, totalBatches)
                    }
                }

                let endIndex = min(startIndex + batchSize, texts.count)
                let batch = Array(texts[startIndex..<endIndex])
                let bIdx = batchIndex

                group.addTask {
                    let embeddings = try await self.embedBatch(texts: batch, model: model)
                    return (bIdx, embeddings)
                }
                launched += 1
            }

            for try await (idx, embeddings) in group {
                results[idx] = embeddings
                let done = completedCount.increment()
                onProgress(done, totalBatches)
            }
        }

        return results.compactMap { $0 }.flatMap { $0 }
    }

}

private final class UnsafeSendableCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
