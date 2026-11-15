import Foundation

public struct QdrantConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let apiKey: String?
    public let useTLS: Bool
    public let timeout: Duration

    public init(
        host: String = "localhost",
        port: Int = 6334,
        apiKey: String? = nil,
        useTLS: Bool? = nil,
        timeout: Duration = .seconds(30)
    ) throws {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.timeout = timeout

        let isLocalhost = Self.isLocalhostAddress(host)

        if let explicitTLS = useTLS {

            if !explicitTLS && !isLocalhost {

                throw QdrantError.tlsRequiredForRemoteHost(host)
            }
            self.useTLS = explicitTLS
        } else {

            self.useTLS = !isLocalhost
        }
    }

    private static func isLocalhostAddress(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        return lowercased == "localhost"
            || lowercased == "127.0.0.1"
            || lowercased == "::1"
            || lowercased == "[::1]"
    }
}
