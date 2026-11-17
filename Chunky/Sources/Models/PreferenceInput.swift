import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum PreferenceInputError: LocalizedError, Equatable {
    case required(String)
    case singleLine(String)
    case endpointFormat
    case endpointWhitespace
    case endpointCredentials
    case endpointPort
    case endpointFragment
    case integerFormat(String)
    case integerRange(String, Int, Int)

    var errorDescription: String? {
        switch self {
        case .required(let label): return "Enter \(label.lowercased())."
        case .singleLine(let label): return "\(label) must be a single line without control characters."
        case .endpointFormat: return "Enter a complete HTTP or HTTPS URL with a host, such as http://localhost:6334."
        case .endpointWhitespace: return "Remove spaces inside the URL. Use percent-encoding for spaces in a path."
        case .endpointCredentials: return "Remove the username or password from the URL. Use the separate credential field."
        case .endpointPort: return "Use a port number from 1 to 65535, or omit the port."
        case .endpointFragment: return "Remove the #fragment from the server URL; it is not sent to the server."
        case .integerFormat(let label): return "\(label) must be a whole number without separators or decimals."
        case .integerRange(let label, let lower, let upper): return "\(label) must be between \(lower) and \(upper)."
        }
    }
}

enum PreferenceInput {
    static func endpoint(_ raw: String, allowEmpty: Bool = false) throws -> String {
        let value = try identifier(raw, label: "Server URL", allowEmpty: allowEmpty)
        if value.isEmpty { return value }
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw PreferenceInputError.endpointWhitespace
        }
        guard let separator = value.range(of: "://"),
            ["http", "https"].contains(value[..<separator.lowerBound].lowercased()) else {
            throw PreferenceInputError.endpointFormat
        }
        let normalized = value[..<separator.lowerBound].lowercased() + value[separator.lowerBound...]
        let authority = value[separator.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.contains("@") else { throw PreferenceInputError.endpointCredentials }
        try validatePort(authority)
        guard let url = URL(string: normalized, encodingInvalidCharacters: false),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty,
            !host.contains(where: { "/\\@?#".contains($0) }),
            !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
            components.user == nil, components.password == nil else {
            throw PreferenceInputError.endpointFormat
        }
        guard components.fragment == nil else { throw PreferenceInputError.endpointFragment }
        return normalized
    }

    static func identifier(_ raw: String, label: String = "Value", allowEmpty: Bool = false) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
            throw PreferenceInputError.singleLine(label)
        }
        guard allowEmpty || !value.isEmpty else { throw PreferenceInputError.required(label) }
        return value
    }

    static func integer(_ raw: String, range: ClosedRange<Int>, label: String = "Value") throws -> Int {
        let text = try identifier(raw, label: label)
        let digits = text.hasPrefix("-") ? text.dropFirst() : text[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw PreferenceInputError.integerFormat(label)
        }
        guard let value = Int(text), range.contains(value) else {
            throw PreferenceInputError.integerRange(label, range.lowerBound, range.upperBound)
        }
        return value
    }

    private static func validatePort(_ authority: Substring) throws {
        let suffix: Substring
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { throw PreferenceInputError.endpointFormat }
            let literal = String(authority[authority.index(after: authority.startIndex)..<closing])
            let parts = literal.components(separatedBy: "%25")
            guard parts.count <= 2,
                !parts[0].contains("%"),
                parts.count == 1 || (!parts[1].isEmpty && parts[1].utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 126].contains($0)
                })) else { throw PreferenceInputError.endpointFormat }
            var address = in6_addr()
            guard parts[0].withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw PreferenceInputError.endpointFormat
            }
            suffix = authority[authority.index(after: closing)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else { throw PreferenceInputError.endpointFormat }
        } else if let colon = authority.lastIndex(of: ":") {
            suffix = authority[colon...]
        } else {
            suffix = ""
        }
        guard !suffix.isEmpty else { return }
        let digits = suffix.dropFirst()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
            let port = Int(digits), (1...65535).contains(port) else {
            throw PreferenceInputError.endpointPort
        }
    }
}
