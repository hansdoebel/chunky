import Foundation

struct LocalEmbeddingService {
    var backend: String
    var ollamaURL: String
    var apiURL: String

    func probeDimension(model: String) async throws -> Int {
        try await EmbeddingDimensionProbe.probe(backend: backend, model: model, ollamaURL: ollamaURL, apiURL: apiURL)
    }

    func embedBatch(texts: [String], model: String) async throws -> [[Float]] {
        if backend == "fastembed" {
            return try await FastEmbedService.shared.embed(texts: texts, model: model)
        }
        if backend == "openai" {
            var vectors: [[Float]] = []
            for text in texts {
                try Task.checkCancellation()
                vectors.append(try await LiveRetrievalEmbedding().embed(text: text, backend: backend, model: model, ollamaURL: ollamaURL, apiURL: apiURL))
            }
            return vectors
        }
        return try await OllamaService(baseURL: ollamaURL).embedBatch(texts: texts, model: model)
    }

    func embedWithProgress(texts: [String], model: String, batchSize: Int, concurrency: Int, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [[Float]] {
        if backend == "ollama" {
            return try await OllamaService(baseURL: ollamaURL).embedWithProgress(texts: texts, model: model, batchSize: batchSize, concurrency: concurrency, onProgress: progress)
        }
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            vectors += try await embedBatch(texts: Array(texts[start..<min(start + max(1, batchSize), texts.count)]), model: model)
            progress(vectors.count, texts.count)
        }
        return vectors
    }
}
