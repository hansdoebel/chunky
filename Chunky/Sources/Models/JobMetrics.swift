import Foundation

struct StageMetric: Codable, Equatable {
    var name: String
    var durationMs: Double
    var status: String
    var runtime: String?
    var pages: Int?
    var chunks: Int?
    var tokens: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case durationMs = "duration_ms"
        case status
        case runtime
        case pages
        case chunks
        case tokens
    }
}

struct ResourceSample: Codable, Equatable {
    var gpuName: String?
    var vramUsedMb: Double?
    var vramTotalMb: Double?
    var utilization: [Double]

    enum CodingKeys: String, CodingKey {
        case gpuName = "gpu_name"
        case vramUsedMb = "vram_used_mb"
        case vramTotalMb = "vram_total_mb"
        case utilization
    }
}

struct JobMetrics: Codable, Equatable {
    var host: String
    var wallMs: Double
    var pagesPerSecond: Double?
    var chunksPerSecond: Double?
    var embeddingsPerSecond: Double?
    var stages: [StageMetric]
    var resources: ResourceSample

    enum CodingKeys: String, CodingKey {
        case host
        case wallMs = "wall_ms"
        case pagesPerSecond = "pages_per_s"
        case chunksPerSecond = "chunks_per_s"
        case embeddingsPerSecond = "embeddings_per_s"
        case stages
        case resources
    }

    static let stageNames = [
        "convert_layout", "ocr", "table", "picture_description",
        "vlm_convert", "chunking", "embedding", "qdrant_upsert",
    ]

    static func record(job: ProcessingJob, settings: AppSettings, host: String) -> JobMetrics {
        let wall = (job.totalTime ?? 0) * 1000
        let seconds = wall / 1000
        let pages = 0
        let chunks = job.chunksCount
        let embeddings = job.embeddedCount
        let stages = stageNames.map { name -> StageMetric in
            let duration = durationMs(name, job: job)
            let enabled = isEnabled(name, settings: settings, job: job)
            let status = enabled ? (duration > 0 || name == "qdrant_upsert" ? "ok" : "ok") : "skipped"
            return StageMetric(
                name: name,
                durationMs: enabled ? duration : 0,
                status: enabled ? status : "skipped",
                runtime: enabled ? runtime(name, settings: settings) : nil,
                pages: name == "convert_layout" ? nil : nil,
                chunks: name == "chunking" || name == "embedding" ? chunks : nil,
                tokens: nil
            )
        }
        return JobMetrics(
            host: host,
            wallMs: wall,
            pagesPerSecond: nil,
            chunksPerSecond: chunks > 0 && seconds > 0 ? Double(chunks) / seconds : nil,
            embeddingsPerSecond: embeddings > 0 && seconds > 0 ? Double(embeddings) / seconds : nil,
            stages: stages,
            resources: ResourceSample(gpuName: nil, vramUsedMb: nil, vramTotalMb: nil, utilization: [])
        )
    }

    private static func durationMs(_ name: String, job: ProcessingJob) -> Double {
        switch name {
        case "convert_layout": return (job.conversionTime ?? 0) * 1000
        case "chunking": return (job.chunkingTime ?? 0) * 1000
        case "embedding": return (job.embeddingTime ?? 0) * 1000
        case "qdrant_upsert": return (job.uploadTime ?? job.embeddingTime ?? 0) * 1000
        default: return 0
        }
    }

    private static func isEnabled(_ name: String, settings: AppSettings, job: ProcessingJob) -> Bool {
        switch name {
        case "ocr": return settings.doOCR
        case "table": return settings.doTableExtraction
        case "picture_description": return settings.doPictureDescription
        case "vlm_convert": return settings.doclingModel != "standard"
        case "embedding": return job.embeddedCount > 0 || (job.embeddingTime ?? 0) > 0
        case "qdrant_upsert": return (job.uploadTime ?? 0) > 0 || job.embeddedCount > 0
        default: return true
        }
    }

    private static func runtime(_ name: String, settings: AppSettings) -> String {
        switch name {
        case "embedding": return settings.embeddingBackend
        case "qdrant_upsert": return "qdrant"
        default: return settings.processingHost == .devbox ? "docling" : "docling"
        }
    }
}
