import Foundation
import QdrantCore

public final class RestSnapshotsService: Sendable {
    private let client: HTTPClient

    internal init(client: HTTPClient) {
        self.client = client
    }

    public func list(collection: String) async throws -> [SnapshotDescription] {
        let response: SnapshotListResponse = try await client.get(
            path: "/collections/\(collection)/snapshots"
        )
        return response.result ?? []
    }

    public func create(
        collection: String,
        wait: Bool = true
    ) async throws -> SnapshotDescription {
        let queryItems = [URLQueryItem(name: "wait", value: wait ? "true" : "false")]
        let response: SnapshotResponse = try await client.post(
            path: "/collections/\(collection)/snapshots",
            body: EmptyBody(),
            queryItems: queryItems
        )
        guard let result = response.result else {
            throw HTTPError.unexpectedResponse("No snapshot info returned")
        }
        return result
    }

    public func delete(
        collection: String,
        snapshot: String,
        wait: Bool = true
    ) async throws {
        let queryItems = [URLQueryItem(name: "wait", value: wait ? "true" : "false")]
        let _: OperationResponse = try await client.delete(
            path: "/collections/\(collection)/snapshots/\(snapshot)",
            queryItems: queryItems
        )
    }

    public func listFull() async throws -> [SnapshotDescription] {
        let response: SnapshotListResponse = try await client.get(path: "/snapshots")
        return response.result ?? []
    }

    public func createFull(wait: Bool = true) async throws -> SnapshotDescription {
        let queryItems = [URLQueryItem(name: "wait", value: wait ? "true" : "false")]
        let response: SnapshotResponse = try await client.post(
            path: "/snapshots",
            body: EmptyBody(),
            queryItems: queryItems
        )
        guard let result = response.result else {
            throw HTTPError.unexpectedResponse("No snapshot info returned")
        }
        return result
    }

    public func deleteFull(
        snapshot: String,
        wait: Bool = true
    ) async throws {
        let queryItems = [URLQueryItem(name: "wait", value: wait ? "true" : "false")]
        let _: OperationResponse = try await client.delete(
            path: "/snapshots/\(snapshot)",
            queryItems: queryItems
        )
    }
}

struct EmptyBody: Encodable {}

struct SnapshotListResponse: Codable {
    let result: [SnapshotDescription]?
}

struct SnapshotResponse: Codable {
    let result: SnapshotDescription?
}
