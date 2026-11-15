import Foundation

nonisolated enum PiSessionError: LocalizedError, Equatable {
    case terminated
    case piUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .terminated:
            return "pi was stopped"
        case .piUnavailable(let message):
            return message
        }
    }
}

nonisolated final class PiChatSession: @unchecked Sendable {
    private let lock = NSLock()
    private let ensureLock = NSLock()
    private let toolMode: PiToolMode
    private let locate: (() -> PiInstallReport)?
    private let transportFactory: () -> any PiByteStream
    private let environment: () -> [String: String]
    private var transport: (any PiByteStream)?
    private var client: PiRPCClient?
    private var accepting = true
    private var currentOverride = ""
    private var selectedModel = ""
    private var launchedExecutable: String?
    private var launchedOverride: String?

    init(
        toolMode: PiToolMode = .none,
        locate: (() -> PiInstallReport)? = nil,
        transportFactory: @escaping () -> any PiByteStream = { FoundationPiTransport() },
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.toolMode = toolMode
        self.locate = locate
        self.transportFactory = transportFactory
        self.environment = environment
    }

    func setOverridePath(_ path: String) {
        lock.lock()
        currentOverride = path
        lock.unlock()
    }

    func use(model: String) {
        lock.lock()
        selectedModel = model
        lock.unlock()
    }

    func report() -> PiInstallReport {
        if let locate {
            return locate()
        }
        lock.lock()
        let override = currentOverride
        lock.unlock()
        return PiLocator.live(overridePath: override)
    }

    func availableModels() async throws -> [PiModel] {
        try await withRestart {
            let client = try self.ensureClient()
            return try await client.availableModels()
        }
    }

    func selectModel(provider: String, modelId: String) async throws -> PiModel {
        try await withRestart {
            let client = try self.ensureClient()
            return try await client.setModel(provider: provider, modelId: modelId)
        }
    }

    func stream(user message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try await self.clientForPrompt()
                    for try await delta in client.streamPrompt(message) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    Task { await self.abort() }
                }
            }
        }
    }

    func abort() async {
        let client: PiRPCClient?
        lock.lock()
        client = self.client
        lock.unlock()
        guard let client else { return }
        try? await client.abort()
    }

    func terminate() {
        lock.lock()
        accepting = false
        let transport = self.transport
        self.transport = nil
        self.client = nil
        lock.unlock()
        transport?.terminate()
    }

    private func clientForPrompt() async throws -> PiRPCClient {
        let model = lockedModel()
        return try await withRestart {
            let client = try self.ensureClient()
            if let selection = PiModelSelection.parse(model) {
                _ = try await client.setModel(provider: selection.provider, modelId: selection.modelId)
            }
            return client
        }
    }

    private func lockedModel() -> String {
        lock.lock()
        defer { lock.unlock() }
        return selectedModel
    }

    private func ensureClient() throws -> PiRPCClient {
        ensureLock.lock()
        defer { ensureLock.unlock() }
        lock.lock()
        if !accepting {
            lock.unlock()
            throw PiSessionError.terminated
        }
        let override = currentOverride
        if let client, let transport, transport.isRunning, launchedOverride == override {
            lock.unlock()
            return client
        }
        lock.unlock()

        let report = report()
        guard report.readiness == .ready, let path = report.executablePath else {
            throw PiSessionError.piUnavailable(report.installHint ?? "pi is not available")
        }

        lock.lock()
        if !accepting {
            lock.unlock()
            throw PiSessionError.terminated
        }
        if let client, let transport, transport.isRunning, launchedExecutable == path {
            launchedOverride = override
            lock.unlock()
            return client
        }
        let previous = transport
        transport = nil
        client = nil
        launchedExecutable = nil
        lock.unlock()
        previous?.terminate()
        let launched = transportFactory()
        let env = PiLaunch.environment(executable: path, nodePath: report.nodePath, base: environment())
        try launched.launch(executable: path, arguments: PiLaunch.arguments(toolMode: toolMode), environment: env)
        let created = PiRPCClient(transport: launched)
        created.startReading()
        lock.lock()
        if !accepting {
            lock.unlock()
            launched.terminate()
            throw PiSessionError.terminated
        }
        transport = launched
        client = created
        launchedExecutable = path
        launchedOverride = override
        lock.unlock()
        return created
    }

    private func dropClient() {
        lock.lock()
        let previous = transport
        transport = nil
        client = nil
        launchedExecutable = nil
        launchedOverride = nil
        lock.unlock()
        previous?.terminate()
    }

    private func withRestart<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as PiRPCError where error == .processExited {
            dropClient()
            return try await body()
        }
    }
}
