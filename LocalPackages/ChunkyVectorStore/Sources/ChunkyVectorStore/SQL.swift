public enum SQLValue: Sendable, Equatable {
    case text(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case null
}

public struct SQLStatement: Sendable, Equatable {
    public var sql: String
    public var parameters: [SQLValue]

    public init(sql: String, parameters: [SQLValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }
}

public struct SQLRow: Sendable, Equatable {
    public var columns: [String: SQLValue]

    public init(columns: [String: SQLValue]) {
        self.columns = columns
    }

    public func text(_ name: String) -> String? {
        if case .text(let value) = columns[name] { return value }
        if case .integer(let value) = columns[name] { return String(value) }
        if case .double(let value) = columns[name] { return String(value) }
        return nil
    }

    public func integer(_ name: String) -> Int? {
        if case .integer(let value) = columns[name] { return value }
        if case .text(let value) = columns[name] { return Int(value) }
        return nil
    }

    public func double(_ name: String) -> Double? {
        if case .double(let value) = columns[name] { return value }
        if case .text(let value) = columns[name] { return Double(value) }
        if case .integer(let value) = columns[name] { return Double(value) }
        return nil
    }
}

public protocol SQLExecuting: Sendable {
    func execute(_ statement: SQLStatement) async throws -> [SQLRow]
}

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encoded() -> String {
        encode(self)
    }

    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(characters: Array(text))
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        guard parser.done else { return nil }
        return value
    }
}

private func encode(_ value: JSONValue) -> String {
    switch value {
    case .null:
        return "null"
    case .bool(let value):
        return value ? "true" : "false"
    case .int(let value):
        return String(value)
    case .double(let value):
        return String(value)
    case .string(let value):
        return "\"" + escape(value) + "\""
    case .array(let values):
        return "[" + values.map(encode).joined(separator: ",") + "]"
    case .object(let fields):
        let body = fields.keys.sorted().map { key in
            "\"" + escape(key) + "\":" + encode(fields[key] ?? .null)
        }.joined(separator: ",")
        return "{" + body + "}"
    }
}

private func escape(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

private struct JSONParser {
    var characters: [Character]
    var index = 0

    var done: Bool { index >= characters.count }

    mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard index < characters.count else { return nil }
        let character = characters[index]
        if character == "{" { return parseObject() }
        if character == "[" { return parseArray() }
        if character == "\"" { return parseString().map(JSONValue.string) }
        if character == "t" { return consume("true") ? .bool(true) : nil }
        if character == "f" { return consume("false") ? .bool(false) : nil }
        if character == "n" { return consume("null") ? .null : nil }
        return parseNumber()
    }

    mutating func parseObject() -> JSONValue? {
        index += 1
        var fields: [String: JSONValue] = [:]
        skipWhitespace()
        if peek("}") { index += 1; return .object(fields) }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard consume(":"), let value = parseValue() else { return nil }
            fields[key] = value
            skipWhitespace()
            if peek("}") { index += 1; return .object(fields) }
            guard consume(",") else { return nil }
            skipWhitespace()
        }
    }

    mutating func parseArray() -> JSONValue? {
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if peek("]") { index += 1; return .array(values) }
        while true {
            guard let value = parseValue() else { return nil }
            values.append(value)
            skipWhitespace()
            if peek("]") { index += 1; return .array(values) }
            guard consume(",") else { return nil }
            skipWhitespace()
        }
    }

    mutating func parseString() -> String? {
        guard consume("\"") else { return nil }
        var out = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\"" { return out }
            if character == "\\" {
                guard index < characters.count else { return nil }
                let escaped = characters[index]
                index += 1
                switch escaped {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(escaped)
                }
            } else {
                out.append(character)
            }
        }
        return nil
    }

    mutating func parseNumber() -> JSONValue? {
        let start = index
        if peek("-") { index += 1 }
        while index < characters.count, characters[index].isNumber { index += 1 }
        var fractional = false
        if peek(".") {
            fractional = true
            index += 1
            while index < characters.count, characters[index].isNumber { index += 1 }
        }
        let text = String(characters[start..<index])
        if fractional, let value = Double(text) { return .double(value) }
        if let value = Int(text) { return .int(value) }
        return nil
    }

    mutating func consume(_ text: String) -> Bool {
        let upcoming = characters[index...].prefix(text.count)
        guard String(upcoming) == text else { return false }
        index += text.count
        return true
    }

    func peek(_ character: Character) -> Bool {
        index < characters.count && characters[index] == character
    }
}
