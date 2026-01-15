import Foundation

struct PersistedJob: Codable {
    let id: UUID
    let sourceURL: URL
    let jobType: String
    let chunksCount: Int
    let error: String?
}

struct PersistedQueue: Codable {
    let jobs: [PersistedJob]
    let timestamp: Date
}

extension AppState {
    private static var stateURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let chunkyDir = appSupport.appendingPathComponent("Chunky")
        try? FileManager.default.createDirectory(at: chunkyDir, withIntermediateDirectories: true)
        return chunkyDir.appendingPathComponent("queue_state.json")
    }

    func saveState() {
        let pendingAndFailed = jobs.filter { $0.status == .pending || $0.status == .failed }
        guard !pendingAndFailed.isEmpty else {
            clearState()
            return
        }

        let persisted = PersistedQueue(
            jobs: pendingAndFailed.map { job in
                PersistedJob(
                    id: job.id,
                    sourceURL: job.sourceURL,
                    jobType: job.jobType.rawValue,
                    chunksCount: job.chunksCount,
                    error: job.error
                )
            },
            timestamp: Date()
        )

        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: Self.stateURL)
            print("[Chunky] Saved \(pendingAndFailed.count) jobs to state file")
        } catch {
            print("[Chunky] Failed to save state: \(error)")
        }
    }

    func loadState() -> PersistedQueue? {
        guard FileManager.default.fileExists(atPath: Self.stateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: Self.stateURL)
            let queue = try JSONDecoder().decode(PersistedQueue.self, from: data)
            print("[Chunky] Loaded \(queue.jobs.count) jobs from state file")
            return queue
        } catch {
            print("[Chunky] Failed to load state: \(error)")
            return nil
        }
    }

    func restoreJobs(from queue: PersistedQueue) {
        for persisted in queue.jobs {
            guard !jobs.contains(where: { $0.sourceURL == persisted.sourceURL }) else { continue }

            let jobType = JobType(rawValue: persisted.jobType) ?? .pdf
            let job: ProcessingJob

            switch jobType {
            case .pdf:
                job = ProcessingJob(sourceURL: persisted.sourceURL)
            case .chunkedJSON, .markdown:
                job = ProcessingJob(sourceURL: persisted.sourceURL, chunks: [])
                job.chunksCount = persisted.chunksCount
            case .embeddedJSON:
                job = ProcessingJob(sourceURL: persisted.sourceURL, embeddedChunks: [])
                job.chunksCount = persisted.chunksCount
            }

            if let error = persisted.error {
                job.setError(error)
            }

            jobs.append(job)
        }
    }

    func clearState() {
        try? FileManager.default.removeItem(at: Self.stateURL)
    }

    func hasPersistedState() -> Bool {
        FileManager.default.fileExists(atPath: Self.stateURL.path)
    }
}

extension JobType: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "pdf": self = .pdf
        case "chunkedJSON": self = .chunkedJSON
        case "embeddedJSON": self = .embeddedJSON
        case "markdown": self = .markdown
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .pdf: return "pdf"
        case .chunkedJSON: return "chunkedJSON"
        case .embeddedJSON: return "embeddedJSON"
        case .markdown: return "markdown"
        }
    }
}
