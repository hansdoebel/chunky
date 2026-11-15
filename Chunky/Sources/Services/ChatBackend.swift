import Foundation

nonisolated enum ChatBackendPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case pi
    case openAICompatible = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .pi:
            return "pi"
        case .openAICompatible:
            return "OpenAI-compatible"
        }
    }
}

nonisolated struct ChatRoute: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pi
        case openAICompatible
    }

    var kind: Kind
    var fellBack: Bool
    var checking: Bool
}

nonisolated enum ChatRouter {
    static func route(preference: ChatBackendPreference, report: PiInstallReport) -> ChatRoute {
        if preference == .openAICompatible {
            return ChatRoute(kind: .openAICompatible, fellBack: false, checking: false)
        }
        if report.readiness == .unknown {
            return ChatRoute(kind: .openAICompatible, fellBack: false, checking: true)
        }
        if report.readiness == .ready {
            return ChatRoute(kind: .pi, fellBack: false, checking: false)
        }
        return ChatRoute(kind: .openAICompatible, fellBack: true, checking: false)
    }
}

nonisolated protocol ChatStreaming: AnyObject, Sendable {
    func stream(user message: String) -> AsyncThrowingStream<String, Error>
    func abort() async
}

nonisolated protocol ChatHTTPStreaming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

nonisolated enum ChatClientError: LocalizedError, Equatable {
    case invalidURL
    case httpStatus(Int, String)
    case emptyModel

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Chat endpoint URL is invalid"
        case .httpStatus(let code, let body):
            if body.isEmpty {
                return "Chat endpoint returned HTTP \(code)"
            }
            return "Chat endpoint returned HTTP \(code): \(body)"
        case .emptyModel:
            return "Choose a chat model"
        }
    }
}

nonisolated enum SecretRedaction {
    static func text(_ text: String, removing secret: String) -> String {
        guard !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
    }
}

nonisolated enum OpenAIChatSSE {
    static func contentDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = PiJSONL.dictionary(object),
              let choice = PiJSONL.dictionaries(root["choices"]).first,
              let delta = PiJSONL.dictionary(choice["delta"]) else {
            return nil
        }
        return delta["content"] as? String
    }

    static func consume(_ buffer: inout Data) -> (deltas: [String], done: Bool) {
        var deltas: [String] = []
        var done = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            var record = Data(buffer[..<newline])
            buffer.removeSubrange(..<buffer.index(after: newline))
            if record.last == 0x0D {
                record.removeLast()
            }
            guard let line = String(data: record, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(":") {
                continue
            }
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                done = true
                continue
            }
            if let delta = contentDelta(from: String(payload)) {
                deltas.append(delta)
            }
        }
        return (deltas, done)
    }
}

nonisolated enum OpenAIModelList {
    static func ids(from data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data)
        let root = PiJSONL.dictionary(object) ?? [:]
        return PiJSONL.dictionaries(root["data"]).compactMap { $0["id"] as? String }
    }
}

nonisolated final class URLSessionChatHTTP: ChatHTTPStreaming, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatClientError.invalidURL
        }
        return (data, http)
    }

    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatClientError.invalidURL
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= 1024 || byte == 10 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (http, stream)
    }
}

nonisolated final class OpenAICompatibleChatClient: ChatStreaming, @unchecked Sendable {
    let baseURL: String
    let model: String
    private let apiKey: String
    private let http: any ChatHTTPStreaming
    private let lock = NSLock()
    private var current: Task<Void, Never>?

    init(baseURL: String, model: String, apiKey: String, http: any ChatHTTPStreaming) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.http = http
    }

    func listModels() async throws -> [String] {
        let request = try makeRequest(path: "models", method: "GET", body: nil)
        let (data, httpResponse) = try await http.data(for: request)
        guard httpResponse.statusCode == 200 else {
            throw statusError(httpResponse.statusCode, data: data)
        }
        return try OpenAIModelList.ids(from: data)
    }

    func stream(user message: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: [["role": "user", "content": message]])
    }

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ])
    }

    private func stream(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": self.model,
                        "messages": messages,
                        "stream": true
                    ]
                    let request = try self.makeRequest(path: "chat/completions", method: "POST", body: body)
                    let (httpResponse, bytes) = try await self.http.bytes(for: request)
                    guard httpResponse.statusCode == 200 else {
                        var raw = Data()
                        for try await chunk in bytes {
                            raw.append(chunk)
                            if raw.count >= 500 { break }
                        }
                        throw self.statusError(
                            httpResponse.statusCode,
                            text: String(data: raw.prefix(500), encoding: .utf8) ?? ""
                        )
                    }
                    var pending = Data()
                    for try await chunk in bytes {
                        if Task.isCancelled { break }
                        pending.append(chunk)
                        let parsed = OpenAIChatSSE.consume(&pending)
                        for delta in parsed.deltas where !delta.isEmpty {
                            continuation.yield(delta)
                        }
                        if parsed.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.lock.lock()
            self.current = task
            self.lock.unlock()
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func abort() async {
        lock.lock()
        let task = current
        lock.unlock()
        task?.cancel()
    }

    private func makeRequest(path: String, method: String, body: [String: Any]?) throws -> URLRequest {
        guard let url = endpoint(baseURL, path) else {
            throw ChatClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func endpoint(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: trimmed + "/" + path)
    }

    private func statusError(_ code: Int, data: Data) -> ChatClientError {
        statusError(code, text: String(data: data, encoding: .utf8) ?? "")
    }

    private func statusError(_ code: Int, text: String) -> ChatClientError {
        let redacted = SecretRedaction.text(String(text.prefix(500)), removing: apiKey)
        return .httpStatus(code, redacted)
    }
}

nonisolated final class PiStreamingChat: ChatStreaming, @unchecked Sendable {
    private let session: PiChatSession
    private let model: String

    init(session: PiChatSession, model: String) {
        self.session = session
        self.model = model
    }

    func stream(user message: String) -> AsyncThrowingStream<String, Error> {
        session.use(model: model)
        return session.stream(user: message)
    }

    func abort() async {
        await session.abort()
    }
}

nonisolated enum ChatBackendFactory {
    static func make(
        preference: ChatBackendPreference,
        report: PiInstallReport,
        piModel: String,
        chatModel: String,
        apiURL: String,
        apiKey: String,
        overridePath: String,
        session: PiChatSession,
        http: any ChatHTTPStreaming
    ) -> any ChatStreaming {
        session.setOverridePath(overridePath)
        let route = ChatRouter.route(preference: preference, report: report)
        switch route.kind {
        case .pi:
            return PiStreamingChat(session: session, model: piModel)
        case .openAICompatible:
            return OpenAICompatibleChatClient(baseURL: apiURL, model: chatModel, apiKey: apiKey, http: http)
        }
    }
}
