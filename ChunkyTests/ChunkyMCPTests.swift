import Foundation
import Testing

@testable import Chunky

struct ChunkyMCPTests {

    @Test func framingReadsNewlineDelimitedJSON() async throws {
        let line = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}\n".utf8)
        var buffer = Data(line.prefix(20))
        #expect(MCPFraming.pullMessages(from: &buffer).isEmpty)
        buffer.append(line.dropFirst(20))
        buffer.append(contentsOf: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\r\n".utf8)
        let messages = MCPFraming.pullMessages(from: &buffer)
        #expect(messages.count == 2)
        #expect(buffer.isEmpty)
        let request = try PiJSONL.decodeObject(messages[0])
        let response = await ChunkyMCPDispatch.handle(request, search: FakeChunkySearch())
        let encoded = try MCPFraming.encode(response!)
        #expect(encoded.last == 0x0A)
        #expect(!encoded.dropLast().contains(0x0A))
        let decoded = try PiJSONL.decodeObject(encoded.dropLast())
        let result = PiJSONL.dictionary(decoded["result"])
        let info = PiJSONL.dictionary(result?["serverInfo"])
        #expect(info?["name"] as? String == "chunky")
    }

    @Test func toolSchemasNameSearchAndCollections() async {
        let response = await ChunkyMCPDispatch.handle(
            ["jsonrpc": "2.0", "id": "tools", "method": "tools/list"],
            search: FakeChunkySearch()
        )
        let result = PiJSONL.dictionary(response?["result"])
        let tools = PiJSONL.dictionaries(result?["tools"])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ["search", "list_collections"])
        let search = tools[0]
        let schema = PiJSONL.dictionary(search["inputSchema"])
        let required = (schema?["required"] as? [String]) ?? (schema?["required"] as? [Any])?.compactMap { $0 as? String }
        #expect(required == ["query"])
        let properties = PiJSONL.dictionary(schema?["properties"])
        #expect(properties?["query"] != nil)
        #expect(properties?["collection"] != nil)
        #expect(properties?["top_k"] != nil)
        #expect(properties?["filters"] != nil)
    }

    @Test func searchCallSerializesHitsAndRedactsSecrets() async throws {
        let arguments: [String: Any] = [
            "query": "voltage",
            "collection": "documents",
            "top_k": 3,
            "filters": [["key": "source", "match": "manual.pdf"], ["key": "page", "gte": 2]]
        ]
        let response = await ChunkyMCPDispatch.handle(
            [
                "jsonrpc": "2.0",
                "id": "call-1",
                "method": "tools/call",
                "params": ["name": "search", "arguments": arguments]
            ],
            search: FakeChunkySearch(),
            secrets: ["super-secret-token"]
        )
        let result = PiJSONL.dictionary(response?["result"])
        #expect(PiJSONL.bool(result?["isError"]) == false)
        let content = PiJSONL.dictionaries(result?["content"])
        let text = content.first?["text"] as? String ?? ""
        #expect(!text.contains("super-secret-token"))
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let page = PiJSONL.dictionary(payload)
        let hits = PiJSONL.dictionaries(page?["results"])
        #expect(page?["collection"] as? String == "documents")
        #expect(hits.first?["id"] as? String == "chunk-1")
        #expect(hits.first?["score"] as? Double == 0.91 || (hits.first?["score"] as? NSNumber)?.doubleValue == 0.91)
        let fields = PiJSONL.dictionary(hits.first?["payload"])
        #expect(fields?["source"] as? String == "manual.pdf")
        #expect(fields?["page"] as? String == "4")
        #expect(text.contains("[redacted]"))
    }

    @Test func listCollectionsAndRejectsAMissingQuery() async throws {
        let listed = await ChunkyMCPDispatch.handle(
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "list_collections", "arguments": [String: String]()]],
            search: FakeChunkySearch()
        )
        let listedText = toolText(listed)
        #expect(listedText?.contains("documents") == true)
        let missing = await ChunkyMCPDispatch.handle(
            ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "search", "arguments": ["collection": "documents"]]],
            search: FakeChunkySearch()
        )
        let result = PiJSONL.dictionary(missing?["result"])
        #expect(PiJSONL.bool(result?["isError"]) == true)
        #expect(toolText(missing)?.contains("query") == true)
    }

    @Test func searchScopeFieldsBecomeFilters() throws {
        let request = try ChunkyMCPDispatch.searchRequest([
            "query": "revenue",
            "year_from": 2020,
            "year_to": 2024,
            "author": "Ada",
            "doi": "10.1000/xyz",
            "title": "Revenue",
            "heading": "Results",
            "content_type": "table",
        ])
        #expect(request.filters.map(\.key) == ["year", "authors", "doi", "doc_title", "headings", "content_type"])
        #expect(request.filters[0].gte == 2020)
        #expect(request.filters[0].lte == 2024)
        #expect(request.filters[1].text == "Ada")
        #expect(request.filters[2].match == "10.1000/xyz")
        #expect(request.filters[3].text == "Revenue")
        #expect(request.filters[4].text == "Results")
        #expect(request.filters[5].match == "table")
        let empty = try ChunkyMCPDispatch.searchRequest(["query": "revenue", "author": "  "])
        #expect(empty.filters.isEmpty)
        let schema = ChunkyMCPDispatch.toolSchemas[0]["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        #expect(properties?["year_from"] != nil)
        #expect(properties?["author"] != nil)
        #expect(properties?["heading"] != nil)
        #expect(properties?["library"] != nil)
        #expect(properties?["all_libraries"] != nil)
        let selected = try ChunkyMCPDispatch.searchRequest(["query": "revenue", "libraries": ["thesis", "default"]])
        #expect(selected.librarySearch == .selected)
        #expect(selected.libraryIDs == ["thesis", "default"])
        let everyone = try ChunkyMCPDispatch.searchRequest(["query": "revenue", "all_libraries": true])
        #expect(everyone.librarySearch == .all)
        let active = try ChunkyMCPDispatch.searchRequest(["query": "revenue"])
        #expect(active.librarySearch == .active)
        #expect(active.libraryIDs.isEmpty)
    }

    @Test func retrievalServiceReceivesTheSavedSearch() async throws {
        let name = "chunky-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        settings.defaultCollection = "manuals"
        settings.embeddingModel = "qwen3-embedding"
        settings.embeddingBackend = "ollama"
        settings.qdrantURL = "http://127.0.0.1:6334"
        settings.qdrantAPIKey = "super-secret-token"
        let script = ScriptedRetrieval()
        let backend = RetrievalServiceSearch(settings: settings, retrieval: script)
        let page = try await backend.search(
            ChunkySearchRequest(
                query: "voltage",
                collection: "",
                topK: 4,
                filters: [ChunkySearchFilter(key: "source", match: "manual.pdf", gt: nil, gte: nil, lt: nil, lte: nil)]
            )
        )
        #expect(page.collection == "manuals")
        #expect(page.results.first?.id == "chunk-9")
        #expect(page.results.first?.payload["text"] == "kept")
        let sent = await script.lastRequest
        #expect(sent?.text == "voltage")
        #expect(sent?.collection == "manuals")
        #expect(sent?.limit == 4)
        #expect(sent?.filters.first?.key == "source")
        #expect(sent?.qdrantAPIKey == "super-secret-token")
        #expect(page.results.first?.payload.values.contains("super-secret-token") != true)
        let names = try await backend.listCollections()
        #expect(names == ["manuals", "notes"])
        let listed = await script.listed
        #expect(listed?.url == "http://127.0.0.1:6334")
        #expect(listed?.apiKey == "super-secret-token")
    }

    @Test func settingsLoadSecretsFromTheStoreAndOmitThemFromTheSummary() throws {
        let name = "chunky-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        settings.qdrantURL = "https://example.cloud.qdrant.io"
        settings.qdrantAPIKey = "super-secret-token"
        settings.workerToken = "worker-secret"
        settings.devboxWorkerURL = "http://127.0.0.1:8000"
        settings.defaultCollection = "manuals"
        settings.embeddingModel = "qwen3-embedding"
        let context = ChunkyMCPContext.load(defaults: defaults, secrets: secrets)
        #expect(context.qdrantURL == "https://example.cloud.qdrant.io")
        #expect(context.qdrantAPIKey == "super-secret-token")
        #expect(context.workerToken == "worker-secret")
        #expect(context.workerURL == "http://127.0.0.1:8000")
        #expect(context.defaultCollection == "manuals")
        let summary = context.redactedSummary()
        #expect(!summary.contains("super-secret-token"))
        #expect(!summary.contains("worker-secret"))
        #expect(summary.contains("manuals"))
    }

    @Test func piConfigEnablesOnlyChunkySearchTools() throws {
        let args = PiLaunch.chunkySearchArguments()
        #expect(args.contains("--approve"))
        #expect(PiLaunch.codingToolsDisabled(in: args))
        #expect(args.contains("mcp__chunky__search,mcp__chunky__list_collections"))
        #expect(!args.contains("--no-tools"))
        let directory = try PiMCPConfig.prepareRuntimeDirectory(command: "/Applications/Chunky.app/Contents/MacOS/Chunky")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = URL(fileURLWithPath: directory).appendingPathComponent(".pi/mcp.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        let root = PiJSONL.dictionary(object)
        let servers = PiJSONL.dictionary(root?["mcpServers"])
        let chunky = PiJSONL.dictionary(servers?["chunky"])
        #expect(chunky?["command"] as? String == "/Applications/Chunky.app/Contents/MacOS/Chunky")
        #expect(chunky?["args"] as? [String] == ["--mcp"])
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains("super-secret-token"))
    }

    @Test func runtimeDirectoryIsRemovedWhenPiStopsOrFailsToLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.path
        func names() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("chunky-pi-") }
        }
        let before = names()
        let transports = MCPLaunchBox()
        let session = PiChatSession(
            toolMode: .allow(PiLaunch.chunkyMCPTools),
            locate: { .readyFixture },
            transportFactory: { transports.make() },
            environment: { ["HOME": "/Users/ada", "PATH": "/usr/bin"] }
        )
        _ = try await session.availableModels()
        let created = names().subtracting(before)
        #expect(created.count == 1)
        session.terminate()
        #expect(names().isDisjoint(with: created))

        transports.failNextLaunch = true
        let again = PiChatSession(
            toolMode: .allow(PiLaunch.chunkyMCPTools),
            locate: { .readyFixture },
            transportFactory: { transports.make() },
            environment: { ["HOME": "/Users/ada", "PATH": "/usr/bin"] }
        )
        let beforeFailure = names()
        do {
            _ = try await again.availableModels()
            Issue.record("launch should fail")
        } catch {
            #expect(names().subtracting(beforeFailure).isEmpty)
        }
    }

    private func toolText(_ response: [String: Any]?) -> String? {
        let result = PiJSONL.dictionary(response?["result"])
        return PiJSONL.dictionaries(result?["content"]).first?["text"] as? String
    }
}

