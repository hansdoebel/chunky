import Foundation
import XCTest

/// End-to-end tests for the Chunky document processing pipeline.
/// These tests require:
/// - Ollama running locally with an embedding model (e.g., snowflake-arctic-embed2)
/// - Qdrant instance (cloud or local) with valid credentials
/// - Python environment with docling installed
///
/// Run with: cd Chunky/Tests && swift test --filter E2ETests
final class E2ETests: XCTestCase {

    // Configuration - loaded from UserDefaults (same as main app)
    var ollamaURL: String = "http://localhost:11434"
    var embeddingModel: String = "snowflake-arctic-embed2"
    var qdrantURL: String = ""
    var qdrantAPIKey: String = ""
    var testCollection: String = ""

    override func setUp() async throws {
        // Priority 1: Load from .env file
        loadEnvFile()

        // Priority 2: Environment variables (override .env)
        if let envOllama = ProcessInfo.processInfo.environment["OLLAMA_URL"] {
            ollamaURL = envOllama
        }
        if let envModel = ProcessInfo.processInfo.environment["EMBEDDING_MODEL"] {
            embeddingModel = envModel
        }
        if let envQdrant = ProcessInfo.processInfo.environment["QDRANT_URL"] {
            qdrantURL = envQdrant
        }
        if let envApiKey = ProcessInfo.processInfo.environment["QDRANT_API_KEY"] {
            qdrantAPIKey = envApiKey
        }

        // Priority 3: UserDefaults (from main app)
        if qdrantURL.isEmpty || qdrantAPIKey.isEmpty {
            if let data = UserDefaults.standard.data(forKey: "appSettings"),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                if ollamaURL == "http://localhost:11434" {
                    ollamaURL = json["ollamaURL"] as? String ?? ollamaURL
                }
                if embeddingModel == "snowflake-arctic-embed2" {
                    embeddingModel = json["embeddingModel"] as? String ?? embeddingModel
                }
                if qdrantURL.isEmpty {
                    qdrantURL = json["qdrantURL"] as? String ?? ""
                }
            }

            // Load API key from Keychain if not set via env
            if qdrantAPIKey.isEmpty {
                qdrantAPIKey = loadFromKeychain(key: "qdrantAPIKey") ?? ""
            }
        }

        // Create unique test collection name
        testCollection = "chunky_e2e_test_\(Int(Date().timeIntervalSince1970))"

