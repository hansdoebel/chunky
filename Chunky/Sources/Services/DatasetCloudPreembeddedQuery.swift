import Foundation

nonisolated enum DatasetCloudPreembeddedQuery {
    static func request(profile: DatasetCloudEmbeddingProfile, endpoint: String, text: String) throws -> URLRequest {
        guard let base = URLComponents(string: endpoint), ["http", "https"].contains(base.scheme ?? ""),
              base.host?.isEmpty == false, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/embeddings") else {
            throw DatasetCloudEmbeddingError.invalid("Choose an HTTP(S) OpenAI-compatible base URL without embedded credentials or query parameters.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": profile.model, "input": [text]])
        return request
    }

    @concurrent static func embed(profile: DatasetCloudEmbeddingProfile, endpoint: String, text: String, session: URLSession = .shared) async throws -> [Float] {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request(profile: profile, endpoint: endpoint, text: text))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 512 * 1024 else {
            throw DatasetCloudEmbeddingError.invalid("The compatible query gateway rejected the model probe or returned an oversized response. No model fallback is used.")
        }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < 512 * 1024 else { throw DatasetCloudEmbeddingError.invalid("The query response exceeded 512 KiB.") }
            data.append(byte)
        }
        return try profile.decodeQueryResponse(data)
    }
}
