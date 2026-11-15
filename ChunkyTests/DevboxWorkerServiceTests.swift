import Foundation
import Testing

@testable import Chunky

struct DevboxWorkerServiceTests {

    @Test func sseParserReadsProgressAndCompletion() {
        let progress = DevboxSSEParser.parse(line: "data: {\"type\":\"progress\",\"message\":\"Converting\",\"percent\":10}")
        #expect(progress?.type == "progress")
        #expect(progress?.message == "Converting")
        #expect(progress?.percent == 10)
        let complete = DevboxSSEParser.parse(line: "data: {\"type\":\"complete\",\"status\":\"succeeded\",\"percent\":100}")
        #expect(complete?.status == "succeeded")
        #expect(DevboxSSEParser.parse(line: ": keep-alive") == nil)
    }

    @Test func settingsMapMLXAndChooseIngestTarget() {
        let settings = AppSettings()
        defer {
            settings.qdrantAPIKey = ""
            settings.qdrantCloudURL = ""
        }
        settings.doclingModel = "granite-docling-mlx"
        settings.doclingAccelerator = "mps"
        settings.devboxIngestTarget = .localDocker
        let returned = DevboxJobPayload.settings(from: settings, mode: .full)
        #expect(returned["ingest_target"] as? String == "return_vectors")
        #expect(returned["vlm_model"] as? String == "granite-docling-transformers")
        #expect(returned["accelerator"] as? String == "cuda")
        #expect(returned["qdrant_api_key"] == nil)

        settings.devboxIngestTarget = .qdrantCloud
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io"
        settings.qdrantAPIKey = "cloud-key"
        let cloud = DevboxJobPayload.settings(from: settings, mode: .full)
        #expect(cloud["ingest_target"] as? String == "qdrant_cloud")
        #expect(cloud["qdrant_api_key"] as? String == "cloud-key")

        let chunkOnly = DevboxJobPayload.settings(from: settings, mode: .chunkOnly)
        #expect(chunkOnly["ingest_target"] as? String == "none")
        #expect(chunkOnly["mode"] as? String == "chunk_only")
    }

    @Test func errorsNameUnreachableUnauthorizedAndDimensionMismatch() {
        let denied = DevboxErrorMapper.classify(url: "http://worker/v1/models", status: 401, body: "nope")
        #expect(denied.errorDescription?.contains("401") == true)
        let mismatch = DevboxErrorMapper.classify(
            url: "http://worker/v1/jobs/1",
            status: 200,
            body: "dimension_mismatch vector size 1024"
        )
        #expect(mismatch.errorDescription?.contains("1024") == true)
        let down = DevboxErrorMapper.classify(url: "http://worker/v1/health", error: URLError(.cannotConnectToHost))
        #expect(down.errorDescription?.contains("Cannot reach") == true)
        let ats = DevboxErrorMapper.classify(
            url: "http://worker/v1/health",
            error: URLError(.appTransportSecurityRequiresSecureConnection)
        )
        #expect(ats.errorDescription?.contains("NSAllowsLocalNetworking") == true)
    }
}
