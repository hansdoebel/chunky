import Foundation
import Testing
@testable import Chunky

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
        let service = FastEmbedService(pythonPath: "/usr/bin/python3", scriptPath: script.path)
        defer { service.cancel() }
        let task = Task { try await service.prepare(model: FastEmbedService.model) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
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
}
