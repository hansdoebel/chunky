import Foundation
import QdrantCore
import QdrantGRPC
import Testing
@testable import Chunky

@MainActor
private final class HealthGate {
    private var continuation: CheckedContinuation<HealthCheckResult, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func wait() async throws -> HealthCheckResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            hasStarted = true
            started?.resume()
            started = nil
        }
    }

    func waitForStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume(returning: HealthCheckResult(title: "test", version: "old"))
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
struct QdrantLifecycleTests {
    @Test func failedHealthClosesUncommittedClientAndRedactsError() async throws {
        var closes = 0
        let handle = QdrantClientHandle(healthCheck: { throw QdrantError.unavailable("fixture-secret") }, close: { closes += 1 })
        let service = QdrantService(makeClient: { _ in handle })
        try await service.configure(url: "http://localhost:6334", apiKey: "fixture-secret")
        await #expect(throws: Error.self) { try await service.connect() }
        #expect(closes == 1)
        #expect(!service.isConnected)
        #expect(service.serverVersion == nil)
        #expect(service.connectionError?.contains("fixture-secret") == false)
        await service.disconnect()
        #expect(closes == 1)
    }

    @Test func releasingServiceClosesCommittedClient() async throws {
        var closes = 0
        var service: QdrantService? = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: { closes += 1 })
        })
        try await service?.configure(url: "http://localhost:6334", apiKey: nil)
        try await service?.connect()
        #expect(service?.isConnected == true)
        service = nil
        #expect(closes == 1)
    }

    @Test func disconnectedAttemptCannotPublishLateHealth() async throws {
        let gate = HealthGate()
        var closes = 0
        let handle = QdrantClientHandle(healthCheck: { try await gate.wait() }, close: { closes += 1 })
        let service = QdrantService(makeClient: { _ in handle })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        let attempt = Task { try await service.connect() }
        await gate.waitForStart()
        await service.disconnect()
        #expect(closes == 1)
        gate.finish()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(!service.isConnected)
        #expect(service.serverVersion == nil)
        #expect(service.connectionError == nil)
        #expect(closes == 1)
    }

    @Test func reconfigurationCannotBeOverwrittenByOldAttempt() async throws {
        let gate = HealthGate()
        var oldCloses = 0
        let old = QdrantClientHandle(healthCheck: { try await gate.wait() }, close: { oldCloses += 1 })
        let new = QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "new") }, close: {})
        let service = QdrantService(makeClient: { config in config.host == "localhost" ? old : new })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        let attempt = Task { try await service.connect() }
        await gate.waitForStart()
        try await service.configure(url: "http://127.0.0.1:6334", apiKey: nil)
        try await service.connect()
        gate.finish()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(service.isConnected)
        #expect(service.serverVersion == "new")
        #expect(service.connectionError == nil)
        #expect(oldCloses == 1)
    }

    @Test func callerCancellationClosesCandidate() async throws {
        let gate = HealthGate()
        var closes = 0
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { try await gate.wait() }, close: { closes += 1 })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        let attempt = Task { try await service.connect() }
        await gate.waitForStart()
        attempt.cancel()
        gate.finish()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(closes == 1)
        #expect(!service.isConnected)
        #expect(service.connectionError == nil)
    }

    @Test func factoryResultAfterDisconnectIsClosedBeforeHealth() async throws {
        let gate = HealthGate()
        var closes = 0
        var healthCalls = 0
        let service = QdrantService(makeClient: { _ in
            _ = try await gate.wait()
            return QdrantClientHandle(healthCheck: {
                healthCalls += 1
                return HealthCheckResult(title: "test", version: "1")
            }, close: { closes += 1 })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        let attempt = Task { try await service.connect() }
        await gate.waitForStart()
        await service.disconnect()
        gate.finish()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(closes == 1)
        #expect(healthCalls == 0)
    }

    @Test func indexFailureRetriesAndSuccessfulReadinessIsCached() async throws {
        var calls = 0
        var fail = true
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: {},
                createFieldIndex: { _, _, _, _ in
                    calls += 1
                    if fail { throw QdrantError.permissionDenied("fixture-secret") }
                })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: "fixture-secret")
        try await service.connect()
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 1)
        #expect(service.indexError != nil)
        #expect(service.indexError?.contains("fixture-secret") == false)
        fail = false
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 18)
        #expect(service.indexError == nil)
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 18)
        await service.disconnect()
        try await service.connect()
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 35)
    }

    @Test func deletionInvalidatesOnlyDeletedCollectionReadiness() async throws {
        var calls: [String: Int] = [:]
        var deleted: [String] = []
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: {},
                createFieldIndex: { collection, _, _, _ in calls[collection, default: 0] += 1 },
                deleteCollection: { deleted.append($0) })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        try await service.connect()
        await service.ensureRetrievalIndexes(collection: "a")
        await service.ensureRetrievalIndexes(collection: "b")
        try await service.deleteCollection("a")
        await service.ensureRetrievalIndexes(collection: "a")
        await service.ensureRetrievalIndexes(collection: "b")
        #expect(deleted == ["a"])
        #expect(calls["a"] == 34)
        #expect(calls["b"] == 17)
    }

    @Test func deletionDuringIndexingCannotCacheStaleReadiness() async throws {
        let gate = HealthGate()
        var calls = 0
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: {},
                createFieldIndex: { _, _, _, _ in
                    calls += 1
                    if calls == 1 { _ = try await gate.wait() }
                }, deleteCollection: { _ in })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        try await service.connect()
        let indexing = Task { await service.ensureRetrievalIndexes(collection: "docs") }
        await gate.waitForStart()
        try await service.deleteCollection("docs")
        gate.finish()
        await indexing.value
        #expect(service.indexError == nil)
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 18)
    }

    @Test func indexesCompletedDuringDeletionAreInvalidatedWhenDeleteFinishes() async throws {
        let gate = HealthGate()
        var calls = 0
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: {},
                createFieldIndex: { _, _, _, _ in calls += 1 },
                deleteCollection: { _ in _ = try await gate.wait() })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        try await service.connect()
        let deletion = Task { try await service.deleteCollection("docs") }
        await gate.waitForStart()
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 17)
        gate.finish()
        try await deletion.value
        await service.ensureRetrievalIndexes(collection: "docs")
        #expect(calls == 34)
    }

    @Test func indexFailureRedactsTheCredentialUsedBeforeReconfiguration() async throws {
        let gate = HealthGate()
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: {},
                createFieldIndex: { _, _, _, _ in _ = try await gate.wait() })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: "old-fixture-secret")
        try await service.connect()
        let indexing = Task { try await service.createPayloadIndexes(collection: "docs") }
        await gate.waitForStart()
        try await service.configure(url: "http://127.0.0.1:6334", apiKey: "new-fixture-secret")
        gate.fail(QdrantError.unavailable("old-fixture-secret"))
        do {
            try await indexing.value
            Issue.record("Expected index failure")
        } catch {
            #expect(!error.localizedDescription.contains("old-fixture-secret"))
        }
        #expect(service.indexError == nil)
    }

    @Test func typedAlreadyExistsIsAcceptedButSimilarFailureIsNot() async throws {
        var alreadyExists = true
        var calls = 0
        let service = QdrantService(makeClient: { _ in
            QdrantClientHandle(healthCheck: { HealthCheckResult(title: "test", version: "1") }, close: {},
                createFieldIndex: { _, _, _, _ in
                    calls += 1
                    if alreadyExists { throw QdrantError.collectionAlreadyExists("index") }
                    throw QdrantError.permissionDenied("already exists but unauthorized")
                })
        })
        try await service.configure(url: "http://localhost:6334", apiKey: nil)
        try await service.connect()
        await service.ensureRetrievalIndexes(collection: "a")
        #expect(calls == 17)
        #expect(service.indexError == nil)
        alreadyExists = false
        await service.ensureRetrievalIndexes(collection: "b")
        #expect(calls == 18)
        #expect(service.indexError?.contains("unauthorized") == true)
    }
}
