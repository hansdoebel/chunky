import Foundation

struct QdrantPoint: Identifiable, Hashable {
    let id: String
    let text: String
    let source: String
    let page: Int?
    let headings: [String]

    init(id: String, text: String, source: String, page: Int?, headings: [String] = []) {
        self.id = id
        self.text = text
        self.source = source
        self.page = page
        self.headings = headings
    }

    init(from raw: QdrantPointRaw) {
        self.id = raw.id.stringValue
        self.text = raw.payload?["text"]?.stringValue ?? ""
        self.source = raw.payload?["source"]?.stringValue ?? "Unknown"
        self.page = raw.payload?["page"]?.intValue
        self.headings = raw.payload?["headings"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }
}

struct QdrantPointRaw: Codable {
    let id: PointId
    let payload: [String: AnyCodable]?

    enum PointId: Codable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) {
                self = .int(intVal)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .int(let i): try container.encode(i)
            }
        }

        var stringValue: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            }
        }
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        value as? String
    }

    var intValue: Int? {
        value as? Int
    }

    var arrayValue: [AnyCodable]? {
        if let arr = value as? [Any] {
            return arr.map { AnyCodable($0) }
        }
        return nil
    }
}

struct QdrantScrollResponse: Codable {
    let result: QdrantScrollResult?
}

struct QdrantScrollResult: Codable {
    let points: [QdrantPointRaw]
    let nextPageOffset: String?

    enum CodingKeys: String, CodingKey {
        case points
        case nextPageOffset = "next_page_offset"
    }
}

struct QdrantCollectionInfo: Codable {
    let result: QdrantCollectionResult?
}

struct QdrantCollectionResult: Codable {
    let pointsCount: Int?
    let vectorsCount: Int?

    enum CodingKeys: String, CodingKey {
        case pointsCount = "points_count"
        case vectorsCount = "vectors_count"
    }
}
