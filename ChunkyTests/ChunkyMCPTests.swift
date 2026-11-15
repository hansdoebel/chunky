import Foundation
import Testing

@testable import Chunky

struct ChunkyMCPTests {

    @Test func framingSplitsOnContentLength() throws {
        let first = try MCPFraming.encode(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let second = try MCPFraming.encode(["jsonrpc": "2.0", "id": 2, "method": "initialize"])
        var buffer = Data(first.prefix(12))
        #expect(MCPFraming.pullMessages(from: &buffer).isEmpty)
        buffer.append(first.dropFirst(12))
        buffer.append(second)
        let messages = MCPFraming.pullMessages(from: &buffer)
        #expect(messages.count == 2)
        #expect(buffer.isEmpty)
        let decoded = try PiJSONL.decodeObject(messages[0])
        #expect(decoded["method"] as? String == "tools/list")
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

    private func toolText(_ response: [String: Any]?) -> String? {
        let result = PiJSONL.dictionary(response?["result"])
        return PiJSONL.dictionaries(result?["content"]).first?["text"] as? String
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
