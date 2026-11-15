import Foundation
import Testing

@testable import Chunky

struct JobMetricsTests {
    @Test func localJobRecordsTheSharedSchemaAndSkipsOCR() throws {
        let settings = IsolatedSettings.make()
        settings.doOCR = false
        settings.doPictureDescription = false
        settings.doclingModel = "standard"
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/paper.pdf"))
        job.totalTime = 2
        job.conversionTime = 1
        job.chunkingTime = 0.4
        job.embeddingTime = 0.5
        job.uploadTime = 0.1
        job.chunksCount = 4
        job.embeddedCount = 4
        let metrics = JobMetrics.record(job: job, settings: settings, host: "Local Mac")
        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(JobMetrics.self, from: data)
        #expect(decoded.host == "Local Mac")
        #expect(decoded.stages.map(\.name) == JobMetrics.stageNames)
        #expect(decoded.stages.first { $0.name == "ocr" }?.status == "skipped")
        #expect(decoded.stages.first { $0.name == "picture_description" }?.status == "skipped")
        #expect(decoded.stages.first { $0.name == "qdrant_upsert" }?.status == "ok")
        #expect(decoded.chunksPerSecond == 2)
    }
}
