import Foundation

enum JobType {
    case pdf
    case chunkedJSON
    case embeddedJSON
    case markdown
}

@MainActor
final class ProcessingJob: ObservableObject, Identifiable {
    let id = UUID()
    let sourceURL: URL
    let jobType: JobType
    var preloadedChunks: [Chunk]?
    var preloadedEmbeddings: [ChunkWithEmbedding]?

    @Published var status: JobStatus = .pending
    @Published var progress: Double = 0
    @Published var statusMessage: String = "Waiting..."
    @Published var error: String?
    @Published var chunksCount: Int = 0
    @Published var embeddedCount: Int = 0

    var fileName: String {
        sourceURL.lastPathComponent
    }

    var isFromJSON: Bool {
        jobType == .chunkedJSON || jobType == .embeddedJSON || jobType == .markdown
    }

    var hasEmbeddings: Bool {
        jobType == .embeddedJSON
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        self.jobType = .pdf
    }

    init(sourceURL: URL, chunks: [Chunk]) {
        self.sourceURL = sourceURL
        let ext = sourceURL.pathExtension.lowercased()
        self.jobType = (ext == "md" || ext == "markdown") ? .markdown : .chunkedJSON
        self.preloadedChunks = chunks
        self.chunksCount = chunks.count
    }

    init(sourceURL: URL, embeddedChunks: [ChunkWithEmbedding]) {
        self.sourceURL = sourceURL
        self.jobType = .embeddedJSON
        self.preloadedEmbeddings = embeddedChunks
        self.chunksCount = embeddedChunks.count
        self.embeddedCount = embeddedChunks.count
    }

    func updateProgress(_ progress: Double, message: String) {
        self.progress = progress
        self.statusMessage = message
    }

    func setError(_ error: String) {
        self.status = .failed
        self.error = error
        self.statusMessage = "Failed"
    }

    func complete() {
        self.status = .completed
        self.progress = 1.0
        self.statusMessage = "Completed"
    }
}

enum JobStatus: String {
    case pending = "Pending"
    case chunking = "Chunking"
    case embedding = "Embedding"
    case uploading = "Uploading"
    case completed = "Completed"
    case failed = "Failed"
}
