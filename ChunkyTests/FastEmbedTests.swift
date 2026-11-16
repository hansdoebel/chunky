import Foundation
import Testing
@testable import Chunky

@MainActor
struct FastEmbedTests {
    @Test func unknownCollectionCannotReuseCPUVectorSpace() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        #expect(throws: NSError.self) {
            try FastEmbedCollectionIdentity.validate(collection: "legacy", backend: "fastembed", model: FastEmbedService.model, defaults: defaults)
        }
    }

    @Test func existingProvidersRemainAvailableWithoutCPUPlan() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        try FastEmbedCollectionIdentity.validate(collection: "legacy", backend: "ollama", model: "qwen3-embedding:0.6b", defaults: defaults)
        try FastEmbedCollectionIdentity.validate(collection: "legacy", backend: "openai", model: "model", defaults: defaults)
    }

    @Test func unsupportedCPUModelFailsBeforeStartingProcess() async {
        do {
            _ = try await FastEmbedService.shared.embed(texts: ["text"], model: "stella")
            Issue.record("Expected unsupported model to fail")
        } catch {
            #expect(error.localizedDescription.contains(FastEmbedService.model))
        }
    }

    @Test func emptyBatchDoesNotStartPython() async throws {
        let vectors = try await FastEmbedService.shared.embed(texts: [], model: FastEmbedService.model)
        #expect(vectors.isEmpty)
    }

    @Test func cpuSelectionPreservesCloudDestinationUntilRejected() {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .qdrantCloud
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io"
        settings.embeddingBackend = "fastembed"
        settings.embeddingModel = FastEmbedService.model
        let request = RetrievalRequest.make(text: "paper", collection: "cpu", limit: 10, settings: settings)
        #expect(request.route == .worker)
        #expect(request.qdrantURL == settings.qdrantCloudURL)
    }

    @Test func aDifferentProviderCannotDispatchToACPUCollectionOnTheWorker() async {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .qdrantCloud
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io"
        settings.embeddingBackend = "openai"
        settings.embeddingModel = "different-512-model"
        settings.embeddingDimensions = 512
        let plan = CollectionPlan.preset(
            .largeCloud,
            name: settings.defaultCollection,
            vectorSize: FastEmbedService.dimensions,
            embeddingBackend: "fastembed",
            embeddingModel: FastEmbedService.model
        )
        CollectionPlanStore.save(plan, defaults: settings.defaults)
        var workerRuns = 0
        var preflights = 0
        let processor = DocumentProcessor(
            fallbackPreflight: { _ in preflights += 1 },
            workerRunner: { _, _, _ in workerRuns += 1 }
        )
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        await processor.process(job: job, settings: settings, mode: .full)
        #expect(workerRuns == 0)
        #expect(preflights == 0)
        #expect(job.status == .failed)
        #expect(job.error?.contains("matching local CPU model plan") == true)
    }

    @Test func chunkOnlyCanUseTheWorkerWithACPUCollectionSelected() async {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.embeddingBackend = "fastembed"
        settings.embeddingModel = FastEmbedService.model
        var workerRuns = 0
        let processor = DocumentProcessor(workerRunner: { job, _, _ in
            workerRuns += 1
            job.status = .completed
        })
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        await processor.process(job: job, settings: settings, mode: .chunkOnly)
        #expect(workerRuns == 1)
        #expect(job.status == .completed)
    }

    @Test func numbersThatOverflowFloatAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("runtime.py")
        let source = """
        import sys,json
        for line in sys.stdin:
            print(json.dumps({'model':'minishlab/potion-retrieval-32M','dimensions':512,'vectors':[[1e300]*512]}),flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let service = try FastEmbedService(pythonPath: pythonPath(), scriptPath: script.path)
        defer { service.cancel() }
        do {
            _ = try await service.embed(texts: ["paper"], model: FastEmbedService.model)
            Issue.record("Expected Float overflow to reject the vector")
        } catch {
            #expect(error.localizedDescription.contains("Invalid local CPU model identity or vector dimensions"))
        }
    }

    @Test func cancellationSurfacesAsCancellationAndProcessRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("runtime.py")
        let marker = directory.appendingPathComponent("started")
        let source = """
        import sys,json,time,pathlib
        for line in sys.stdin:
            request=json.loads(line)
            if request['command']=='prepare':
                pathlib.Path(__file__).with_name('started').touch()
                time.sleep(30)
            print(json.dumps({'status':'Ready'}),flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let service = try FastEmbedService(pythonPath: pythonPath(), scriptPath: script.path)
        defer { service.cancel() }
        let task = Task { try await service.prepare(model: FastEmbedService.model) }
        try await waitForMarker(marker)
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        let status = try await service.health(model: FastEmbedService.model)
        #expect(status == "Ready")
    }

    @Test func cancellingAQueuedRequestDoesNotInterruptTheActiveRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("runtime.py")
        let marker = directory.appendingPathComponent("started")
        let source = """
        import sys,json,time,pathlib
        for line in sys.stdin:
            pathlib.Path(__file__).with_name('started').touch()
            time.sleep(0.5)
            print(json.dumps({'status':'Ready'}),flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let service = try FastEmbedService(pythonPath: pythonPath(), scriptPath: script.path)
        defer { service.cancel() }
        let active = Task { try await service.health(model: FastEmbedService.model) }
        try await waitForMarker(marker)
        let queued = Task { try await service.prepare(model: FastEmbedService.model) }
        queued.cancel()
        #expect(try await active.value == "Ready")
        do {
            try await queued.value
            Issue.record("Expected queued request cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(try await service.health(model: FastEmbedService.model) == "Ready")
    }

    private func pythonPath() throws -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            + path.split(separator: ":").map { String($0) + "/python3" }
        return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func waitForMarker(_ marker: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
    }
}
