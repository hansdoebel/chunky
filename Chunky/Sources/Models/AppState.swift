import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var jobs: [ProcessingJob] = []
    @Published var settings = AppSettings()
    let piSession = PiChatSession(toolMode: .allow(PiLaunch.chunkyMCPTools))
    @Published var viewMode: ViewMode = .queue
    @Published var processingMode: ProcessingMode = {
        ProcessingMode(rawValue: UserDefaults.standard.string(forKey: "chunky.processingMode") ?? "") ?? .chunkOnly
    }() {
        didSet { UserDefaults.standard.set(processingMode.rawValue, forKey: "chunky.processingMode") }
    }
    @Published var isProcessing: Bool = false
    @Published var isCancellationRequested: Bool = false
    var benchmarkTask: Task<Void, Never>?
    @Published var availableCollections: [String] = ["documents", "notes"]
    @Published var browserPoints: [QdrantPoint] = []
    @Published var browserSources: [String] = []
    @Published var browserPointCount: Int = 0
    @Published var isLoadingPoints: Bool = false
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var qdrantConnectionError: String?
    let runHistory: RunHistoryStore
    @Published private(set) var finishedRuns: [RunDraft] = []
    @Published private(set) var evalRuns: [RetrievalEvalDraft] = []
    @Published var historyWarning: String?

    var qdrantService: QdrantService?

    var pendingJobs: [ProcessingJob] { jobs.filter { $0.status == .pending } }
    var completedJobs: [ProcessingJob] { jobs.filter { $0.status == .completed } }
    var failedJobs: [ProcessingJob] { jobs.filter { $0.status == .failed } }
    var activeJobs: [ProcessingJob] { jobs.filter { [.chunking, .embedding, .uploading].contains($0.status) } }
    var hasJobsToProcess: Bool { !pendingJobs.isEmpty }
    var overallProgress: Double { 0.5 }

    init() {
        do {
            runHistory = try RunHistoryStore(inMemory: false)
        } catch {
            runHistory = try! RunHistoryStore(inMemory: true)
            historyWarning = "Run history could not be opened on disk. New runs stay in memory until quit."
        }
    }

    func importBibliography(_ matches: [BibliographyMatch]) {
        for match in matches {
            guard let pdf = match.pdf else { continue }
            guard FileManager.default.isReadableFile(atPath: pdf.path) else { continue }
            if jobs.contains(where: { $0.sourceURL == pdf }) { continue }
            let job = ProcessingJob(url: pdf)
            job.bibliography = match.record
            jobs.append(job)
        }
    }

    var watchedIndex = WatchedFolderIndex(folders: [], records: [])
    private let folderWatcher: FolderWatching = MacFolderWatcher()
    var watchedStatus = ""

    func watchedIndexURL() -> URL {
        ChunkCacheLocation.macDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("watched-folders.json")
    }

    func loadWatchedFolders() {
        watchedIndex = WatchedFolderIndex.load(from: watchedIndexURL())
    }

    func saveWatchedFolders() {
        try? watchedIndex.save(to: watchedIndexURL())
    }

    func enqueueWatched(url: URL, docID: String) {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return }
        if jobs.contains(where: { $0.sourceURL == url && $0.status != .completed && $0.status != .failed }) { return }
        let job = ProcessingJob(url: url)
        job.watchedDocID = docID
        jobs.append(job)
    }

    func scanWatchedFolders() {
        loadWatchedFolders()
        var records = watchedIndex.records
        var ingested = 0
        var skipped = 0
        var replaced = 0
        var removed = 0
        var pointIDs: [String] = []
        for folder in watchedIndex.folders where !folder.paused {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            let owned = records.filter { $0.path == folder.path || $0.path.hasPrefix(prefix) }
            let outside = records.filter { $0.path != folder.path && !$0.path.hasPrefix(prefix) }
            let files = WatchedFolderFiles.list(directory: URL(fileURLWithPath: folder.path)).compactMap {
                WatchedFolderFiles.file(at: $0)
            }
            let fingerprint = FolderSync.settingsFingerprint(
                collection: folder.collection,
                embeddingModel: settings.embeddingModel,
                chunkTokens: settings.maxTokensPerChunk,
                overlap: settings.chunkOverlap
            )
            let plan = FolderSync.plan(files: files, records: owned, settingsHash: fingerprint, deleteRemoved: folder.deleteRemoved)
            FolderSyncApply.apply(plan.actions, enqueue: { url, docID in
                enqueueWatched(url: url, docID: docID)
            }, delete: { ids in
                pointIDs.append(contentsOf: ids)
            })
            for action in plan.actions {
                switch action {
                case .ingest: ingested += 1
                case .skip: skipped += 1
                case .replace: replaced += 1
                case .delete: removed += 1
                }
            }
            records = outside + plan.records
        }
        watchedIndex.records = records
        saveWatchedFolders()
        watchedStatus = "Ingest \(ingested), replace \(replaced), skip \(skipped), delete \(removed)."
        if !pointIDs.isEmpty {
            Task { await deletePoints(ids: pointIDs) }
        }
        startWatchingFolders()
    }

    func startWatchingFolders() {
        let paths = watchedIndex.folders.filter { !$0.paused }.map(\.path)
        folderWatcher.start(paths: paths) { [weak self] in
            Task { @MainActor in
                self?.scanWatchedFolders()
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {

            guard FileManager.default.isReadableFile(atPath: url.path) else {
                print("Cannot read file: \(url.path)")
                continue
            }

            let alreadyAdded = jobs.contains { $0.sourceURL == url }
            guard !alreadyAdded else {
                print("File already in queue: \(url.lastPathComponent)")
                continue
            }

            let job = ProcessingJob(url: url)
            jobs.append(job)
        }
    }

    func removeJob(_ job: ProcessingJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearCompleted() {
        jobs.removeAll { $0.status == .completed }
    }

    func clearAll() {
        jobs.removeAll()
    }
    func reloadHistory() {
        finishedRuns = (try? runHistory.allDrafts()) ?? finishedRuns
        evalRuns = (try? runHistory.evalDrafts()) ?? evalRuns
    }

    func storeEvalRun(_ draft: RetrievalEvalDraft) {
        do {
            try runHistory.insert(draft)
            reloadHistory()
        } catch {
            historyWarning = "Could not save the eval run."
        }
    }

    func storeFinishedRun(_ job: ProcessingJob, settings: AppSettings) {
        guard job.status == .completed || job.status == .failed else { return }
        guard !job.analyticsStored, !job.analyticsPending else { return }
        job.analyticsPending = true
        let url = job.sourceURL
        Task {
            let hash = await Task.detached {
                RunHistory.contentHash(ofFile: url)
            }.value
            guard !job.analyticsStored else { return }
            let draft = RunDraft.make(job: job, settings: settings, contentHash: hash)
            do {
                try runHistory.insert(draft)
                job.analyticsStored = true
                job.analyticsPending = false
                reloadHistory()
            } catch {
                job.analyticsPending = false
                historyWarning = "Could not save \(job.fileName) to run history."
            }
        }
    }

    func requestCancellation() { isCancellationRequested = true }
    func resetCancellation() { isCancellationRequested = false }

    deinit {
        piSession.terminate()
    }

    func makeChat(report: PiInstallReport, http: any ChatHTTPStreaming = URLSessionChatHTTP()) -> any ChatStreaming {
        ChatBackendFactory.make(
            preference: ChatBackendPreference(rawValue: settings.chatBackend) ?? .automatic,
            report: report,
            piModel: settings.piModel,
            chatModel: settings.chatModel,
            apiURL: settings.chatAPIURL,
            apiKey: settings.chatAPIKey,
            overridePath: settings.piExecutablePath,
            session: piSession,
            http: http
        )
    }

    @MainActor
    func ensureQdrantConnection() async throws {
        let url = settings.qdrantURL
        guard !url.isEmpty else {
            throw QdrantError.invalidURL("Qdrant URL not configured")
        }

        if qdrantService == nil {
            qdrantService = QdrantService()
        }

        guard let service = qdrantService else { return }

        if !service.isConnected {
            let apiKey = settings.qdrantAPIKey.isEmpty ? nil : settings.qdrantAPIKey

            do {
                try await service.configure(url: url, apiKey: apiKey)
                try await service.connect(timeout: settings.qdrantTimeout)
                qdrantConnectionError = nil
            } catch {
                qdrantConnectionError = error.localizedDescription
                throw error
            }
        }
    }

    @MainActor
    func loadBrowserPoints() async {
        isLoadingPoints = true
        defer { isLoadingPoints = false }

        do {
            try await ensureQdrantConnection()

            guard let service = qdrantService else { return }
            let collectionName = settings.defaultCollection

            let exists = try await service.collectionExists(collectionName)
            guard exists else {
                browserPoints = []
                browserSources = []
                browserPointCount = 0
                return
            }

            let points = try await service.loadPoints(collectionName: collectionName, limit: CollectionBrowse.pointLimit)
            browserPoints = points
            browserPointCount = points.count

            let sources = Set(points.map { $0.source }).filter { !$0.isEmpty }
            browserSources = Array(sources).sorted()
            settings.noteQdrantSuccess()
            print("Loaded \(points.count) points with \(sources.count) unique sources: \(sources)")
        } catch {
            print("Failed to load browser points: \(error)")
            qdrantConnectionError = error.localizedDescription
        }
    }

    @MainActor
    func deletePoints(ids: [String]) async {
        guard !ids.isEmpty else { return }

        do {
            try await ensureQdrantConnection()

            guard let service = qdrantService else { return }
            let collectionName = settings.defaultCollection

            try await service.deletePoints(collectionName: collectionName, ids: ids)

            await loadBrowserPoints()
        } catch {
            print("Failed to delete points: \(error)")
            qdrantConnectionError = error.localizedDescription
        }
    }

    @MainActor
    func fetchCollections() async {

        guard !settings.qdrantURL.isEmpty else {
            let base = availableCollections.isEmpty ? ["documents"] : availableCollections
            let pending = CollectionPlanStore.mergedNames(server: base)
            availableCollections = pending.isEmpty ? ["documents"] : pending
            return
        }

        do {
            try await ensureQdrantConnection()

            guard let service = qdrantService else { return }
            let collections = CollectionPlanStore.mergedNames(server: try await service.listCollections())
            availableCollections = collections.isEmpty ? ["documents"] : collections
            qdrantConnectionError = nil
            settings.noteQdrantSuccess()
            print("Fetched \(collections.count) collections: \(collections)")
        } catch {
            print("Failed to fetch collections: \(error)")
            qdrantConnectionError = error.localizedDescription

            if availableCollections.isEmpty {
                let pending = CollectionPlanStore.mergedNames(server: ["documents"])
                availableCollections = pending.isEmpty ? ["documents"] : pending
            }
        }
    }
}
