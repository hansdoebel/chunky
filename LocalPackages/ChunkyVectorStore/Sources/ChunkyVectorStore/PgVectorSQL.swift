public struct VectorFilter: Sendable, Equatable {
    public enum Match: Sendable, Equatable {
        case text(String)
        case int(Int)
        case bool(Bool)
        case contains(String)
        case any([String])
    }

    public var key: String
    public var match: Match?
    public var gt: Double?
    public var gte: Double?
    public var lt: Double?
    public var lte: Double?
    public var negated: Bool
    public var should: Bool
    public var matchEmpty: Bool

    public init(
        key: String,
        match: Match? = nil,
        gt: Double? = nil,
        gte: Double? = nil,
        lt: Double? = nil,
        lte: Double? = nil,
        negated: Bool = false,
        should: Bool = false,
        matchEmpty: Bool = false
    ) {
        self.key = key
        self.match = match
        self.gt = gt
        self.gte = gte
        self.lt = lt
        self.lte = lte
        self.negated = negated
        self.should = should
        self.matchEmpty = matchEmpty
    }
}

public struct VectorRecord: Sendable, Equatable {
    public var id: String
    public var vector: [Double]
    public var payload: JSONValue

    public init(id: String, vector: [Double], payload: JSONValue) {
        self.id = id
        self.vector = vector
        self.payload = payload
    }
}

public struct VectorHit: Sendable, Equatable {
    public var id: String
    public var score: Double
    public var payload: JSONValue

    public init(id: String, score: Double, payload: JSONValue) {
        self.id = id
        self.score = score
        self.payload = payload
    }
}

public enum VectorStoreFailure: Error, Equatable, Sendable {
    case invalidCollection(String)
    case invalidVector
    case dimensionMismatch(collection: String, existing: Int, actual: Int)
    case distanceMismatch(collection: String, existing: String)
    case notFound(String)
    case unsupported(String)
    case database(String)
}

enum PgIdentifiers {
    static let meta = quote("chunky_collection_meta")

    static func collection(_ name: String) throws -> String {
        guard name.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,54}$"#, options: .regularExpression) != nil else {
            throw VectorStoreFailure.invalidCollection(name)
        }
        return name
    }

    static func table(_ name: String) throws -> String {
        quote("chunky_" + (try collection(name)))
    }

    static func index(_ name: String) throws -> String {
        quote("hnsw_" + (try collection(name)))
    }

    static func quote(_ name: String) -> String {
        "\"" + name + "\""
    }
}

enum PgSQL {
    static func vectorText(_ vector: [Double]) throws -> String {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { throw VectorStoreFailure.invalidVector }
        return "[" + vector.map { String($0) }.joined(separator: ",") + "]"
    }

    static func filter(_ filters: [VectorFilter]) throws -> (String, [SQLValue]) {
        var must: [String] = []
        var mustNot: [String] = []
        var should: [String] = []
        var mustParams: [SQLValue] = []
        var mustNotParams: [SQLValue] = []
        var shouldParams: [SQLValue] = []
        for filter in filters {
            let key = filter.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else {
                throw VectorStoreFailure.unsupported("Invalid filter key")
            }
            let atoms = try atoms(filter, key: key)
            if filter.should {
                should.append(contentsOf: atoms.sql)
                shouldParams.append(contentsOf: atoms.parameters)
            } else if filter.negated {
                mustNot.append(contentsOf: atoms.sql)
                mustNotParams.append(contentsOf: atoms.parameters)
            } else {
                must.append(contentsOf: atoms.sql)
                mustParams.append(contentsOf: atoms.parameters)
            }
        }
        var parts = must + mustNot.map { "NOT (\($0))" }
        var parameters = mustParams + mustNotParams
        if !should.isEmpty {
            parts.append("(" + should.joined(separator: " OR ") + ")")
            parameters.append(contentsOf: shouldParams)
        }
        return (parts.joined(separator: " AND "), parameters)
    }

