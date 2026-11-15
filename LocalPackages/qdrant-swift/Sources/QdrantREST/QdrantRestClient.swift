import Foundation
import QdrantCore

public final class QdrantRESTClient: Sendable {
    private let httpClient: HTTPClient

    private let _collections: RestCollectionsService
    private let _points: RestPointsService
    private let _snapshots: RestSnapshotsService

    public var collections: RestCollectionsService { _collections }

    public var points: RestPointsService { _points }

    public var snapshots: RestSnapshotsService { _snapshots }

    public init(
        host: String = "localhost",
        port: Int = 6333,
        useTLS: Bool? = nil,
        apiKey: String? = nil,
        session: URLSession = .shared
    ) throws {
        let isLocalhost = Self.isLocalhostAddress(host)
        let shouldUseTLS: Bool

        if let explicitTLS = useTLS {

            if !explicitTLS && !isLocalhost {

                throw HTTPError.tlsRequiredForRemoteHost(host)
            }
            shouldUseTLS = explicitTLS
        } else {

            shouldUseTLS = !isLocalhost
        }

        self.httpClient = try HTTPClient(
            host: host,
            port: port,
            useTLS: shouldUseTLS,
            apiKey: apiKey,
            session: session
        )

        self._collections = RestCollectionsService(client: httpClient)
        self._points = RestPointsService(client: httpClient)
        self._snapshots = RestSnapshotsService(client: httpClient)
    }

    private static func isLocalhostAddress(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        return lowercased == "localhost"
            || lowercased == "127.0.0.1"
            || lowercased == "::1"
            || lowercased == "[::1]"
    }

    public func healthCheck() async throws -> RestHealthCheckResult {
        try await httpClient.get(path: "/healthz")
    }

    public func telemetry() async throws -> TelemetryResponse {
        try await httpClient.get(path: "/telemetry")
    }

    public func metrics() async throws -> String {
        try await httpClient.getText(path: "/metrics")
    }

    public func issues() async throws -> [QdrantIssue] {
        let response: IssuesResponse = try await httpClient.get(path: "/issues")
        return response.result?.issues ?? []
    }

    public func clearIssues() async throws {
        let _: ClearIssuesResponse = try await httpClient.delete(path: "/issues")
    }
}

struct IssuesResponse: Codable {
    let result: IssuesResult?

    struct IssuesResult: Codable {
        let issues: [QdrantIssue]
    }
}

struct ClearIssuesResponse: Codable {
    let result: Bool?
}

public struct RestHealthCheckResult: Codable, Sendable {

    public let title: String?

    public let version: String?
}

public struct TelemetryResponse: Codable, Sendable {

    public let result: TelemetryData?
}

public struct TelemetryData: Codable, Sendable {

    public let app: AppInfo?

    public struct AppInfo: Codable, Sendable {

        public let name: String?

        public let version: String?
    }
}
