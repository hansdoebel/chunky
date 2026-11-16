import Foundation
import Testing

@testable import Chunky

@MainActor
struct LocalFallbackTests {
    @Test func fallbackIsOffByDefaultAndPersistsExplicitOptIn() {
        let settings = IsolatedSettings.make()
        #expect(!settings.allowLocalFallback)
        settings.allowLocalFallback = true
        let reloaded = AppSettings(defaults: settings.defaults, secrets: MemorySecretStore())
        #expect(reloaded.allowLocalFallback)
    }

    @Test func fallbackSnapshotDoesNotRegisterDefaultsForOtherSettings() throws {
        let original = configuredSettings()
        original.embeddingModel = "snapshot-only-model"
        original.maxTokensPerChunk = 733
        let unrelated = IsolatedSettings.make()
        let priorModel = unrelated.embeddingModel
        let priorTokens = unrelated.maxTokensPerChunk
        let registration = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary
        let plan = try LocalFallbackPlan.make(from: original, mode: .chunkOnly, collection: original.defaultCollection)
        #expect(plan.settings.embeddingModel == "snapshot-only-model")
        #expect(plan.settings.maxTokensPerChunk == 733)
        #expect(CollectionPlanStore.load(name: original.defaultCollection, defaults: plan.settings.defaults) != nil)
        plan.discard()
        #expect(registration.isEqual(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary))
        let reloaded = AppSettings(defaults: unrelated.defaults, secrets: MemorySecretStore())
        #expect(!reloaded.allowLocalFallback)
        #expect(reloaded.embeddingModel == priorModel)
        #expect(reloaded.maxTokensPerChunk == priorTokens)
        #expect(!IsolatedSettings.make().allowLocalFallback)
    }

    @Test func fallbackOnlyAcceptsTransportUnreachabilityAndLiteralLoopback() {
        for code in [URLError.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost, .timedOut] {
            #expect(LocalFallbackPolicy.isUnreachable(URLError(code)))
        }
        for code in [URLError.cancelled, .appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted, .badURL, .cannotDecodeContentData] {
            #expect(!LocalFallbackPolicy.isUnreachable(URLError(code)))
        }
        #expect(!LocalFallbackPolicy.isUnreachable(DevboxClientError.unauthorized(url: "http://worker")))
        for url in ["http://localhost:11434", "https://127.0.0.1:6334", "http://[::1]:6334"] {
            #expect(LocalFallbackPolicy.isLoopback(url))
        }
        for url in ["https://qdrant.example", "http://127.0.0.1.example", "http://192.0.2.1", "ftp://localhost", "http://key@localhost"] {
            #expect(!LocalFallbackPolicy.isLoopback(url))
        }
    }

    @Test func snapshotPreservesSettingsAndProfilesWithoutCloudSecrets() throws {
        let settings = configuredSettings()
        settings.workerToken = "worker-secret"
        settings.qdrantCloudURL = "https://qdrant.example"
        settings.chatAPIKey = "chat-secret"
        settings.chatModel = "remote-summary-model"
        let endpoints = settings.workerEndpoints()
        settings.setWorkerEndpointToken(id: endpoints[0].id, "profile-secret")
        let before = settings.defaults.dictionaryRepresentation() as NSDictionary
        let plan = try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        defer { plan.discard() }
        #expect(plan.settings.processingHost == .localMac)
        #expect(!plan.settings.allowLocalFallback)
        #expect(plan.settings.doclingModel == DoclingModel.graniteDoclingMLX.rawValue)
        #expect(plan.settings.doclingAccelerator == ProcessingHost.localMac.defaultAccelerator.rawValue)
        #expect(plan.settings.ollamaURL == settings.ollamaURL)
        #expect(plan.settings.qdrantURL == settings.qdrantURL)
        #expect(plan.settings.embeddingModel == settings.embeddingModel)
        #expect(plan.settings.embeddingDimensions == settings.embeddingDimensions)
        #expect(plan.settings.workerToken.isEmpty)
        #expect(plan.settings.devboxWorkerURL.isEmpty)
        #expect(plan.settings.qdrantAPIKey.isEmpty)
        #expect(plan.settings.qdrantCloudURL.isEmpty)
        #expect(plan.settings.chatAPIKey.isEmpty)
        #expect(plan.settings.chatModel.isEmpty)
        #expect(plan.settings.workerEndpointToken(id: endpoints[0].id).isEmpty)
        #expect(!plan.settings.enableEmbeddingCache)
        #expect(before.isEqual(settings.defaults.dictionaryRepresentation() as NSDictionary))
        #expect(settings.workerToken == "worker-secret")
        #expect(settings.workerEndpointToken(id: endpoints[0].id) == "profile-secret")
        #expect(settings.processingHost == .devbox)
        #expect(plan.cacheDirectory != ChunkCacheLocation.macDirectory())
    }

