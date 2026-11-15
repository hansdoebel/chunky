import Foundation

struct IntegrationTestConfig {
    let url: String
    let apiKey: String?
    let testCollection: String

    var isLocal: Bool {
        url.contains("localhost") || url.contains("127.0.0.1")
    }

    static func load() throws -> IntegrationTestConfig {

        if let url = ProcessInfo.processInfo.environment["QDRANT_URL"] {
            let apiKey = ProcessInfo.processInfo.environment["QDRANT_API_KEY"]
            let collection =
                ProcessInfo.processInfo.environment["QDRANT_TEST_COLLECTION"] ?? "test-collection"
            return IntegrationTestConfig(
                url: url,
                apiKey: apiKey?.isEmpty == true ? nil : apiKey,
                testCollection: collection
            )
        }

        let envPath = findEnvFile()
        guard let envPath = envPath else {
            throw ConfigError.envFileNotFound
        }

        let envContent = try String(contentsOfFile: envPath, encoding: .utf8)
        var env: [String: String] = [:]

        for line in envContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(
                in: .whitespaces)
            env[key] = value
        }

        guard let url = env["QDRANT_URL"] else {
            throw ConfigError.missingRequiredKeys
        }

        let apiKey = env["QDRANT_API_KEY"]
        let collection = env["QDRANT_TEST_COLLECTION"] ?? "test-collection"

        return IntegrationTestConfig(
            url: url,
            apiKey: apiKey?.isEmpty == true ? nil : apiKey,
            testCollection: collection
        )
    }

    private static func findEnvFile() -> String? {

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath

        let possiblePaths = [
            "\(currentDir)/.env",
            "\(currentDir)/../.env",
            "\(currentDir)/../../.env",
            "\(currentDir)/../../../.env",
        ]

        for path in possiblePaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    enum ConfigError: Error, CustomStringConvertible {
        case envFileNotFound
        case missingRequiredKeys

        var description: String {
            switch self {
            case .envFileNotFound:
                return
                    "Could not find .env file. Set QDRANT_URL environment variable (QDRANT_API_KEY and QDRANT_TEST_COLLECTION are optional for local Docker)."
            case .missingRequiredKeys:
                return
                    "Missing required key in .env file: QDRANT_URL"
            }
        }
    }
}
