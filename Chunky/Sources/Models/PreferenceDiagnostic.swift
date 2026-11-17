import Foundation

enum PreferenceDiagnostic {
    nonisolated static func message(_ message: String, secrets: [String]) -> String {
        var safe = RunHistory.redact(message, secrets: secrets)
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"]+", options: .caseInsensitive) else { return safe }
        for match in regex.matches(in: safe, range: NSRange(safe.startIndex..., in: safe)).reversed() {
            guard let range = Range(match.range, in: safe) else { continue }
            guard var url = URLComponents(string: String(safe[range])) else {
                safe.replaceSubrange(range, with: "[endpoint]")
                continue
            }
            url.user = nil
            url.password = nil
            url.query = nil
            url.fragment = nil
            safe.replaceSubrange(range, with: url.string ?? "[endpoint]")
        }
        return safe
    }

    nonisolated static func report(context: String, message: String, secrets: [String]) -> String {
        "Chunky — \(context)\n\(self.message(message, secrets: secrets))"
    }
}
