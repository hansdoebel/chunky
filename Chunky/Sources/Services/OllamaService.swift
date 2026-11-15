import Foundation

/// Service for generating embeddings using Ollama
actor OllamaService {

    // MARK: - Types

    struct EmbeddingRequest: Codable {
        let model: String
        let input: [String]
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

    // MARK: - Properties

    private let baseURL: URL
    private let session: URLSession
    private var dimensionCache = EmbeddingDimensionCache()

    // MARK: - Initialization

    init(baseURL: String = "http://localhost:11434") throws {
        guard let url = URL(string: baseURL) else {
            throw OllamaError.connectionFailed("Invalid URL: \(baseURL)")
        }
        self.baseURL = url

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes for large batches
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    /// Check if Ollama is running
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

    /// Fetch available models
    func listModels() async throws -> [ModelInfo] {
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

        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.models
    }

    /// Fetch models that support embeddings
    func listEmbeddingModels() async throws -> [ModelInfo] {
        let models = try await listModels()
        // Filter for known embedding models
        let embeddingKeywords = ["embed", "nomic", "mxbai", "bge", "e5", "gte"]
        return models.filter { model in
            let name = model.name.lowercased()
            return embeddingKeywords.contains { name.contains($0) }
        }
    }

    /// Embed one probe string and remember the width for this model.
    func probeDimension(model: String) async throws -> Int {
        if let cached = dimensionCache.cached(model) {
            return cached
        }
        let vector = try await embed(text: EmbeddingDimensionCache.probeText, model: model)
        return try dimensionCache.store(model: model, vector: vector)
    }

    /// Generate embeddings for a single text
    func embed(text: String, model: String) async throws -> [Float] {
        let embeddings = try await embedBatch(texts: [text], model: model)
        guard let first = embeddings.first else {
            throw OllamaError.invalidResponse
        }
        return first
    }

    /// Generate embeddings for multiple texts
    func embedBatch(texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let url = baseURL.appendingPathComponent("api/embed")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = EmbeddingRequest(model: model, input: texts)
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

    /// Generate embeddings for texts in batches with progress reporting
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

extension OllamaService {
    /// Get the embedding dimension for a model. Uses the cached probe.
    func getEmbeddingDimension(model: String) async throws -> Int {
        try await probeDimension(model: model)
    }
}
