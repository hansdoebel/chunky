import Combine
import SwiftUI

class ProcessingJob: ObservableObject, Identifiable {
    let id = UUID()
    @Published var fileName: String
    @Published var sourceURL: URL
    @Published var status: JobStatus = .pending
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""
    @Published var chunksCount: Int = 0
    @Published var embeddedCount: Int = 0
    @Published var error: String?
    var jobType: JobType

    @Published var startTime: Date?
    @Published var conversionTime: TimeInterval?
    @Published var chunkingTime: TimeInterval?
    @Published var embeddingTime: TimeInterval?
    @Published var uploadTime: TimeInterval?
    @Published var totalTime: TimeInterval?
    var metrics: JobMetrics?
    var pageCount: Int?
    var tokenCount: Int?
    var analyticsStored = false
    var analyticsPending = false
    var analyticsRuntime: String?
    var workerJobID: String?
    var retainedChunks: [ChunkingService.DocumentChunk] = []
    var ingestCollection: String?
    var ingestCloud = false
    @Published var verification: VerificationReport?
    @Published var verificationNote: String?
    @Published var forceReconvert = false
    @Published var cacheStatus: String?
    var preparedEmbeddings: [[Float]]?
    var bibliography: BibliographicMetadata?
    var watchedDocID: String?
    var watchedCollection: String?
    var watchedPath: String?
    var watchedContentHash: String?
    var watchedSettingsHash: String?
    var watchedModified: Date?
    var uploadedPointIDs: [String] = []

    var timingSummary: String? {
        guard let total = totalTime else { return nil }
        var parts: [String] = []
        let convertTotal = (conversionTime ?? 0) + (chunkingTime ?? 0)
        if convertTotal > 0 { parts.append("convert \(Self.formatDuration(convertTotal))") }
        if let t = embeddingTime { parts.append("embed \(Self.formatDuration(t))") }
        if let t = uploadTime { parts.append("upload \(Self.formatDuration(t))") }
        if let cacheStatus { parts.append("cache \(cacheStatus)") }
        let detail = parts.joined(separator: " | ")
        return "Total \(Self.formatDuration(total)) (\(detail))"
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return String(format: "%dm%.0fs", mins, secs)
    }

    init(url: URL) {
        self.sourceURL = url
        self.fileName = url.lastPathComponent
        self.jobType = Self.determineJobType(from: url)
    }

    private static func determineJobType(from url: URL) -> JobType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            return .markdown
        case "json":

            return .chunkedJSON
        default:

            return .pdf
        }
    }
}

typealias OllamaModel = OllamaService.ModelInfo