private final class MCPLaunchBox: @unchecked Sendable {
    var failNextLaunch = false
    func make() -> MCPLaunchTransport {
        let transport = MCPLaunchTransport()
        transport.failLaunch = failNextLaunch
        failNextLaunch = false
        return transport
    }
}

private final class MCPLaunchTransport: PiByteStream, @unchecked Sendable {
    var failLaunch = false
    private var running = false
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    var stdout: AsyncStream<Data> { stream }
    var isRunning: Bool { running }

    init() {
        var captured: AsyncStream<Data>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func launch(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?) throws {
        _ = (executable, arguments, environment, currentDirectory)
        if failLaunch { throw PiTransportError.notRunning }
        running = true
    }

    func write(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any] else { return }
        let id = object["id"] as? String ?? ""
        let response = try? PiJSONL.encodeLine([
            "id": id,
            "type": "response",
            "command": "get_available_models",
            "success": true,
            "data": ["models": []]
        ])
        if let response { continuation.yield(response) }
    }

    func terminate() {
        running = false
        continuation.finish()
    }
}

private actor ScriptedRetrieval: ChunkyRetrievalCalling {
    var lastRequest: RetrievalRequest?
    var listed: (url: String, apiKey: String)?

    func search(_ request: RetrievalRequest) async throws -> RetrievalPage {
        lastRequest = request
        return RetrievalPage(
            hits: [
                RetrievalHit(
                    id: "chunk-9",
                    score: 0.5,
                    text: "kept",
                    source: "manual.pdf",
                    page: 1,
                    headings: [],
                    payload: ["text": "kept", "source": "manual.pdf"]
                )
            ],
            limit: request.limit,
            offset: 0,
            nextOffset: nil,
            embeddingModel: request.embeddingModel,
            embeddingBackend: request.embeddingBackend,
            embeddingDim: 1024,
            collection: request.collection,
            route: request.route
        )
    }

    func listCollections(url: String, apiKey: String) async throws -> [String] {
        listed = (url, apiKey)
        return ["manuals", "notes"]
    }
}

private struct FakeChunkySearch: ChunkySearchProviding {
    func listCollections() async throws -> [String] {
        ["documents", "notes"]
    }

    func search(_ request: ChunkySearchRequest) async throws -> ChunkySearchPage {
        return ChunkySearchPage(
            results: [
                ChunkySearchHit(
                    id: "chunk-1",
                    score: 0.91,
                    payload: ["source": "manual.pdf", "page": "4", "text": "token super-secret-token stays out"]
                )
            ],
            collection: request.collection
        )
    }
}
