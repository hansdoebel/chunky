import Foundation

struct OllamaModel: Codable, Identifiable, Hashable {
    let name: String
    let size: Int64?
    let digest: String?
    let modifiedAt: String?

    var id: String { name }

    var displayName: String {
        name.replacingOccurrences(of: ":latest", with: "")
    }

    var sizeFormatted: String {
        guard let size = size else { return "" }
        let gb = Double(size) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(size) / 1_000_000
        return String(format: "%.0f MB", mb)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case digest
        case modifiedAt = "modified_at"
    }
}

struct OllamaTagsResponse: Codable {
    let models: [OllamaModel]
}

actor OllamaService {
    private let baseURL: URL

    init(baseURL: String) throws {
        guard let url = URL(string: baseURL), url.scheme != nil else {
            throw OllamaServiceError.invalidURL(baseURL)
        }
        self.baseURL = url
    }

    func fetchAvailableModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaServiceError.connectionFailed
        }

        let result = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return result.models
    }

    func isServerAvailable() async -> Bool {
        do {
            _ = try await fetchAvailableModels()
            return true
        } catch {
            return false
        }
    }
}

enum OllamaServiceError: Error, LocalizedError {
    case invalidURL(String)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid Ollama URL: \(url)"
        case .connectionFailed:
            return "Could not connect to Ollama server"
        }
    }
}

enum EmbeddingModelInfo {
    static let dimensions: [String: Int] = [
        "nomic-embed-text": 768,
        "nomic-embed-text:latest": 768,
        "mxbai-embed-large": 1024,
        "mxbai-embed-large:latest": 1024,
        "all-minilm": 384,
        "all-minilm:latest": 384,
        "snowflake-arctic-embed": 1024,
        "snowflake-arctic-embed:latest": 1024,
    ]

    static func getDimensions(for model: String) -> Int {
        let baseName = model.replacingOccurrences(of: ":latest", with: "")
        return dimensions[baseName] ?? dimensions[model] ?? 768
    }
}
