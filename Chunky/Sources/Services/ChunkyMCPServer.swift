import Foundation

nonisolated enum MCPFraming {
    static func encode(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        var message = header
        message.append(body)
        return message
    }

    static func pullMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerRange = range(of: separator, in: buffer) {
            let headerData = buffer[..<headerRange.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8),
                  let length = contentLength(header) else {
                break
            }
            let bodyStart = headerRange.upperBound
            let bodyEnd = buffer.index(bodyStart, offsetBy: length, limitedBy: buffer.endIndex)
            guard let bodyEnd, bodyEnd <= buffer.endIndex else { break }
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(..<bodyEnd)
        }
        return messages
    }

    static func range(of separator: Data, in buffer: Data) -> Range<Data.Index>? {
        guard !separator.isEmpty, buffer.count >= separator.count else { return nil }
        var index = buffer.startIndex
        let last = buffer.index(buffer.endIndex, offsetBy: -separator.count)
        while index <= last {
            let end = buffer.index(index, offsetBy: separator.count)
            if buffer[index..<end] == separator {
                return index..<end
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    static func contentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1])
        }
        return nil
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
                                "gt": ["type": "number"],
                                "gte": ["type": "number"],
                                "lt": ["type": "number"],
                                "lte": ["type": "number"]
                            ],
                            "required": ["key"]
                        ]
                    ]
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
        let filters = PiJSONL.dictionaries(arguments["filters"]).compactMap(filter)
        return ChunkySearchRequest(query: query, collection: collection, topK: topK, filters: filters)
    }

    private static func filter(_ object: [String: Any]) -> ChunkySearchFilter? {
        guard let key = object["key"] as? String, !key.isEmpty else { return nil }
        return ChunkySearchFilter(
            key: key,
            match: object["match"] as? String,
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
        let context = ChunkyMCPContext.load(defaults: .standard, secrets: KeychainSecretStore())
        let search = ChunkySearchBackend.make(context: context)
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            for body in MCPFraming.pullMessages(from: &buffer) {
                guard let message = try? PiJSONL.decodeObject(body) else { continue }
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    if let response = await ChunkyMCPDispatch.handle(message, search: search, secrets: context.secrets),
                       let encoded = try? MCPFraming.encode(response) {
                        try? output.write(contentsOf: encoded)
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }
    }
}
