import Foundation

nonisolated enum MCPFraming {
    static func encode(_ object: [String: Any]) throws -> Data {
        try PiJSONL.encodeLine(object)
    }

    static func pullMessages(from buffer: inout Data) -> [Data] {
        PiJSONL.pullRecords(from: &buffer)
    }
}

nonisolated enum ChunkyMCPDispatch {
    static func handle(
        _ message: [String: Any],
        search: any ChunkySearchProviding,
        secrets: [String] = []
    ) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        if id == nil || id is NSNull {
            return nil
        }
        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: String]()],
                "serverInfo": ["name": "chunky", "version": "1.0"]
            ])
        case "tools/list":
            return result(id, ["tools": toolSchemas])
        case "tools/call":
            let params = PiJSONL.dictionary(message["params"]) ?? [:]
            return await call(id: id, params: params, search: search, secrets: secrets)
        default:
            return error(id, code: -32601, message: "Method not found")
        }
    }

    static let toolSchemas: [[String: Any]] = [
        [
            "name": "search",
            "description": "Search a Chunky collection and return matching chunks.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "collection": ["type": "string"],
                    "top_k": ["type": "integer"],
                    "filters": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "key": ["type": "string"],
                                "match": ["type": "string"],
                                "text": ["type": "string"],
                                "gt": ["type": "number"],
                                "gte": ["type": "number"],
                                "lt": ["type": "number"],
                                "lte": ["type": "number"]
                            ],
                            "required": ["key"]
                        ]
                    ],
                    "year_from": ["type": "integer"],
                    "year_to": ["type": "integer"],
                    "author": ["type": "string"],
                    "doi": ["type": "string"],
                    "title": ["type": "string"],
                    "heading": ["type": "string"],
                    "content_type": ["type": "string"],
                    "library": ["type": "string"],
                    "libraries": ["type": "array", "items": ["type": "string"]],
                    "all_libraries": ["type": "boolean"]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "list_collections",
            "description": "List Chunky collections that can be searched.",
            "inputSchema": [
                "type": "object",
                "properties": [String: String]()
            ]
        ]
    ]

    private static func call(
        id: Any?,
        params: [String: Any],
        search: any ChunkySearchProviding,
        secrets: [String]
    ) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = PiJSONL.dictionary(params["arguments"]) ?? [:]
        do {
            switch name {
            case "list_collections":
                let names = try await search.listCollections()
                return toolResult(id, ["collections": names], secrets: secrets)
            case "search":
                let request = try searchRequest(arguments)
                let page = try await search.search(request)
                return toolResult(id, pageJSON(page), secrets: secrets)
            default:
                return toolError(id, "Unknown tool \(name)", secrets: secrets)
            }
        } catch {
            return toolError(id, error.localizedDescription, secrets: secrets)
        }
    }

    static func searchRequest(_ arguments: [String: Any]) throws -> ChunkySearchRequest {
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChunkySearchError.invalidArguments("search requires query")
        }
        let collection = (arguments["collection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topK = int(arguments["top_k"]) ?? 8
        guard topK >= 1, topK <= 100 else {
            throw ChunkySearchError.invalidArguments("top_k must be from 1 to 100")
        }
        let filters = PiJSONL.dictionaries(arguments["filters"]).compactMap(filter) + scopeFilters(arguments)
        let libraries = Self.libraries(arguments)
        return ChunkySearchRequest(
            query: query,
            collection: collection,
            topK: topK,
            filters: filters,
            libraryIDs: libraries.ids,
            librarySearch: libraries.scope
        )
    }

    static func scopeFilters(_ arguments: [String: Any]) -> [ChunkySearchFilter] {
        RetrievalFilter.scope(
            yearFrom: string(arguments["year_from"]),
            yearTo: string(arguments["year_to"]),
            author: string(arguments["author"]),
            doi: string(arguments["doi"]),
            title: string(arguments["title"]),
            heading: string(arguments["heading"]),
            contentType: string(arguments["content_type"])
        ).map { item in
            ChunkySearchFilter(
                key: item.key,
                match: item.exactMatch,
                text: item.containsMatch,
                gte: item.gte,
                lte: item.lte
            )
        }
    }

    static func libraries(_ arguments: [String: Any]) -> (ids: [String], scope: LibrarySearch) {
        if arguments["all_libraries"] as? Bool == true {
            return ([], .all)
        }
        if let values = arguments["libraries"] as? [String] {
            let ids = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !ids.isEmpty { return (ids, .selected) }
        }
        let one = string(arguments["library"])
        if !one.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ([one], .selected)
        }
        return ([], .active)
    }

    private static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func filter(_ object: [String: Any]) -> ChunkySearchFilter? {
        guard let key = object["key"] as? String, !key.isEmpty else { return nil }
        return ChunkySearchFilter(
            key: key,
            match: object["match"] as? String,
            text: object["text"] as? String,
            gt: double(object["gt"]),
            gte: double(object["gte"]),
            lt: double(object["lt"]),
            lte: double(object["lte"])
        )
    }

    static func pageJSON(_ page: ChunkySearchPage) -> [String: Any] {
        [
            "collection": page.collection,
            "results": page.results.map { hit in
                [
                    "id": hit.id,
                    "score": hit.score,
                    "payload": hit.payload
                ] as [String: Any]
            }
        ]
    }

    private static func toolResult(_ id: Any?, _ payload: [String: Any], secrets: [String]) -> [String: Any] {
        let text = jsonText(payload, secrets: secrets)
        return result(id, [
            "content": [["type": "text", "text": text]],
            "isError": false
        ])
    }

    private static func toolError(_ id: Any?, _ message: String, secrets: [String]) -> [String: Any] {
        result(id, [
            "content": [["type": "text", "text": redact(message, secrets: secrets)]],
            "isError": true
        ])
    }

    private static func jsonText(_ payload: [String: Any], secrets: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return redact(text, secrets: secrets)
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        var redacted = text
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return redacted
    }

    private static func result(_ id: Any?, _ value: Any) -> [String: Any] {
        var object: [String: Any] = ["jsonrpc": "2.0", "result": value]
        if let id, !(id is NSNull) {
            object["id"] = id
        }
        return object
    }

    private static func error(_ id: Any?, code: Int, message: String) -> [String: Any] {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id, !(id is NSNull) {
            object["id"] = id
        }
        return object
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

nonisolated enum PiMCPConfig {
    static func json(command: String) -> [String: Any] {
        [
            "mcpServers": [
                "chunky": [
                    "command": command,
                    "args": ["--mcp"]
                ]
            ]
        ]
    }

    static func prepareRuntimeDirectory(command: String) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunky-pi-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(".pi", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json(command: command), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("mcp.json"))
        return root.path
    }
}

nonisolated enum ChunkyMCPMain {
    static func run() {
        Task.detached {
            await serve()
            exit(0)
        }
        dispatchMain()
    }

    static func serve() async {
        let secrets = await MainActor.run { KeychainSecretStore() }
        let context = ChunkyMCPContext.load(defaults: .standard, secrets: secrets)
        let search = await ChunkySearchBackend.make(secrets: secrets)
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            for body in MCPFraming.pullMessages(from: &buffer) {
                guard let message = try? PiJSONL.decodeObject(body) else { continue }
                if let response = await ChunkyMCPDispatch.handle(message, search: search, secrets: context.secrets),
                   let encoded = try? MCPFraming.encode(response) {
                    try? output.write(contentsOf: encoded)
                }
            }
        }
    }
}
