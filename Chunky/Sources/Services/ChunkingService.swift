import Foundation

actor ChunkingService {
    private let pythonPath: String
    private let scriptsPath: String

    init() {
        // Find Python: prefer venv in project root, then system python3
        let possibleVenvPaths = [
            // Relative to app bundle (when running as .app)
            Bundle.main.bundlePath + "/../../../../.venv/bin/python3",
            // Common development locations
            FileManager.default.currentDirectoryPath + "/.venv/bin/python3",
            // Home directory based venv
            NSHomeDirectory() + "/chunky/.venv/bin/python3",
        ]

        self.pythonPath =
            possibleVenvPaths.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/bin/python3"

        // Find chunker.py: prefer bundled, then look in common locations
        if let bundledPath = Bundle.main.path(forResource: "chunker", ofType: "py") {
            self.scriptsPath = bundledPath
        } else {
            let possibleScriptPaths = [
                FileManager.default.currentDirectoryPath + "/scripts/chunker.py",
                Bundle.main.bundlePath + "/../../../../scripts/chunker.py",
            ]
            self.scriptsPath =
                possibleScriptPaths.first { FileManager.default.fileExists(atPath: $0) }
                ?? "chunker.py"
        }
    }

    struct Options {
        var maxTokens: Int = 512
        var model: String = "default"
        var workers: Int = 4
        var accelerator: String = "auto"
        var timeout: Int = 300
        var maxPages: Int = 0
        var doTableExtraction: Bool = true
        var tableMode: String = "accurate"
        var doOCR: Bool = false
        var exportFormat: String = "none"
        var exportFolder: String = ""
    }

    func chunk(documentURL: URL, options: Options) async throws -> [Chunk] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        var arguments = [
            scriptsPath,
            "--input", documentURL.path,
            "--output", outputURL.path,
            "--max-tokens", String(options.maxTokens),
            "--model", options.model,
            "--workers", String(options.workers),
            "--accelerator", options.accelerator,
            "--timeout", String(options.timeout),
            "--table-mode", options.tableMode,
            "--export-format", options.exportFormat,
        ]

        if options.maxPages > 0 {
            arguments += ["--max-pages", String(options.maxPages)]
        }

        if options.doTableExtraction {
            arguments.append("--tables")
        } else {
            arguments.append("--no-tables")
        }

        if options.doOCR {
            arguments.append("--ocr")
        }

        if !options.exportFolder.isEmpty {
            arguments += ["--export-folder", options.exportFolder]
        }

        print("[Chunky] Python path: \(pythonPath)")
        print("[Chunky] Script path: \(scriptsPath)")
        print("[Chunky] Arguments: \(arguments.joined(separator: " "))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        try process.run()

        // Wait for process in a non-blocking way
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderrOutput.isEmpty {
            print("[Chunky] Python stderr: \(stderrOutput)")
        }

        guard process.terminationStatus == 0 else {
            throw ChunkingError.processFailed(
                stderrOutput.isEmpty
                    ? "Process exited with code \(process.terminationStatus)" : stderrOutput)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ChunkingError.processFailed("Output file not created. Stderr: \(stderrOutput)")
        }

        let data = try Data(contentsOf: outputURL)
        let output = try JSONDecoder().decode(ChunkerOutput.self, from: data)

        try? FileManager.default.removeItem(at: outputURL)

        print("[Chunky] Successfully chunked into \(output.chunks.count) pieces")
        return output.chunks
    }
}

enum ChunkingError: Error, LocalizedError {
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let message):
            return "Chunking failed: \(message)"
        }
    }
}
