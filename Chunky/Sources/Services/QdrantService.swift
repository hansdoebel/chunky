import Foundation

actor QdrantService {
    private let qdrantUpPath: String
    private let qdrantURL: String
    private let apiKey: String
    private let timeout: Int
    private let poolSize: Int
    private let batchSize: Int
    private let compression: String
    private let dimensions: Int

    init(
        qdrantURL: String, apiKey: String, timeout: Int = 30, poolSize: Int = 3,
        batchSize: Int = 100, compression: String = "none", dimensions: Int = 768
    ) {
        let paths = [
            // Relative to app bundle (when running as .app)
            Bundle.main.bundlePath + "/../../../../qdrant-up/target/release/qdrant-up",
            // Common install locations
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/qdrant-up",
            FileManager.default.homeDirectoryForCurrentUser.path + "/bin/qdrant-up",
            "/usr/local/bin/qdrant-up",
            "/opt/homebrew/bin/qdrant-up",
            // Development: current directory
            FileManager.default.currentDirectoryPath + "/qdrant-up/target/release/qdrant-up",
        ]
        self.qdrantUpPath = paths.first { FileManager.default.fileExists(atPath: $0) } ?? paths[0]
        self.qdrantURL = QdrantService.normalizeURL(qdrantURL)
        self.apiKey = apiKey
        self.timeout = timeout
        self.poolSize = poolSize
        self.batchSize = batchSize
        self.compression = compression
        self.dimensions = dimensions
    }

    private static func normalizeURL(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        if parsed.port == nil {
            return url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ":6334"
        }
        return url
    }

    func upload(
        chunks: [ChunkWithEmbedding],
        collection: String,
        onProgress: @escaping (Int, Int) async -> Void
    ) async throws {
        print("[Qdrant] Starting upload of \(chunks.count) chunks to collection '\(collection)'")
        print("[Qdrant] URL: \(qdrantURL)")
        print("[Qdrant] Binary: \(qdrantUpPath)")
        print("[Qdrant] Dimensions: \(dimensions)")

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let input = QdrantInput(points: chunks)
        let data = try JSONEncoder().encode(input)
        try data.write(to: inputURL)
        print("[Qdrant] Wrote \(data.count) bytes to \(inputURL.path)")

        defer {
            try? FileManager.default.removeItem(at: inputURL)
        }

        guard FileManager.default.fileExists(atPath: qdrantUpPath) else {
            let error = "qdrant-up binary not found at: \(qdrantUpPath)"
            print("[Qdrant] ERROR: \(error)")
            throw QdrantError.uploadFailed(error)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qdrantUpPath)
        process.arguments = [
            "--url", qdrantURL,
            "--api-key", apiKey,
            "--collection", collection,
            "--input", inputURL.path,
            "--timeout", String(timeout),
            "--pool-size", String(poolSize),
            "--batch-size", String(batchSize),
            "--compression", compression,
            "--dimensions", String(dimensions),
        ]

        let safeArgs =
            process.arguments?.map { arg in
                arg == apiKey ? "[REDACTED]" : arg
            }.joined(separator: " ") ?? ""
        print("[Qdrant] Running: \(qdrantUpPath) \(safeArgs)")

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let outputHandle = outputPipe.fileHandleForReading
        for try await line in outputHandle.bytes.lines {
            print("[Qdrant] stdout: \(line)")
            if line.hasPrefix("progress:") {
                let json = String(line.dropFirst(9))
                if let data = json.data(using: .utf8),
                    let progress = try? JSONDecoder().decode(UploadProgress.self, from: data)
                {
                    await onProgress(progress.batch, progress.total)
                }
            }
        }

        process.waitUntilExit()
        print("[Qdrant] Process exited with status: \(process.terminationStatus)")

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: errorData, encoding: .utf8) ?? ""
        if !stderrOutput.isEmpty {
            print("[Qdrant] stderr: \(stderrOutput)")
        }

        guard process.terminationStatus == 0 else {
            let errorMessage =
                stderrOutput.isEmpty
                ? "Process exited with code \(process.terminationStatus)" : stderrOutput
            print("[Qdrant] ERROR: \(errorMessage)")
            throw QdrantError.uploadFailed(errorMessage)
        }

        print("[Qdrant] Upload completed successfully")
    }
}

struct UploadProgress: Codable {
    let batch: Int
    let total: Int
    let points: Int
}

enum QdrantError: Error, LocalizedError {
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let message):
            return "Qdrant upload failed: \(message)"
        }
    }
}