    @Test func cloudRemoteAndMismatchedCollectionSettingsCannotFallback() throws {
        let settings = configuredSettings()
        settings.qdrantAPIKey = "cloud-secret"
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        }
        settings.qdrantAPIKey = ""
        settings.qdrantURL = "https://qdrant.example"
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        }
        settings.qdrantURL = "http://localhost:6334"
        var saved = try #require(CollectionPlanStore.load(name: settings.defaultCollection, defaults: settings.defaults))
        saved.target = .qdrantCloud
        CollectionPlanStore.save(saved, defaults: settings.defaults)
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        }
        saved.target = .localDocker
        saved.embeddingModel = "different-model"
        CollectionPlanStore.save(saved, defaults: settings.defaults)
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        }
        saved.embeddingModel = settings.embeddingModel
        saved.vectorSize += 1
        CollectionPlanStore.save(saved, defaults: settings.defaults)
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        }
        settings.ollamaURL = "http://worker:11434"
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .full, collection: settings.defaultCollection)
        }
    }

    @Test func chunkOnlyDoesNotRequireUnusedEmbeddingOrVLMServers() throws {
        let settings = configuredSettings()
        settings.ollamaURL = "http://worker:11434"
        settings.embeddingBackend = EmbeddingBackendKind.openai.rawValue
        settings.embeddingAPIURL = "https://embedding.example"
        settings.vlmServerURL = "https://unused-vlm.example"
        settings.doclingModel = DoclingModel.graniteDoclingMLX.rawValue
        settings.doPictureDescription = false
        let plan = try LocalFallbackPlan.make(from: settings, mode: .chunkOnly, collection: settings.defaultCollection)
        defer { plan.discard() }
        #expect(plan.settings.processingHost == .localMac)
        #expect(plan.settings.doclingModel == DoclingModel.graniteDoclingMLX.rawValue)
        #expect(plan.settings.embeddingAPIURL.isEmpty)
        #expect(plan.settings.vlmServerURL.isEmpty)
        #expect(settings.ollamaURL == "http://worker:11434")
        #expect(settings.vlmServerURL == "https://unused-vlm.example")
        settings.doPictureDescription = true
        settings.pictureDescriptionPreset = PictureDescriptionPreset.api.rawValue
        #expect(throws: LocalFallbackError.self) {
            try LocalFallbackPlan.make(from: settings, mode: .chunkOnly, collection: settings.defaultCollection)
        }
    }

    @Test func workerPreflightMakesTheQueueJobActiveBeforeSuspending() async {
        let settings = configuredSettings()
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        let processor = DocumentProcessor(
            fallbackPreflight: { _ in
                await withCheckedContinuation { continuation in
                    release = continuation
                    signal.yield(())
                }
            },
            workerRunner: { job, _, _ in job.status = .completed }
        )
        let processing = Task { await processor.process(job: job, settings: settings, mode: .full) }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        #expect(job.status == .chunking)
        #expect(job.statusMessage == "Checking worker before upload...")
        #expect(job.status != .pending && job.status != .completed && job.status != .failed)
        release?.resume()
        signal.finish()
        await processing.value
        #expect(job.status == .completed)
    }

    @Test func disabledFallbackNeverPreflightsOrStartsLocalWork() async {
        let settings = configuredSettings()
        settings.allowLocalFallback = false
        var localRuns = 0
        var workerRuns = 0
        var preflights = 0
        let processor = DocumentProcessor(
            fallbackPreflight: { _ in preflights += 1; throw URLError(.cannotConnectToHost) },
            fallbackRunner: { _, _, _ in localRuns += 1 },
            workerRunner: { job, _, _ in
                workerRuns += 1
                job.status = .failed
                job.error = "Cannot reach worker"
            }
        )
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        await processor.process(job: job, settings: settings, mode: .full)
        #expect(preflights == 0)
        #expect(localRuns == 0)
        #expect(workerRuns == 1)
        #expect(job.localFallbackNotice == nil)
        #expect(job.error == "Cannot reach worker")
    }

    @Test func unreachablePreflightRunsLocallyAndRecordsActualHost() async {
        let settings = configuredSettings()
        var localRuns = 0
        var workerRuns = 0
        let processor = DocumentProcessor(
            fallbackPreflight: { _ in throw URLError(.cannotConnectToHost) },
            fallbackRunner: { job, local, _ in
                localRuns += 1
                #expect(job.localFallbackNotice?.contains("Local Mac") == true)
                #expect(local.processingHost == .localMac)
                #expect(local.qdrantAPIKey.isEmpty)
                #expect(local.workerToken.isEmpty)
                job.metrics = JobMetrics.record(job: job, settings: local, host: local.processingHost.rawValue)
                job.status = .completed
            },
            workerRunner: { _, _, _ in workerRuns += 1 }
        )
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        await processor.process(job: job, settings: settings, mode: .full)
        #expect(localRuns == 1)
        #expect(workerRuns == 0)
        #expect(job.metrics?.host == ProcessingHost.localMac.rawValue)
        #expect(!job.ingestCloud)
        #expect(job.ingestCollection == settings.defaultCollection)
        #expect(settings.processingHost == .devbox)
    }

    @Test func authHTTPAndCancellationFailuresNeverTriggerFallback() async {
        let errors: [Error] = [
            DevboxClientError.unauthorized(url: "http://worker"),
            DevboxClientError.http(url: "http://worker", status: 503, detail: "Unavailable"),
            URLError(.cancelled), URLError(.appTransportSecurityRequiresSecureConnection),
        ]
        for error in errors {
            var localRuns = 0
            var workerRuns = 0
            let processor = DocumentProcessor(
                fallbackPreflight: { _ in throw error },
                fallbackRunner: { _, _, _ in localRuns += 1 },
                workerRunner: { _, _, _ in workerRuns += 1 }
            )
            let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
            await processor.process(job: job, settings: configuredSettings(), mode: .full)
            #expect(localRuns == 0)
            #expect(workerRuns == 0)
            #expect(job.status == .failed)
        }
    }

    @Test func aFailureAfterSubmissionNeverReplaysTheJobLocally() async {
        var localRuns = 0
        let processor = DocumentProcessor(
            fallbackPreflight: { _ in },
            fallbackRunner: { _, _, _ in localRuns += 1 },
            workerRunner: { job, _, _ in
                job.workerJobID = "accepted-job"
                job.status = .failed
                job.error = URLError(.networkConnectionLost).localizedDescription
            }
        )
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        await processor.process(job: job, settings: configuredSettings(), mode: .full)
        #expect(localRuns == 0)
        #expect(job.workerJobID == "accepted-job")
        #expect(job.status == .failed)
        #expect(job.localFallbackNotice == nil)
    }

    private func configuredSettings() -> AppSettings {
        let settings = IsolatedSettings.make()
        settings.processingHost = .devbox
        settings.allowLocalFallback = true
        settings.devboxWorkerURL = "http://worker.example:8080"
        settings.ollamaURL = "http://localhost:11434"
        settings.qdrantURL = "http://localhost:6334"
        settings.doclingModel = DoclingModel.graniteDoclingTransformers.rawValue
        let plan = CollectionPlan.preset(
            .smallFastLocal, name: settings.defaultCollection,
            vectorSize: settings.embeddingDimensions,
            embeddingBackend: settings.embeddingBackend, embeddingModel: settings.embeddingModel
        )
        CollectionPlanStore.save(plan, defaults: settings.defaults)
        return settings
    }
}
