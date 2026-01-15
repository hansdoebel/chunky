import Foundation

actor EmbeddingService {
    private let baseURL: URL
    private let model: String
    private let batchSize: Int
    private let concurrency: Int

    init(baseURL: String, model: String, batchSize: Int, concurrency: Int) throws {
        guard let url = URL(string: baseURL), url.scheme != nil else {
            throw EmbeddingError.invalidURL(baseURL)
        }
        self.baseURL = url
        self.model = model
        self.batchSize = batchSize
        self.concurrency = concurrency
    }

    func detectDimensions() async throws -> Int {
        let testEmbedding = try await embedBatch(["test"])
        guard let first = testEmbedding.first else {
            throw EmbeddingError.requestFailed
        }
        return first.count
    }

    func embed(texts: [String], onProgress: @escaping (Int, Int) async -> Void) async throws -> [[Float]] {
        var allEmbeddings: [[Float]] = Array(repeating: [], count: texts.count)
        let batches = texts.chunked(into: batchSize)

        try await withThrowingTaskGroup(of: (Int, [[Float]]).self) { group in
            var batchIndex = 0
            var runningTasks = 0

            for batch in batches {
                if runningTasks >= concurrency {
                    if let result = try await group.next() {
                        let (idx, embeddings) = result
                        for (i, embedding) in embeddings.enumerated() {
                            allEmbeddings[idx * batchSize + i] = embedding
                        }
                        runningTasks -= 1
                        await onProgress(idx + 1, batches.count)
                    }
                }

                let currentIndex = batchIndex
                group.addTask {
                    let embeddings = try await self.embedBatch(batch)
                    return (currentIndex, embeddings)
                }
                batchIndex += 1
                runningTasks += 1
            }

            for try await result in group {
                let (idx, embeddings) = result
                for (i, embedding) in embeddings.enumerated() {
                    let globalIndex = idx * batchSize + i
                    if globalIndex < allEmbeddings.count {
                        allEmbeddings[globalIndex] = embedding
                    }
                }
                await onProgress(idx + 1, batches.count)
            }
        }

        return allEmbeddings
    }

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        let url = baseURL.appendingPathComponent("api/embed")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "input": texts
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmbeddingError.requestFailed
        }

        let result = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return result.embeddings
    }
}

struct EmbeddingResponse: Codable {
    let embeddings: [[Float]]
}

enum EmbeddingError: Error, LocalizedError {
    case invalidURL(String)
    case requestFailed
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid Ollama URL: \(url)"
        case .requestFailed:
            return "Failed to get embeddings from Ollama"
        case .emptyInput:
            return "No text to embed"
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
