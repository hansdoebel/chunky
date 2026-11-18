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
    var processingTask: Task<Void, Never>?
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

    @Published var qdrantService: QdrantService?

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

    @Published var watchedIndex = WatchedFolderIndex(folders: [], records: [])
    private let folderWatcher: FolderWatching = MacFolderWatcher()
    @Published var watchedStatus = ""
    @Published var watchedRunToken = 0
    var watchedFollowUp = false

    var watchedIndexLocationOverride: URL?

    func watchedIndexURL() -> URL {
        if let watchedIndexLocationOverride { return watchedIndexLocationOverride }
        return ChunkCacheLocation.macDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("watched-folders.json")
    }

    func loadWatchedFolders() {
        watchedIndex = WatchedFolderIndex.load(from: watchedIndexURL())
    }

    func saveWatchedFolders() {
        try? watchedIndex.save(to: watchedIndexURL())
    }

    func enqueueWatched(_ file: WatchedFile, collection: String, settingsHash: String) {
        let url = URL(fileURLWithPath: file.path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return }
        if jobs.contains(where: { $0.watchedPath == file.path && $0.status != .completed && $0.status != .failed }) { return }
        let job = ProcessingJob(url: url)
        job.watchedDocID = file.docID
        job.watchedCollection = collection
        job.watchedPath = file.path
        job.watchedContentHash = file.contentHash
        job.watchedSettingsHash = settingsHash
        job.watchedModified = file.modified
        jobs.append(job)
    }

    func noteWatchedSuccess(_ job: ProcessingJob) {
        guard job.status == .completed, !job.uploadedPointIDs.isEmpty, let path = job.watchedPath, let hash = job.watchedContentHash, let settingsHash = job.watchedSettingsHash else { return }
        var records = watchedIndex.records
        let record = WatchedRecord(
            path: path,
            contentHash: hash,
            settingsHash: settingsHash,
            docID: job.watchedDocID ?? hash,
            pointIDs: job.uploadedPointIDs,
            modified: job.watchedModified ?? Date()
        )
        if let index = records.firstIndex(where: { $0.path == path }) {
            records[index] = record
        } else {
            records.append(record)
        }
        var index = watchedIndex
        index.records = records
        watchedIndex = index
        saveWatchedFolders()
    }

    func scanWatchedFolders() {
        var records = watchedIndex.records
        var ingested = 0
        var skipped = 0
        var replaced = 0
        var removed = 0
        let inFlight = Set(jobs.compactMap { job -> String? in
            guard let path = job.watchedPath, job.status != .completed, job.status != .failed else { return nil }
            return path
        })
        for folder in watchedIndex.folders where !folder.paused {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            let owned = records.filter { $0.path == folder.path || $0.path.hasPrefix(prefix) }
            let outside = records.filter { $0.path != folder.path && !$0.path.hasPrefix(prefix) }
            let files = WatchedFolderFiles.list(directory: URL(fileURLWithPath: folder.path)).compactMap {
                WatchedFolderFiles.file(at: $0)
            }
            let fingerprint = fingerprint(for: folder)
            let plan = FolderSync.plan(
                files: files,
                records: owned,
                settingsHash: fingerprint,
                deleteRemoved: folder.deleteRemoved,
                inFlight: inFlight
            )
            var pointIDs: [String] = []
            FolderSyncApply.apply(plan.actions, enqueue: { file in
                enqueueWatched(file, collection: folder.collection, settingsHash: fingerprint)
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
            if !pointIDs.isEmpty {
                let collection = folder.collection
                Task { await deletePoints(ids: pointIDs, collection: collection) }
            }
        }
        var index = watchedIndex
        index.records = records
        watchedIndex = index
        saveWatchedFolders()
        watchedStatus = "Ingest \(ingested), replace \(replaced), skip \(skipped), delete \(removed)."
        if ingested + replaced > 0 {
            if isProcessing {
                watchedFollowUp = true
            } else {
                watchedRunToken += 1
            }
        }
        startWatchingFolders()
    }

    private func fingerprint(for folder: WatchedFolder) -> String {
        FolderSync.settingsFingerprint(
            collection: folder.collection,
            embeddingModel: settings.embeddingModel,
            embeddingBackend: settings.embeddingBackend,
            chunkTokens: settings.maxTokensPerChunk,
            overlap: settings.chunkOverlap,
            chunkTokenizer: settings.chunkTokenizer,
            doclingModel: settings.doclingModel,
            doOCR: settings.doOCR,
            ocrLanguage: settings.ocrLanguage,
            doTableExtraction: settings.doTableExtraction,
            tableMode: settings.tableMode,
            doFormulaEnrichment: settings.doFormulaEnrichment
        )
    }

    func startWatchedFolders() {
        loadWatchedFolders()
        scanWatchedFolders()
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
        if job.status == .completed {
            noteWatchedSuccess(job)
        }
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

    func requestCancellation() {
        isCancellationRequested = true
        watchedFollowUp = false
    }
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
    func movePoints(ids: [String], libraryID: String, collection: String? = nil) async {
        guard !ids.isEmpty else { return }
        do {
            try await ensureQdrantConnection()
            guard let service = qdrantService else { return }
            try await service.movePoints(
                collectionName: collection ?? settings.defaultCollection,
                ids: ids,
                libraryID: libraryID
            )
            await loadBrowserPoints()
        } catch {
            qdrantConnectionError = error.localizedDescription
        }
    }

    @MainActor
    func addPaperLibrary(name: String) {
        let libraries = PaperLibrary.load(settings.paperLibrariesJSON)
        let updated = PaperLibrary.adding(name: name, to: libraries)
        guard updated != libraries, let created = updated.last else { return }
        settings.paperLibrariesJSON = PaperLibrary.save(updated)
        settings.activeLibraryID = created.id
    }

    @MainActor
    func deletePoints(ids: [String], collection: String? = nil) async {
        guard !ids.isEmpty else { return }

        do {
            try await ensureQdrantConnection()

            guard let service = qdrantService else { return }
            let collectionName = collection ?? settings.defaultCollection

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
