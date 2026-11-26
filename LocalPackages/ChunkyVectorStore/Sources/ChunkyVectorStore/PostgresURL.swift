import Foundation

public struct PostgresConnectionTarget: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var database: String
    public var tls: Bool

    public var redacted: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let tlsNote = tls ? " tls" : ""
        return "postgresql://\(user)\(host):\(port)/\(database)\(tlsNote)"
    }
}

public enum PostgresURLError: Error, Equatable, Sendable {
    case invalid(String)
}

public enum PostgresURL {
    public static func parse(_ raw: String) throws -> PostgresConnectionTarget {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = split(value) else {
            throw PostgresURLError.invalid("pgvector requires a postgresql:// URL without a fragment")
        }
        if parts.fragment != nil {
            throw PostgresURLError.invalid("pgvector requires a postgresql:// URL without a fragment")
        }
        guard parts.scheme == "postgresql" || parts.scheme == "postgres", let host = parts.host, !host.isEmpty else {
            throw PostgresURLError.invalid("pgvector requires a postgresql:// URL without a fragment")
        }
        let database = parts.database.isEmpty ? "postgres" : parts.database
        let tls = parts.query["sslmode"] == "require" || parts.query["sslmode"] == "verify-full" || parts.query["sslmode"] == "verify-ca"
        return PostgresConnectionTarget(
            host: host,
            port: parts.port ?? 5432,
            username: parts.username ?? "",
            password: parts.password ?? "",
            database: database,
            tls: tls
        )
    }

    public static func validateHTTP(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw PostgresURLError.invalid("Vector store URL must be an http(s) URL without credentials, query, or fragment")
        }
        return value
    }
}

private struct URLParts {
    var scheme: String
    var username: String?
    var password: String?
    var host: String?
    var port: Int?
    var database: String
    var query: [String: String]
    var fragment: String?
}

private func split(_ raw: String) -> URLParts? {
    guard let schemeEnd = raw.range(of: "://") else { return nil }
    let scheme = String(raw[..<schemeEnd.lowerBound]).lowercased()
    var rest = String(raw[schemeEnd.upperBound...])
    var fragment: String?
    if let hash = rest.firstIndex(of: "#") {
        fragment = String(rest[rest.index(after: hash)...])
        rest = String(rest[..<hash])
    }
    var query: [String: String] = [:]
    if let question = rest.firstIndex(of: "?") {
        let queryText = String(rest[rest.index(after: question)...])
        rest = String(rest[..<question])
        for item in queryText.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                query[pair[0]] = decode(pair[1])
            }
        }
    }
    var username: String?
    var password: String?
    if let at = rest.lastIndex(of: "@") {
        let userinfo = String(rest[..<at])
        rest = String(rest[rest.index(after: at)...])
        if let colon = userinfo.firstIndex(of: ":") {
            username = decode(String(userinfo[..<colon]))
            password = decode(String(userinfo[userinfo.index(after: colon)...]))
        } else {
            username = decode(userinfo)
        }
    }
    var host: String?
    var port: Int?
    var database = ""
    if rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
        host = String(rest[rest.index(after: rest.startIndex)..<end])
        let tail = String(rest[rest.index(after: end)...])
        if tail.hasPrefix(":"), let slash = tail.firstIndex(of: "/") {
            port = Int(tail[tail.index(after: tail.startIndex)..<slash])
            database = String(tail[tail.index(after: slash)...])
        } else if tail.hasPrefix("/") {
            database = String(tail.dropFirst())
        }
    } else if let slash = rest.firstIndex(of: "/") {
        let authority = String(rest[..<slash])
        database = String(rest[rest.index(after: slash)...])
        if let colon = authority.lastIndex(of: ":"), colon != authority.startIndex {
            host = String(authority[..<colon])
            port = Int(authority[authority.index(after: colon)...])
        } else {
            host = authority
        }
    } else {
        host = rest
    }
    return URLParts(scheme: scheme, username: username, password: password, host: host, port: port, database: database, query: query, fragment: fragment)
}

private func decode(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}