        print("=== E2E Test Configuration ===")
        print("Ollama URL: \(ollamaURL)")
        print("Embedding Model: \(embeddingModel)")
        print("Qdrant URL: \(qdrantURL.isEmpty ? "(not set)" : qdrantURL)")
        print("Qdrant API Key: \(qdrantAPIKey.isEmpty ? "(not set)" : "[REDACTED]")")
        print("Test Collection: \(testCollection)")
        print("==============================")
    }

    private func loadEnvFile() {
        // Look for .env in Tests directory or project root
        let envPaths = [
            URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent(".env"),
            URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".env"),
        ]

        for envPath in envPaths {
            if let contents = try? String(contentsOf: envPath, encoding: .utf8) {
                print("Loading .env from: \(envPath.path)")
                parseEnvFile(contents)
                return
            }
        }
    }

    private func parseEnvFile(_ contents: String) {
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Remove surrounding quotes if present
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }

            switch key {
            case "OLLAMA_URL":
                ollamaURL = value
            case "EMBEDDING_MODEL":
                embeddingModel = value
            case "QDRANT_URL":
                qdrantURL = value
            case "QDRANT_API_KEY":
                qdrantAPIKey = value
            default:
                break
            }
        }
    }

    // MARK: - Ollama Tests

    func testOllamaConnection() async throws {
        let url = URL(string: "\(ollamaURL)/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        XCTAssertEqual(httpResponse?.statusCode, 200, "Ollama should respond with 200")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["models"] as? [[String: Any]] ?? []

        XCTAssertFalse(models.isEmpty, "Ollama should have at least one model")
        print("Available models: \(models.compactMap { $0["name"] as? String })")
    }

    func testOllamaEmbedding() async throws {
        let url = URL(string: "\(ollamaURL)/api/embed")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": embeddingModel,
            "input": ["Hello world", "This is a test"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        XCTAssertEqual(httpResponse?.statusCode, 200, "Embedding request should succeed")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let embeddings = json?["embeddings"] as? [[Double]] ?? []

        XCTAssertEqual(embeddings.count, 2, "Should return 2 embeddings")
        XCTAssertGreaterThan(embeddings[0].count, 0, "Embeddings should have dimensions")

        print("Embedding dimensions: \(embeddings[0].count)")
    }

    // MARK: - Qdrant Tests

    func testQdrantConnection() async throws {
        try skipIfQdrantNotConfigured()

        let normalizedURL = normalizeQdrantURL(qdrantURL)
        guard let url = URL(string: normalizedURL) else {
            XCTFail("Invalid Qdrant URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(qdrantAPIKey, forHTTPHeaderField: "api-key")

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        XCTAssertNotNil(httpResponse, "Should receive HTTP response from Qdrant")
        print("Qdrant responded with status: \(httpResponse?.statusCode ?? 0)")
    }

    // MARK: - Chunking Tests (Python subprocess)

    func testChunkingWithPython() async throws {
        let fixtureURL = try getFixtureURL("sample.pdf")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        // Find Python and script
        let pythonPath = findPython()
        let scriptPath = findChunkerScript()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pythonPath), "Python not found at \(pythonPath)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scriptPath),
            "Chunker script not found at \(scriptPath)")

        print("Using Python: \(pythonPath)")
        print("Using script: \(scriptPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            "--input", fixtureURL.path,
            "--output", outputURL.path,
            "--max-tokens", "512",
            "--model", "default",
            "--workers", "2",
            "--accelerator", "cpu",
            "--timeout", "120",
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""
        print("Chunker stderr: \(stderrOutput)")

        XCTAssertEqual(process.terminationStatus, 0, "Chunking should succeed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path), "Output file should exist")

        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let chunks = json?["chunks"] as? [[String: Any]] ?? []

        XCTAssertFalse(chunks.isEmpty, "Should produce at least one chunk")
        print("Produced \(chunks.count) chunks")

        // Cleanup
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Full Pipeline Test

    func testFullPipeline() async throws {
        try skipIfQdrantNotConfigured()

        let fixtureURL = try getFixtureURL("sample.pdf")

        print("\n=== STEP 1: Chunking ===")
        let chunks = try await runChunking(inputURL: fixtureURL)
        XCTAssertFalse(chunks.isEmpty, "Should produce chunks")
        print("Produced \(chunks.count) chunks")

        print("\n=== STEP 2: Embedding ===")
        let texts = chunks.compactMap { $0["text"] as? String }
        let embeddings = try await runEmbedding(texts: texts)
        XCTAssertEqual(embeddings.count, texts.count, "Should have embedding per chunk")
        print("Generated \(embeddings.count) embeddings of dimension \(embeddings[0].count)")

        print("\n=== STEP 3: Upload to Qdrant ===")
        try await runQdrantUpload(
            chunks: chunks, embeddings: embeddings, collection: testCollection)
        print("Uploaded to collection: \(testCollection)")

        print("\n=== PIPELINE COMPLETE ===")
        print("Test collection '\(testCollection)' created - delete manually if needed")
    }

    // MARK: - Helper Methods

    private func skipIfQdrantNotConfigured() throws {
        try XCTSkipIf(qdrantURL.isEmpty, "Qdrant URL not configured")
        try XCTSkipIf(qdrantAPIKey.isEmpty, "Qdrant API key not configured")
    }

    private func getFixtureURL(_ filename: String) throws -> URL {
        // Try relative path from source file
        let testDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fixtureURL = testDir.appendingPathComponent("Fixtures").appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            return fixtureURL
        }

        // Try from current directory
        let cwdFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: cwdFixture.path) {
            return cwdFixture
        }

        throw NSError(
            domain: "E2ETests", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Fixture not found: \(filename). Place sample.pdf in Tests/Fixtures/"
            ])
    }

    private func findPython() -> String {
        let paths = [
            FileManager.default.currentDirectoryPath + "/../../.venv/bin/python3",
            URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().path + "/.venv/bin/python3",
            "/usr/bin/python3",
            "/usr/local/bin/python3",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3"
    }

    private func findChunkerScript() -> String {
        let paths = [
            FileManager.default.currentDirectoryPath + "/../../scripts/chunker.py",
            URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().path + "/scripts/chunker.py",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "chunker.py"
    }

    private func normalizeQdrantURL(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        if parsed.port == nil {
            return url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ":6334"
        }
        return url
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.chunky.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    private func runChunking(inputURL: URL) async throws -> [[String: Any]] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: findPython())
        process.arguments = [
            findChunkerScript(),
            "--input", inputURL.path,
            "--output", outputURL.path,
            "--max-tokens", "512",
            "--model", "default",
            "--workers", "2",
            "--accelerator", "cpu",
            "--timeout", "120",
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "E2ETests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Chunking failed"])
        }

        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try? FileManager.default.removeItem(at: outputURL)

        return json?["chunks"] as? [[String: Any]] ?? []
    }

    private func runEmbedding(texts: [String]) async throws -> [[Double]] {
        let url = URL(string: "\(ollamaURL)/api/embed")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": embeddingModel,
            "input": texts,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        return json?["embeddings"] as? [[Double]] ?? []
    }

    private func runQdrantUpload(
        chunks: [[String: Any]], embeddings: [[Double]], collection: String
    ) async throws {
        // Find qdrant-up binary
        let binaryPaths = [
            FileManager.default.homeDirectoryForCurrentUser.path + "/bin/qdrant-up",
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/qdrant-up",
            "/usr/local/bin/qdrant-up",
        ]

        guard
            let binaryPath = binaryPaths.first(where: { FileManager.default.fileExists(atPath: $0) }
            )
        else {
            throw NSError(
                domain: "E2ETests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "qdrant-up binary not found"])
        }

        // Create input JSON
        var points: [[String: Any]] = []
        for (index, chunk) in chunks.enumerated() {
            points.append([
                "id": UUID().uuidString,
                "vector": embeddings[index],
                "payload": [
                    "text": chunk["text"] ?? "",
                    "source": chunk["source"] ?? "",
                    "page": chunk["page"] ?? 0,
                ],
            ])
        }

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let inputData = try JSONSerialization.data(withJSONObject: ["points": points])
        try inputData.write(to: inputURL)

        defer { try? FileManager.default.removeItem(at: inputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "--url", normalizeQdrantURL(qdrantURL),
            "--api-key", qdrantAPIKey,
            "--collection", collection,
            "--input", inputURL.path,
            "--dimensions", String(embeddings[0].count),
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            print("qdrant-up stderr: \(stderrOutput)")
            throw NSError(
                domain: "E2ETests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Qdrant upload failed: \(stderrOutput)"])
        }
    }
}
