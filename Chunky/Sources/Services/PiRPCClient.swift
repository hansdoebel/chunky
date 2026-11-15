import Foundation

nonisolated protocol PiByteStream: AnyObject, Sendable {
    var stdout: AsyncStream<Data> { get }
    var isRunning: Bool { get }
    func launch(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?) throws
    func write(_ data: Data) throws
    func terminate()
}

nonisolated enum PiTransportError: LocalizedError {
    case notRunning

    var errorDescription: String? {
        "pi is not running"
    }
}

nonisolated final class FoundationPiTransport: PiByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdin: Pipe?
    private var running = false
    private var finished = false
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    var stdout: AsyncStream<Data> { stream }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && process?.isRunning == true
    }

    init() {
        var captured: AsyncStream<Data>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func launch(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.finishStdout()
            } else {
                self?.continuation.yield(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            self?.finishStdout()
        }
        try process.run()
        lock.lock()
        self.process = process
        self.stdin = stdin
        self.running = true
        lock.unlock()
    }

    func write(_ data: Data) throws {
        lock.lock()
        let handle = stdin?.fileHandleForWriting
        let active = running
        lock.unlock()
        guard active, let handle else {
            throw PiTransportError.notRunning
        }
        try handle.write(contentsOf: data)
    }

    func terminate() {
        lock.lock()
        let process = self.process
        running = false
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
        finishStdout()
    }

    private func finishStdout() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        running = false
        let stdout = process?.standardOutput as? Pipe
        let stderr = process?.standardError as? Pipe
        lock.unlock()
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        continuation.finish()
    }
}

nonisolated final class PiRPCClient: @unchecked Sendable {
    private let transport: any PiByteStream
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [String: CheckedContinuation<PiRPCResponse, Error>] = [:]
    private var events: [PiEvent] = []
    private var eventWaiter: CheckedContinuation<PiEvent, Error>?
    private var reading = false
    private var closed = false
    private var closeError: Error?

    init(transport: any PiByteStream) {
        self.transport = transport
    }

    func startReading() {
        lock.lock()
        if reading {
            lock.unlock()
            return
        }
        reading = true
        lock.unlock()
        let transport = self.transport
        Task {
            for await chunk in transport.stdout {
                self.ingest(chunk)
            }
            self.fail(PiRPCError.processExited)
        }
    }

    func request(type: String, fields: [String: Any] = [:]) async throws -> PiRPCResponse {
        let id = UUID().uuidString
        var object: [String: Any] = ["id": id, "type": type]
        for (key, value) in fields {
            object[key] = value
        }
        let line = try PiJSONL.encodeLine(object)
        return try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if self.closed {
                let error = self.closeError ?? PiRPCError.processExited
                self.lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.waiters[id] = continuation
            self.lock.unlock()
            do {
                try self.transport.write(line)
            } catch {
                self.lock.lock()
                let waiter = self.waiters.removeValue(forKey: id)
                self.lock.unlock()
                let mapped: Error = self.transport.isRunning ? error : PiRPCError.processExited
                waiter?.resume(throwing: mapped)
            }
        }
    }

    func availableModels() async throws -> [PiModel] {
        let response = try await request(type: "get_available_models")
        guard response.success else {
            throw PiRPCError.commandFailed(response.command, response.error ?? "Could not list models")
        }
        return PiModel.list(from: response.data)
    }

    func setModel(provider: String, modelId: String) async throws -> PiModel {
        let response = try await request(type: "set_model", fields: ["provider": provider, "modelId": modelId])
        guard response.success, let object = PiJSONL.dictionary(response.data), let model = PiModel(json: object) else {
            throw PiRPCError.commandFailed(response.command, response.error ?? "Could not select the model")
        }
        return model
    }

    func abort() async throws {
        let response = try await request(type: "abort")
        guard response.success else {
            throw PiRPCError.commandFailed("abort", response.error ?? "Abort failed")
        }
    }

    func streamPrompt(_ message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.request(type: "prompt", fields: ["message": message])
                    guard response.success else {
                        throw PiRPCError.commandFailed(response.command, response.error ?? "Prompt failed")
                    }
                    if response.disposition == "handled" {
                        continuation.finish()
                        return
                    }
                    while true {
                        let event = try await self.nextEvent()
                        if let delta = event.textDelta {
                            continuation.yield(delta)
                        } else if event.type == "agent_settled" {
                            continuation.finish()
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func nextEvent() async throws -> PiEvent {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if self.closed {
                let error = self.closeError ?? PiRPCError.processExited
                self.lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            if !self.events.isEmpty {
                let event = self.events.removeFirst()
                self.lock.unlock()
                continuation.resume(returning: event)
                return
            }
            if self.eventWaiter != nil {
                self.lock.unlock()
                continuation.resume(throwing: PiRPCError.busy)
                return
            }
            self.eventWaiter = continuation
            self.lock.unlock()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        buffer.append(data)
        let records = PiJSONL.pullRecords(from: &buffer)
        lock.unlock()
        for record in records {
            do {
                let object = try PiJSONL.decodeObject(record)
                handle(object)
            } catch {
                fail(error)
                return
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        let type = object["type"] as? String ?? ""
        if type == "response" {
            let id = object["id"] as? String ?? ""
            let response = PiRPCResponse(
                id: id,
                command: object["command"] as? String ?? "",
                success: PiJSONL.bool(object["success"]),
                data: PiJSONL.stripped(object["data"]),
                error: PiRPCResponse.errorText(object["error"])
            )
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(returning: response)
        } else {
            push(PiEvent(object: object))
        }
    }

    private func push(_ event: PiEvent) {
        lock.lock()
        if let waiter = eventWaiter {
            eventWaiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        } else {
            events.append(event)
            lock.unlock()
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        closeError = error
        let commandWaiters = Array(waiters.values)
        waiters.removeAll()
        let pendingEvent = eventWaiter
        eventWaiter = nil
        lock.unlock()
        for waiter in commandWaiters {
            waiter.resume(throwing: error)
        }
        pendingEvent?.resume(throwing: error)
    }
}