    static func metric(_ distance: String) throws -> (score: String, order: String) {
        switch distance {
        case "cosine":
            return ("1 - (embedding <=> $@::vector)", "embedding <=> $@::vector")
        case "euclid":
            return ("1.0 / (1.0 + (embedding <-> $@::vector))", "embedding <-> $@::vector")
        case "dot":
            return ("-(embedding <#> $@::vector)", "embedding <#> $@::vector")
        default:
            throw VectorStoreFailure.unsupported("Unsupported distance: \(distance)")
        }
    }

    private static func atoms(_ filter: VectorFilter, key: String) throws -> (sql: [String], parameters: [SQLValue]) {
        var sql: [String] = []
        var parameters: [SQLValue] = []
        let hasRange = filter.gt != nil || filter.gte != nil || filter.lt != nil || filter.lte != nil
        if filter.match == nil && !filter.matchEmpty && !hasRange {
            throw VectorStoreFailure.unsupported("Filter \(key) needs a match or a range")
        }
        if filter.matchEmpty {
            sql.append("(NOT (payload ? $@) OR payload->>$@ IS NULL OR payload->>$@ = '')")
            parameters.append(contentsOf: [.text(key), .text(key), .text(key)])
        }
        if let match = filter.match {
            switch match {
            case .text(let value):
                sql.append("payload @> $@::jsonb")
                parameters.append(.text(JSONValue.object([key: .string(value)]).encoded()))
            case .int(let value):
                sql.append("payload @> $@::jsonb")
                parameters.append(.text(JSONValue.object([key: .int(value)]).encoded()))
            case .bool(let value):
                sql.append("payload @> $@::jsonb")
                parameters.append(.text(JSONValue.object([key: .bool(value)]).encoded()))
            case .contains(let value):
                let pattern = "%" + like(value) + "%"
                sql.append("(COALESCE(payload->>$@, '') ILIKE $@ ESCAPE '\\' OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(payload->$@) = 'array' THEN payload->$@ ELSE '[]'::jsonb END) element WHERE element ILIKE $@ ESCAPE '\\'))")
                parameters.append(contentsOf: [.text(key), .text(pattern), .text(key), .text(key), .text(pattern)])
            case .any(let values):
                let slots = values.map { _ in "$@" }.joined(separator: ", ")
                sql.append("payload->>$@ IN (\(slots))")
                parameters.append(.text(key))
                parameters.append(contentsOf: values.map { SQLValue.text($0) })
            }
        }
        if hasRange {
            var pieces: [String] = []
            if let bound = filter.gt { pieces.append("(payload->>$@)::double precision > $@"); parameters.append(contentsOf: [.text(key), .double(bound)]) }
            if let bound = filter.gte { pieces.append("(payload->>$@)::double precision >= $@"); parameters.append(contentsOf: [.text(key), .double(bound)]) }
            if let bound = filter.lt { pieces.append("(payload->>$@)::double precision < $@"); parameters.append(contentsOf: [.text(key), .double(bound)]) }
            if let bound = filter.lte { pieces.append("(payload->>$@)::double precision <= $@"); parameters.append(contentsOf: [.text(key), .double(bound)]) }
            sql.append("(" + pieces.joined(separator: " AND ") + ")")
        }
        return (sql, parameters)
    }

    private static func like(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

func numbered(_ sql: String, parameters: [SQLValue]) -> SQLStatement {
    var rendered = ""
    var number = 1
    var index = sql.startIndex
    while index < sql.endIndex {
        let next = sql.index(after: index)
        if sql[index] == "$", next < sql.endIndex, sql[next] == "@" {
            rendered += "$\(number)"
            number += 1
            index = sql.index(after: next)
        } else {
            rendered.append(sql[index])
            index = next
        }
    }
    return SQLStatement(sql: rendered, parameters: parameters)
}
