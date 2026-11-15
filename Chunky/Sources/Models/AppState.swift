import SwiftUI
import Combine

// MARK: - AppState

class AppState: ObservableObject {
    @Published var jobs: [ProcessingJob] = []
    @Published var settings = AppSettings()
    @Published var viewMode: ViewMode = .queue
    @Published var processingMode: ProcessingMode = {
        ProcessingMode(rawValue: UserDefaults.standard.string(forKey: "chunky.processingMode") ?? "") ?? .chunkOnly
    }() {
        didSet { UserDefaults.standard.set(processingMode.rawValue, forKey: "chunky.processingMode") }
    }
    @Published var isProcessing: Bool = false
    @Published var isCancellationRequested: Bool = false
    @Published var availableCollections: [String] = ["documents", "notes"]
    @Published var browserPoints: [QdrantPoint] = []
    @Published var browserSources: [String] = []
    @Published var browserPointCount: Int = 0
    @Published var isLoadingPoints: Bool = false
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var qdrantConnectionError: String?

    /// The shared Qdrant service instance
    var qdrantService: QdrantService?

    var pendingJobs: [ProcessingJob] { jobs.filter { $0.status == .pending } }
    var completedJobs: [ProcessingJob] { jobs.filter { $0.status == .completed } }
    var failedJobs: [ProcessingJob] { jobs.filter { $0.status == .failed } }
    var activeJobs: [ProcessingJob] { jobs.filter { [.chunking, .embedding, .uploading].contains($0.status) } }
    var hasJobsToProcess: Bool { !pendingJobs.isEmpty }
    var overallProgress: Double { 0.5 }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            // Check if file exists and is readable
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                print("Cannot read file: \(url.path)")
                continue
            }

            // Check if file is already in the queue
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
    func requestCancellation() { isCancellationRequested = true }
    func resetCancellation() { isCancellationRequested = false }

    /// Connect to Qdrant if not already connected
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

    /// Load points from the current collection for browsing
    @MainActor
    func loadBrowserPoints() async {
        isLoadingPoints = true
        defer { isLoadingPoints = false }

        do {
            try await ensureQdrantConnection()

            guard let service = qdrantService else { return }
            let collectionName = settings.defaultCollection

            // Check if collection exists
            let exists = try await service.collectionExists(collectionName)
            guard exists else {
                browserPoints = []
                browserSources = []
                browserPointCount = 0
                return
            }

            // Load points
            let points = try await service.loadPoints(collectionName: collectionName, limit: 1000)
            browserPoints = points
            browserPointCount = points.count

            // Extract unique sources (filter out empty strings)
            let sources = Set(points.map { $0.source }).filter { !$0.isEmpty }
            browserSources = Array(sources).sorted()
            print("Loaded \(points.count) points with \(sources.count) unique sources: \(sources)")
        } catch {
            print("Failed to load browser points: \(error)")
            qdrantConnectionError = error.localizedDescription
        }
    }

    /// Delete points by their IDs
    @MainActor
    func deletePoints(ids: [String]) async {
        guard !ids.isEmpty else { return }

        do {
            try await ensureQdrantConnection()

            guard let service = qdrantService else { return }
            let collectionName = settings.defaultCollection

            try await service.deletePoints(collectionName: collectionName, ids: ids)

            // Refresh the browser
            await loadBrowserPoints()
        } catch {
            print("Failed to delete points: \(error)")
            qdrantConnectionError = error.localizedDescription
        }
    }

    /// Fetch available collections from Qdrant
    @MainActor
    func fetchCollections() async {
        // Skip if Qdrant is not configured
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
            print("Fetched \(collections.count) collections: \(collections)")
        } catch {
            print("Failed to fetch collections: \(error)")
            qdrantConnectionError = error.localizedDescription
            // Keep default collections on error
            if availableCollections.isEmpty {
                let pending = CollectionPlanStore.mergedNames(server: ["documents"])
                availableCollections = pending.isEmpty ? ["documents"] : pending
            }
        }
    }
}
