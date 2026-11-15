import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import QdrantCore
import QdrantProto

public typealias HealthCheckResult = QdrantCore.HealthCheckResult
public typealias SnapshotDescription = QdrantCore.SnapshotDescription
public typealias FieldType = QdrantCore.FieldType

public final class QdrantGRPCClient: Sendable {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let configuration: QdrantConfiguration
    private let runTask: Task<Void, any Error>

    private let _collections: CollectionsService
    private let _points: PointsService
    private let _snapshots: SnapshotsService

    public var collections: CollectionsService { _collections }

    public var points: PointsService { _points }

    public var snapshots: SnapshotsService { _snapshots }

    public init(configuration: QdrantConfiguration) async throws {
        self.configuration = configuration

        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: configuration.host, port: configuration.port),
            transportSecurity: configuration.useTLS ? .tls : .plaintext
        )

        let client = GRPCClient(transport: transport)
        self.grpcClient = client

        self.runTask = Task {
            try await client.runConnections()
        }

        self._collections = CollectionsService(client: grpcClient, apiKey: configuration.apiKey)
        self._points = PointsService(client: grpcClient, apiKey: configuration.apiKey)
        self._snapshots = SnapshotsService(client: grpcClient, apiKey: configuration.apiKey)
    }

    public convenience init(
        host: String = "localhost",
        port: Int = 6334,
        apiKey: String? = nil,
        useTLS: Bool? = nil
    ) async throws {
        let config = try QdrantConfiguration(
            host: host,
            port: port,
            apiKey: apiKey,
            useTLS: useTLS
        )
        try await self.init(configuration: config)
    }

    public func close() {
        grpcClient.beginGracefulShutdown()
        runTask.cancel()
    }

    public func healthCheck() async throws -> HealthCheckResult {
        let client = Qdrant_Qdrant.Client(wrapping: grpcClient)

        var metadata = Metadata()
        if let apiKey = configuration.apiKey {
            metadata.addString(apiKey, forKey: "api-key")
        }

        let request = ClientRequest(message: Qdrant_HealthCheckRequest(), metadata: metadata)
        let response: Qdrant_HealthCheckReply = try await client.healthCheck(request: request)

        return HealthCheckResult(
            title: response.title,
            version: response.version,
            commit: response.hasCommit ? response.commit : nil
        )
    }
}
