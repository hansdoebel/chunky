import Foundation

enum EmbeddingDimensionProbe {
    static func probe(backend: String, model: String, ollamaURL: String, apiURL: String) async throws -> Int {
        if backend == "fastembed" {
            return try await FastEmbedService.shared.embed(texts: ["chunky"], model: model).first?.count ?? 0
        }
        if backend == EmbeddingBackendKind.openai.rawValue {
            return try await openAI(url: apiURL, model: model)
        }
        let service = try OllamaService(baseURL: ollamaURL)
        return try await service.probeDimension(model: model)
    }

    private static func openAI(url: String, model: String) async throws -> Int {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(string: trimmed + "/v1/embeddings") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": ["chunky"]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = object?["data"] as? [[String: Any]]
        let embedding = rows?.first?["embedding"] as? [Any]
        guard let count = embedding?.count, count > 0 else {
            throw URLError(.cannotParseResponse)
        }
        return count
    }
}
