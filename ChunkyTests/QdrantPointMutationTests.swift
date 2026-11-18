import Foundation
import QdrantCore
import Testing
@testable import Chunky

@MainActor
struct QdrantPointMutationTests {
    @Test func payloadEditsSendIntegerUUIDAndBoundaryIDsWithoutChangingTheirKinds() async throws {
        let recorder = MutationRecorder()
        let service = try await connectedService(recorder)
        let uuid = "bdefd408-de82-54f7-b74f-8478d8f689e9"
        try await service.setPayload(
            collectionName: "library",
            ids: ["0", "42", String(UInt64.max), uuid],
            fields: ["doc_title": "Updated title"]
        )
        #expect(recorder.payloadCollection == "library")
        #expect(recorder.payloadIDs == [.integer(0), .integer(42), .integer(UInt64.max), .uuid(uuid)])
        #expect(recorder.payload["doc_title"] == .string("Updated title"))
        await service.disconnect()
    }

    @Test func deletionSendsMixedIDsAndFullUnsignedRange() async throws {
        let recorder = MutationRecorder()
        let service = try await connectedService(recorder)
        let uuid = "bdefd408-de82-54f7-b74f-8478d8f689e9"
        try await service.deletePoints(collectionName: "library", ids: [uuid, "42", String(UInt64.max), "0"])
        #expect(recorder.deleteCollection == "library")
        #expect(recorder.deleteIDs == [.uuid(uuid), .integer(42), .integer(UInt64.max), .integer(0)])
        await service.disconnect()
    }

    @Test func emptyPayloadEditsDoNotSendAndMutationErrorsPropagate() async throws {
        let recorder = MutationRecorder()
        let service = try await connectedService(recorder)
        try await service.setPayload(collectionName: "library", ids: [], fields: ["title": "value"])
        try await service.setPayload(collectionName: "library", ids: ["42"], fields: [:])
        #expect(recorder.payloadCollection == nil)
        recorder.shouldFail = true
        await #expect(throws: MutationFailure.rejected) {
            try await service.setPayload(collectionName: "library", ids: ["42"], fields: ["title": "value"])
        }
        await #expect(throws: MutationFailure.rejected) {
            try await service.deletePoints(collectionName: "library", ids: ["42"])
        }
        await service.disconnect()
    }

    private func connectedService(_ recorder: MutationRecorder) async throws -> QdrantService {
        let handle = QdrantClientHandle(
            healthCheck: { HealthCheckResult(title: "fixture", version: "1.20.2") },
            close: {},
            setPayload: { collection, ids, payload in
                if recorder.shouldFail { throw MutationFailure.rejected }
                recorder.payloadCollection = collection
                recorder.payloadIDs = ids
                recorder.payload = payload
            },
            deletePoints: { collection, ids in
                if recorder.shouldFail { throw MutationFailure.rejected }
                recorder.deleteCollection = collection
                recorder.deleteIDs = ids
            }
        )
        let service = QdrantService(makeClient: { _ in handle })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        try await service.connect()
        return service
    }
}

@MainActor
private final class MutationRecorder {
    var payloadCollection: String?
    var payloadIDs: [PointID] = []
    var payload: [String: PayloadValue] = [:]
    var deleteCollection: String?
    var deleteIDs: [PointID] = []
    var shouldFail = false
}

private enum MutationFailure: Error, Equatable {
    case rejected
}
