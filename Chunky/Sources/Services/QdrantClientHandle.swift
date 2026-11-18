import Foundation
import QdrantCore
import QdrantGRPC

@MainActor
final class QdrantClientHandle {
    let client: QdrantGRPCClient?
    let healthCheck: () async throws -> HealthCheckResult
    let createFieldIndex: (String, String, FieldType, Bool) async throws -> Void
    let deleteCollection: (String) async throws -> Void
    let setPayload: (String, [PointID], [String: PayloadValue]) async throws -> Void
    let deletePoints: (String, [PointID]) async throws -> Void
    private let closeAction: () -> Void
    private var closed = false

    init(
        client: QdrantGRPCClient? = nil,
        healthCheck: @escaping () async throws -> HealthCheckResult,
        close: @escaping () -> Void,
        createFieldIndex: @escaping (String, String, FieldType, Bool) async throws -> Void = { _, _, _, _ in throw QdrantServiceError.notConnected },
        deleteCollection: @escaping (String) async throws -> Void = { _ in throw QdrantServiceError.notConnected },
        setPayload: @escaping (String, [PointID], [String: PayloadValue]) async throws -> Void = { _, _, _ in throw QdrantServiceError.notConnected },
        deletePoints: @escaping (String, [PointID]) async throws -> Void = { _, _ in throw QdrantServiceError.notConnected }
    ) {
        self.client = client
        self.healthCheck = healthCheck
        self.closeAction = close
        self.createFieldIndex = createFieldIndex
        self.deleteCollection = deleteCollection
        self.setPayload = setPayload
        self.deletePoints = deletePoints
    }

    isolated deinit {
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        closeAction()
    }

    static func live(configuration: QdrantConfiguration) async throws -> QdrantClientHandle {
        let client = try await QdrantGRPCClient(configuration: configuration)
        return QdrantClientHandle(
            client: client,
            healthCheck: { try await client.healthCheck() },
            close: { client.close() },
            createFieldIndex: { collection, field, type, tenant in
                try await client.points.createFieldIndex(collection: collection, fieldName: field, fieldType: type, wait: true, isTenant: tenant)
            },
            deleteCollection: { try await client.collections.delete(name: $0) },
            setPayload: { collection, ids, payload in
                try await client.points.setPayload(collection: collection, ids: ids, payload: payload, wait: true)
            },
            deletePoints: { collection, ids in
                try await client.points.delete(collection: collection, ids: ids, wait: true)
            }
        )
    }
}
