import Foundation

nonisolated final class FastEmbedService: @unchecked Sendable {
    static let shared = FastEmbedService()
    static let model = "minishlab/potion-retrieval-32M"
    static let dimensions = 512
    private let pythonPath: String?
    private let scriptPath: String?

    init(pythonPath: String? = nil, scriptPath: String? = nil) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
    }

    private let queue = DispatchQueue(label: "chunky.fastembed")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning == true { process?.terminate() }
    }

    func health(model: String) async throws -> String {
        let result = try await request(["command": "health", "model": model])
        return result["status"] as? String ?? "Not ready"
    }

    func prepare(model: String) async throws {
        _ = try await request(["command": "prepare", "model": model])
    }

    func embed(texts: [String], model: String, query: Bool = false, rejectTruncation: Bool = false) async throws -> [[Float]] {
        guard model == Self.model else { throw failure("Select \(Self.model) for local CPU embeddings.") }
        if texts.isEmpty { return [] }
        var payload: [String: Any] = ["command": "embed", "model": model, "texts": texts, "query": query]
        if rejectTruncation { payload["reject_truncation"] = true }
        let result = try await request(payload)
        guard !rejectTruncation || result["untruncated"] as? Bool == true else {
            throw failure("The CPU embedding process did not confirm complete input tokenization. Restart the app with the updated helper before Cloud import.")
        }
        guard result["model"] as? String == model,
              result["dimensions"] as? Int == Self.dimensions,
              let vectors = result["vectors"] as? [[NSNumber]], vectors.count == texts.count,
              vectors.allSatisfy({ $0.count == Self.dimensions && $0.allSatisfy { $0.doubleValue.isFinite && $0.floatValue.isFinite } }) else {
            throw failure("Invalid local CPU model identity or vector dimensions. Refusing to index or search.")
        }
        return vectors.map { $0.map(\.floatValue) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Chunky.FastEmbed", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning == true { return }
        let python = pythonPath ?? ("~/.chunky-venv/bin/python3" as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: python) else { throw failure("Run make setup-venv to install the local CPU runtime.") }
        let candidates = [
            scriptPath,
            Bundle.main.path(forResource: "fastembed_daemon", ofType: "py"),
            Bundle.main.resourcePath.map { $0 + "/Scripts/fastembed_daemon.py" },
            FileManager.default.currentDirectoryPath + "/Chunky/Resources/Scripts/fastembed_daemon.py"
        ].compactMap { $0 }
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw failure("The local CPU embedding script is missing. Rebuild Chunky.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-u", script]
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private func reset() {
        lock.lock()
        let child = process
        process = nil
        let writer = input
        let reader = output
        input = nil
        output = nil
        lock.unlock()
        if child?.isRunning == true { child?.terminate() }
        child?.waitUntilExit()
        try? writer?.close()
        try? reader?.close()
    }

    nonisolated private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var child: Process?

        func begin(_ process: Process?) throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            child = process
        }

        func finish() {
            lock.lock()
            child = nil
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if child?.isRunning == true { child?.terminate() }
        }
    }

    private func request(_ body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body) + Data([10])
        let state = RequestState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
            let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try state.begin(nil)
                        try self.start()
                        try state.begin(self.process)
                        defer { state.finish() }
                        let timeout = DispatchWorkItem { state.cancel() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
                        defer { timeout.cancel() }
                        try self.input?.write(contentsOf: data)
                        var line = Data()
                        while let byte = try self.output?.read(upToCount: 1), !byte.isEmpty {
                            if byte == Data([10]) { break }
                            line.append(byte)
                        }
                        guard let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                            throw self.failure("Local CPU runtime exited unexpectedly. Check make setup-venv.")
                        }
                        if let error = result["error"] as? String { throw self.failure(error) }
                        continuation.resume(returning: result)
                    } catch {
                        self.reset()
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { state.cancel() }
    }
}
