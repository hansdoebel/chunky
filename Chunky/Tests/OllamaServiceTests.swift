import XCTest

struct MockOllamaModel: Codable, Identifiable, Hashable {
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

struct MockOllamaTagsResponse: Codable {
    let models: [MockOllamaModel]
}

enum MockOllamaServiceError: Error, LocalizedError {
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

final class OllamaServiceTests: XCTestCase {

    func testURLValidation() {
        let validURLs = [
            "http://localhost:11434",
            "https://ollama.example.com"
        ]

        for urlString in validURLs {
            let url = URL(string: urlString)
            XCTAssertNotNil(url, "Should create URL from: \(urlString)")
            XCTAssertNotNil(url?.scheme, "URL should have scheme: \(urlString)")
        }
    }

    func testInvalidURLDetection() {
        let emptyURL = URL(string: "")
        XCTAssertNil(emptyURL, "Empty string should not create URL")

        let validHTTPUrl = URL(string: "http://localhost:11434")
        XCTAssertEqual(validHTTPUrl?.scheme, "http")
        XCTAssertEqual(validHTTPUrl?.host, "localhost")
        XCTAssertEqual(validHTTPUrl?.port, 11434)
    }

    func testOllamaServiceErrorDescriptions() {
        let invalidURLError = MockOllamaServiceError.invalidURL("bad-url")
        XCTAssertEqual(invalidURLError.errorDescription, "Invalid Ollama URL: bad-url")

        let connectionFailedError = MockOllamaServiceError.connectionFailed
        XCTAssertEqual(connectionFailedError.errorDescription, "Could not connect to Ollama server")
    }

    func testOllamaModelDecoding() throws {
        let json = """
        {
            "name": "nomic-embed-text:latest",
            "size": 274302450,
            "digest": "abc123def456",
            "modified_at": "2024-01-15T10:30:00Z"
        }
        """
        let data = json.data(using: .utf8)!
        let model = try JSONDecoder().decode(MockOllamaModel.self, from: data)

        XCTAssertEqual(model.name, "nomic-embed-text:latest")
        XCTAssertEqual(model.size, 274302450)
        XCTAssertEqual(model.digest, "abc123def456")
        XCTAssertEqual(model.modifiedAt, "2024-01-15T10:30:00Z")
    }

    func testOllamaModelDisplayName() throws {
        let json = """
        {
            "name": "nomic-embed-text:latest",
            "size": null,
            "digest": null,
            "modified_at": null
        }
        """
        let data = json.data(using: .utf8)!
        let model = try JSONDecoder().decode(MockOllamaModel.self, from: data)

        XCTAssertEqual(model.displayName, "nomic-embed-text")
        XCTAssertEqual(model.id, "nomic-embed-text:latest")
    }

    func testOllamaModelSizeFormattedGB() throws {
        let json = """
        {
            "name": "llama2:70b",
            "size": 45000000000,
            "digest": null,
            "modified_at": null
        }
        """
        let data = json.data(using: .utf8)!
        let model = try JSONDecoder().decode(MockOllamaModel.self, from: data)

        XCTAssertEqual(model.sizeFormatted, "45.0 GB")
    }

    func testOllamaModelSizeFormattedMB() throws {
        let json = """
        {
            "name": "nomic-embed-text",
            "size": 274000000,
            "digest": null,
            "modified_at": null
        }
        """
        let data = json.data(using: .utf8)!
        let model = try JSONDecoder().decode(MockOllamaModel.self, from: data)

        XCTAssertEqual(model.sizeFormatted, "274 MB")
    }

    func testOllamaModelSizeFormattedNil() throws {
        let json = """
        {
            "name": "test-model",
            "size": null,
            "digest": null,
            "modified_at": null
        }
        """
        let data = json.data(using: .utf8)!
        let model = try JSONDecoder().decode(MockOllamaModel.self, from: data)

        XCTAssertEqual(model.sizeFormatted, "")
    }

    func testOllamaTagsResponseDecoding() throws {
        let json = """
        {
            "models": [
                {
                    "name": "nomic-embed-text:latest",
                    "size": 274302450,
                    "digest": "abc123",
                    "modified_at": "2024-01-15T10:30:00Z"
                },
                {
                    "name": "mxbai-embed-large:latest",
                    "size": 670000000,
                    "digest": "def456",
                    "modified_at": "2024-01-14T09:00:00Z"
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(MockOllamaTagsResponse.self, from: data)

        XCTAssertEqual(response.models.count, 2)
        XCTAssertEqual(response.models[0].name, "nomic-embed-text:latest")
        XCTAssertEqual(response.models[1].name, "mxbai-embed-large:latest")
    }

    func testOllamaModelHashable() throws {
        let json1 = """
        {"name": "model1", "size": null, "digest": null, "modified_at": null}
        """
        let json2 = """
        {"name": "model2", "size": null, "digest": null, "modified_at": null}
        """
        let model1 = try JSONDecoder().decode(MockOllamaModel.self, from: json1.data(using: .utf8)!)
        let model2 = try JSONDecoder().decode(MockOllamaModel.self, from: json2.data(using: .utf8)!)

        var set = Set<MockOllamaModel>()
        set.insert(model1)
        set.insert(model2)
        set.insert(model1)

        XCTAssertEqual(set.count, 2)
    }
}
