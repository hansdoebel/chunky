import Foundation

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

actor DoclingService {

    // MARK: - Types

    struct PythonChunk: Codable, Sendable {
        let text: String
        let embeddingText: String
        let page: Int?
        let headings: [String]?
        let contentType: String?
        let chunkIndex: Int
        let tokenCount: Int

        enum CodingKeys: String, CodingKey {
            case text
            case embeddingText = "embedding_text"
            case page, headings
            case contentType = "content_type"
            case chunkIndex = "chunk_index"
            case tokenCount = "token_count"
        }
    }

    struct ConversionResult: Codable, Sendable {
        let success: Bool
        let inputFile: String?
        let outputFile: String?
        let outputFormat: String?
        let pageCount: Int?
        let textItemsCount: Int?
        let tableCount: Int?
        let error: String?
        let errorType: String?
        let extractionOutput: String?
        let extractionCount: Int?
        let chunks: [PythonChunk]?
        let docTitle: String?
        let authors: [String]?
        let doi: String?
        let docURL: String?
        let year: Int?
        let language: String?

        enum CodingKeys: String, CodingKey {
            case success
            case inputFile = "input_file"
            case outputFile = "output_file"
            case outputFormat = "output_format"
            case pageCount = "page_count"
            case textItemsCount = "text_items_count"
            case tableCount = "table_count"
            case error
            case errorType = "error_type"
            case extractionOutput = "extraction_output"
            case extractionCount = "extraction_count"
            case chunks
            case docTitle = "doc_title"
            case authors
            case doi
            case docURL = "doc_url"
            case year
            case language
        }
    }

    struct ProgressUpdate: Codable, Sendable {
        let type: String
        let message: String
        let percent: Double?
    }

    enum OutputFormat: String, Sendable {
        case json
        case markdown
        case markdownNoImages = "markdown_no_images"
        case markdownWithImages = "markdown_with_images"
        case text
        case doctags
        case html
    }

    enum TableMode: String, Sendable {
        case fast
        case accurate
    }

    enum Accelerator: String, Sendable {
        case auto, cpu, mps, cuda
    }

    enum ImageExportMode: String, Sendable {
        case embedded
        case placeholder
        case referenced
    }

    struct ConversionOptions: Sendable {
        var outputDir: URL?
        var format: OutputFormat = .json
        var maxPages: Int?
        var enableOCR: Bool = false
        var ocrLanguage: String = "de"
        var doTableExtraction: Bool = true
        var tableMode: TableMode = .fast
        var accelerator: Accelerator = .cpu
        var vlmModel: String = "standard"
        var ollamaURL: String = "http://localhost:11434"
        var generateImages: Bool = false
        var imageExportMode: ImageExportMode = .embedded
        var doFormulaEnrichment: Bool = false
        var doCodeEnrichment: Bool = false
        var doChartExtraction: Bool = false
        var doPictureDescription: Bool = false
        var doPictureClassification: Bool = false
        var inputFormat: String?
        var extractionSchemaPath: String?
        var layoutModel: String = "default"
        var workers: Int = 2
        var timeout: Int = 120
        var pythonPath: String = "~/.chunky-venv/bin/python3".expandingTildeInPath
        var enableChunking: Bool = false
        var chunkMaxTokens: Int = 512
        var chunkMergePeers: Bool = true
        var chunkTokenizer: String = ""
        var useDaemon: Bool = true

        init() {}
    }

    enum DoclingError: LocalizedError, Sendable {
        case pythonNotFound
        case scriptNotFound
        case conversionFailed(String)
        case invalidOutput
        case cancelled

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "Python 3 not found. Please install Python 3.10+ and docling."
            case .scriptNotFound:
                return "Docling conversion script not found in bundle."
            case .conversionFailed(let message):
                return "Document conversion failed: \(message)"
            case .invalidOutput:
                return "Invalid output from docling conversion."
            case .cancelled:
                return "Conversion was cancelled."
            }
        }
    }

    // MARK: - Properties

    private var currentTask: Process?
    private let scriptName = "docling_convert.py"
    private let daemonScriptName = "docling_daemon.py"

    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var daemonStdout: FileHandle?
    private var daemonStderr: FileHandle?
    private var isDaemonReady: Bool = false
    private var daemonStartTask: Task<Void, Error>?
    private var daemonConvertQueue: [CheckedContinuation<ConversionResult, Error>] = []
    private var isDaemonBusy: Bool = false

    // MARK: - Daemon Management

    func ensureDaemonReady(pythonPath: String = "~/.chunky-venv/bin/python3".expandingTildeInPath) async throws {
        if isDaemonRunning { return }

        if let existingTask = daemonStartTask {
            try await existingTask.value
            return
        }

        let task = Task { [self] in
            try await self.startDaemon(pythonPath: pythonPath)
        }
        daemonStartTask = task

        do {
            try await task.value
        } catch {
            daemonStartTask = nil
            throw error
        }
        daemonStartTask = nil
    }

    private func startDaemon(pythonPath: String) async throws {
        if daemonProcess != nil && daemonProcess!.isRunning {
            daemonProcess!.terminate()
        }

        isDaemonReady = false

        let scriptPath = try findScript(named: daemonScriptName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonPath, scriptPath]

        var environment = ProcessInfo.processInfo.environment
        environment["OMP_NUM_THREADS"] = "4"
        environment["PYTHONPATH"] = (scriptPath as NSString).deletingLastPathComponent
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        daemonProcess = process
        daemonStdin = stdinPipe.fileHandleForWriting
        daemonStdout = stdoutPipe.fileHandleForReading
        daemonStderr = stderrPipe.fileHandleForReading

        let readyLine = try await waitForDaemonReady(stdoutHandle: stdoutPipe.fileHandleForReading, timeout: 60)
        if let data = readyLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["type"] as? String == "ready" {
            isDaemonReady = true
        } else {
            stopDaemon()
            throw DoclingError.conversionFailed("Daemon failed to start")
        }
    }

    func stopDaemon() {
        if let stdin = daemonStdin {
            let shutdownCmd = "{\"command\": \"shutdown\"}\n"
            if let data = shutdownCmd.data(using: .utf8) {
                try? stdin.write(contentsOf: data)
            }
        }
        daemonProcess?.terminate()
        daemonProcess = nil
        daemonStdin = nil
        daemonStdout = nil
        daemonStderr = nil
        isDaemonReady = false
    }

    var isDaemonRunning: Bool {
        daemonProcess?.isRunning == true && isDaemonReady
    }

    private nonisolated func waitForDaemonReady(stdoutHandle: FileHandle, timeout: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue.global()
            var resumed = false
            let lock = NSLock()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler {
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: DoclingError.conversionFailed("Daemon startup timed out"))
                }
            }
            timer.schedule(wallDeadline: .now() + .seconds(timeout))
            timer.resume()

            queue.async {
                var buffer = ""
                while true {
                    let data = stdoutHandle.availableData
                    guard !data.isEmpty else { break }
                    if let str = String(data: data, encoding: .utf8) {
                        buffer += str
                        if buffer.contains("\n") {
                            let lines = buffer.components(separatedBy: "\n")
                            if let firstLine = lines.first, !firstLine.isEmpty {
                                timer.cancel()
                                lock.lock()
                                defer { lock.unlock() }
                                if !resumed {
                                    resumed = true
                                    continuation.resume(returning: firstLine)
                                }
                                return
                            }
                        }
                    }
                }
                timer.cancel()
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: DoclingError.conversionFailed("Daemon process ended before ready"))
                }
            }
        }
    }

    // MARK: - Public Methods

    func convert(
        inputURL: URL,
        options: ConversionOptions = ConversionOptions(),
        onProgress: (@Sendable (String, Double?) -> Void)? = nil
    ) async throws -> ConversionResult {

        if options.useDaemon {
            return try await convertViaDaemon(inputURL: inputURL, options: options, onProgress: onProgress)
        }
        return try await convertViaSubprocess(inputURL: inputURL, options: options, onProgress: onProgress)
    }

    func cancel() {
        currentTask?.terminate()
        currentTask = nil
    }

    func checkInstallation(pythonPath: String = "python3") async -> (installed: Bool, version: String?) {
        do {
            let (stdout, _) = try await runPython(
                path: pythonPath,
                arguments: ["-c", "import docling; print(docling.__version__)"],
                onStderr: nil
            )
            let version = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, version.isEmpty ? nil : version)
        } catch {
            return (false, nil)
        }
    }

    // MARK: - Daemon Conversion

    private func buildDaemonCommand(inputURL: URL, options: ConversionOptions) throws -> Data {
        var cmd: [String: Any] = [
            "command": "convert",
            "input": inputURL.path,
            "format": options.format.rawValue,
            "accelerator": options.accelerator.rawValue,
            "image_export_mode": options.imageExportMode.rawValue,
            "workers": options.workers,
        ]

        if let outputDir = options.outputDir { cmd["output_dir"] = outputDir.path }
        if let maxPages = options.maxPages { cmd["max_pages"] = maxPages }
        if options.enableOCR {
            cmd["enable_ocr"] = true
            cmd["ocr_language"] = options.ocrLanguage
        }
        if options.doTableExtraction {
            cmd["table_mode"] = options.tableMode.rawValue
        } else {
            cmd["no_tables"] = true
        }
        if options.vlmModel != "standard" {
            cmd["vlm_model"] = options.vlmModel
            cmd["ollama_url"] = options.ollamaURL
        }
        if options.generateImages { cmd["generate_images"] = true }
        if options.doFormulaEnrichment { cmd["do_formula_enrichment"] = true }
        if options.doCodeEnrichment { cmd["do_code_enrichment"] = true }
        if options.doChartExtraction { cmd["do_chart_extraction"] = true }
        if options.doPictureDescription { cmd["do_picture_description"] = true }
        if options.doPictureClassification { cmd["do_picture_classification"] = true }
        if let inputFormat = options.inputFormat { cmd["input_format"] = inputFormat }
        if options.layoutModel != "default" { cmd["layout_model"] = options.layoutModel }
        if let schemaPath = options.extractionSchemaPath { cmd["extract_schema"] = schemaPath }
        if options.enableChunking {
            cmd["chunk"] = true
            cmd["chunk_max_tokens"] = options.chunkMaxTokens
            cmd["chunk_merge_peers"] = options.chunkMergePeers
            if !options.chunkTokenizer.isEmpty { cmd["chunk_tokenizer"] = options.chunkTokenizer }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: cmd)
        let jsonStr = String(data: jsonData, encoding: .utf8)! + "\n"
        return jsonStr.data(using: .utf8)!
    }

    private func convertViaDaemon(
        inputURL: URL,
        options: ConversionOptions,
        onProgress: (@Sendable (String, Double?) -> Void)?
    ) async throws -> ConversionResult {
        if !isDaemonRunning {
            try await ensureDaemonReady(pythonPath: options.pythonPath)
        }

        guard let stdinHandle = daemonStdin, let stdoutHandle = daemonStdout, let stderrHandle = daemonStderr else {
            return try await convertViaSubprocess(inputURL: inputURL, options: options, onProgress: onProgress)
        }

        let cmdData = try buildDaemonCommand(inputURL: inputURL, options: options)

        while isDaemonBusy {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        isDaemonBusy = true

        let progressCallback = onProgress

        defer { isDaemonBusy = false }

        if progressCallback != nil {
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                    for line in string.components(separatedBy: .newlines) where !line.isEmpty {
                        if let lineData = line.data(using: .utf8),
                           let progress = try? JSONDecoder().decode(ProgressUpdate.self, from: lineData) {
                            progressCallback?(progress.message, progress.percent)
                        }
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue.global()
            var resumed = false
            let lock = NSLock()

            func safeResume(_ result: Result<ConversionResult, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                stderrHandle.readabilityHandler = nil
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            queue.async {
                stdinHandle.write(cmdData)

                var buffer = ""
                while true {
                    let data = stdoutHandle.availableData
                    guard !data.isEmpty else {
                        safeResume(.failure(DoclingError.conversionFailed("Daemon process ended unexpectedly")))
                        return
                    }
                    guard let str = String(data: data, encoding: .utf8) else { continue }
                    buffer += str

                    guard let newlineRange = buffer.range(of: "\n") else { continue }

                    let responseLine = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    guard !responseLine.isEmpty else {
                        buffer = String(buffer[newlineRange.upperBound...])
                        continue
                    }

                    guard let responseData = responseLine.data(using: .utf8) else {
                        safeResume(.failure(DoclingError.invalidOutput))
                        return
                    }

                    do {
                        let result = try JSONDecoder().decode(ConversionResult.self, from: responseData)
                        if !result.success, let error = result.error {
                            safeResume(.failure(DoclingError.conversionFailed(error)))
                        } else {
                            safeResume(.success(result))
                        }
                    } catch {
                        safeResume(.failure(DoclingError.conversionFailed("Failed to parse daemon response: \(responseLine.prefix(500))")))
                    }
                    return
                }
            }
        }
    }

    // MARK: - Subprocess Conversion (fallback)

    private func convertViaSubprocess(
        inputURL: URL,
        options: ConversionOptions,
        onProgress: (@Sendable (String, Double?) -> Void)?
    ) async throws -> ConversionResult {
        let scriptPath = try findScript(named: scriptName)

        var arguments = [scriptPath, inputURL.path]

        if let outputDir = options.outputDir {
            arguments.append(contentsOf: ["--output-dir", outputDir.path])
        }

        arguments.append(contentsOf: ["--format", options.format.rawValue])

        if let maxPages = options.maxPages {
            arguments.append(contentsOf: ["--max-pages", String(maxPages)])
        }

        if options.enableOCR {
            arguments.append("--ocr")
            arguments.append(contentsOf: ["--ocr-lang", options.ocrLanguage])
        }

        if options.doTableExtraction {
            arguments.append(contentsOf: ["--table-mode", options.tableMode.rawValue])
        } else {
            arguments.append("--no-tables")
        }
        arguments.append(contentsOf: ["--accelerator", options.accelerator.rawValue])

        if options.vlmModel != "standard" {
            arguments.append(contentsOf: ["--vlm-model", options.vlmModel])
            arguments.append(contentsOf: ["--ollama-url", options.ollamaURL])
        }

        if options.generateImages {
            arguments.append("--generate-images")
        }

        arguments.append(contentsOf: ["--image-export-mode", options.imageExportMode.rawValue])

        if options.doFormulaEnrichment { arguments.append("--do-formula-enrichment") }
        if options.doCodeEnrichment { arguments.append("--do-code-enrichment") }
        if options.doChartExtraction { arguments.append("--do-chart-extraction") }
        if options.doPictureDescription { arguments.append("--do-picture-description") }
        if options.doPictureClassification { arguments.append("--do-picture-classification") }

        if let inputFormat = options.inputFormat {
            arguments.append(contentsOf: ["--input-format", inputFormat])
        }

        if options.layoutModel != "default" {
            arguments.append(contentsOf: ["--layout-model", options.layoutModel])
        }

        if let schemaPath = options.extractionSchemaPath {
            arguments.append(contentsOf: ["--extract-schema", schemaPath])
        }

        if options.workers > 1 {
            arguments.append(contentsOf: ["--workers", String(options.workers)])
        }

        if options.enableChunking {
            arguments.append("--chunk")
            arguments.append(contentsOf: ["--chunk-max-tokens", String(options.chunkMaxTokens)])
            if !options.chunkTokenizer.isEmpty {
                arguments.append(contentsOf: ["--chunk-tokenizer", options.chunkTokenizer])
            }
            if !options.chunkMergePeers {
                arguments.append("--no-chunk-merge-peers")
            }
        }

        if onProgress != nil {
            arguments.append("--progress")
        }

        let (stdout, _) = try await runPython(
            path: options.pythonPath,
            arguments: arguments,
            timeout: options.timeout,
            onStderr: { line in
                if let data = line.data(using: .utf8),
                   let progress = try? JSONDecoder().decode(ProgressUpdate.self, from: data) {
                    onProgress?(progress.message, progress.percent)
                }
            }
        )

        guard let data = stdout.data(using: .utf8) else {
            throw DoclingError.invalidOutput
        }

        let result = try JSONDecoder().decode(ConversionResult.self, from: data)

        if !result.success, let error = result.error {
            throw DoclingError.conversionFailed(error)
        }

        return result
    }

    // MARK: - Private Methods

    private func findScript(named name: String = "docling_convert.py") throws -> String {
        let baseName = (name as NSString).deletingPathExtension

        if let bundlePath = Bundle.main.path(forResource: baseName, ofType: "py") {
            return bundlePath
        }

        if let resourcePath = Bundle.main.resourcePath {
            let scriptPath = (resourcePath as NSString).appendingPathComponent("Scripts/\(name)")
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }

        let fileManager = FileManager.default

        if let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            var searchDir = executableDir
            for _ in 0..<10 {
                let projectFile = (searchDir as NSString).appendingPathComponent("Chunky.xcodeproj")
                if fileManager.fileExists(atPath: projectFile) {
                    let scriptPath = (searchDir as NSString).appendingPathComponent("Chunky/Resources/Scripts/\(name)")
                    if fileManager.fileExists(atPath: scriptPath) {
                        return scriptPath
                    }
                }
                searchDir = (searchDir as NSString).deletingLastPathComponent
            }
        }

        let devPaths = [
            "Chunky/Resources/Scripts/\(name)",
            "../Chunky/Resources/Scripts/\(name)",
            "Resources/Scripts/\(name)"
        ]

        for path in devPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        throw DoclingError.scriptNotFound
    }

    private nonisolated func runPython(
        path: String,
        arguments: [String],
        timeout: Int = 0,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> (stdout: String, stderr: String) {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["OMP_NUM_THREADS"] = "4"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class OutputCapture: @unchecked Sendable {
            var stderr: String = ""
            let lock = NSLock()

            func append(_ string: String) {
                lock.lock()
                stderr += string
                lock.unlock()
            }

            func get() -> String {
                lock.lock()
                defer { lock.unlock() }
                return stderr
            }
        }

        let capture = OutputCapture()

        if let onStderr = onStderr {
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                    capture.append(string)
                    for line in string.components(separatedBy: .newlines) where !line.isEmpty {
                        onStderr(line)
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()

                var timeoutSource: DispatchSourceTimer?
                if timeout > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                    timer.setEventHandler {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                    timer.schedule(wallDeadline: .now() + .seconds(timeout))
                    timer.resume()
                    timeoutSource = timer
                }

                process.terminationHandler = { proc in
                    timeoutSource?.cancel()
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""

                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingStderr = String(data: stderrData, encoding: .utf8) ?? ""

                    var stderrOutput = capture.get()
                    if !remainingStderr.isEmpty {
                        stderrOutput += remainingStderr
                    }

                    if !stdoutString.isEmpty {
                        continuation.resume(returning: (stdoutString, stderrOutput))
                    } else if proc.terminationStatus != 0 {
                        let errorMessage = stderrOutput.isEmpty ? "Unknown error" : stderrOutput
                        continuation.resume(throwing: DoclingError.conversionFailed(
                            "Process exited with code \(proc.terminationStatus): \(errorMessage)"
                        ))
                    } else {
                        continuation.resume(throwing: DoclingError.invalidOutput)
                    }
                }
            } catch {
                continuation.resume(throwing: DoclingError.pythonNotFound)
            }
        }
    }
}

// MARK: - Convenience Extensions

extension DoclingService {

    func convertToFile(
        inputURL: URL,
        outputDir: URL,
        format: OutputFormat = .json,
        maxPages: Int? = nil,
        enableOCR: Bool = false,
        tableMode: TableMode = .fast,
        onProgress: (@Sendable (String, Double?) -> Void)? = nil
    ) async throws -> URL {
        var options = ConversionOptions()
        options.outputDir = outputDir
        options.format = format
        options.maxPages = maxPages
        options.enableOCR = enableOCR
        options.tableMode = tableMode

        let result = try await convert(inputURL: inputURL, options: options, onProgress: onProgress)

        guard let outputPath = result.outputFile else {
            throw DoclingError.invalidOutput
        }

        return URL(fileURLWithPath: outputPath)
    }
}
