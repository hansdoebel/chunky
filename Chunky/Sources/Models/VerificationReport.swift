import CoreGraphics
import SwiftUI

struct VerificationReport: Codable, Equatable, Identifiable {
    var jobID: String?
    var filename: String
    var pdfHash: String
    var chunkSource: String
    var status: String
    var generatedAt: String
    var coverageThreshold: Double
    var pageSize: PageSize
    var text: TextNote
    var pages: [PageRow]
    var attributions: [Attribution]
    var store: CheckBlock
    var vectorSpotCheck: CheckBlock
    var retrieval: CheckBlock
    var spotChecks: [SpotCheck]

    var id: String { pdfHash.isEmpty ? filename : pdfHash }

    struct PageSize: Codable, Equatable {
        var width: Double
        var height: Double
    }

    struct TextNote: Codable, Equatable {
        var status: String
        var note: String?
    }

    struct PageRow: Codable, Equatable, Identifiable {
        var page: Int
        var status: String
        var coverage: Double
        var flags: [String]
        var id: Int { page }
    }

    struct Attribution: Codable, Equatable, Identifiable {
        var chunkID: String
        var page: Int?
        var pageEnd: Int?
        var similarity: Double
        var matched: Bool
        var suggestedPage: Int?
        var id: String { chunkID }
    }

    struct CheckBlock: Codable, Equatable {
        var status: String
        var issues: [Issue]
        var samples: [Sample]
        var queries: [Query]

        struct Issue: Codable, Equatable, Identifiable {
            var chunkID: String
            var kind: String
            var detail: String
            var id: String { chunkID + kind + detail }
        }

        struct Sample: Codable, Equatable, Identifiable {
            var chunkID: String
            var cosine: Double
            var status: String
            var id: String { chunkID }
        }

        struct Query: Codable, Equatable, Identifiable {
            var query: String
            var expectedChunkID: String
            var expectedPage: Int?
            var topChunkID: String
            var topPage: Int?
            var passed: Bool
            var id: String { query }
        }
    }

    struct SpotCheck: Codable, Equatable, Identifiable {
        var chunkID: String
        var page: Int?
        var bbox: VerificationBBox?
        var preview: String
        var id: String { chunkID }
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case filename
        case pdfHash = "pdf_hash"
        case chunkSource = "chunk_source"
        case status
        case generatedAt = "generated_at"
        case coverageThreshold = "coverage_threshold"
        case pageSize = "page_size"
        case text, pages, attributions, store
        case vectorSpotCheck = "vector_spot_check"
        case retrieval
        case spotChecks = "spot_checks"
    }

    init(
        jobID: String?,
        filename: String,
        pdfHash: String,
        chunkSource: String,
        status: String,
        generatedAt: String,
        coverageThreshold: Double,
        pageSize: PageSize,
        text: TextNote,
        pages: [PageRow],
        attributions: [Attribution],
        store: CheckBlock,
        vectorSpotCheck: CheckBlock,
        retrieval: CheckBlock,
        spotChecks: [SpotCheck]
    ) {
        self.jobID = jobID
        self.filename = filename
        self.pdfHash = pdfHash
        self.chunkSource = chunkSource
        self.status = status
        self.generatedAt = generatedAt
        self.coverageThreshold = coverageThreshold
        self.pageSize = pageSize
        self.text = text
        self.pages = pages
        self.attributions = attributions
        self.store = store
        self.vectorSpotCheck = vectorSpotCheck
        self.retrieval = retrieval
        self.spotChecks = spotChecks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "Document"
        pdfHash = try container.decodeIfPresent(String.self, forKey: .pdfHash) ?? ""
        chunkSource = try container.decodeIfPresent(String.self, forKey: .chunkSource) ?? "job"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "red"
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        coverageThreshold = try container.decodeIfPresent(Double.self, forKey: .coverageThreshold) ?? 0.9
        pageSize = try container.decodeIfPresent(PageSize.self, forKey: .pageSize) ?? PageSize(width: 612, height: 792)
        text = try container.decodeIfPresent(TextNote.self, forKey: .text) ?? TextNote(status: "skipped", note: nil)
        pages = try container.decodeIfPresent([PageRow].self, forKey: .pages) ?? []
        attributions = try container.decodeIfPresent([Attribution].self, forKey: .attributions) ?? []
        store = try container.decodeIfPresent(CheckBlock.self, forKey: .store) ?? CheckBlock(status: "skipped", issues: [], samples: [], queries: [])
        vectorSpotCheck = try container.decodeIfPresent(CheckBlock.self, forKey: .vectorSpotCheck) ?? CheckBlock(status: "skipped", issues: [], samples: [], queries: [])
        retrieval = try container.decodeIfPresent(CheckBlock.self, forKey: .retrieval) ?? CheckBlock(status: "skipped", issues: [], samples: [], queries: [])
        spotChecks = try container.decodeIfPresent([SpotCheck].self, forKey: .spotChecks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(jobID, forKey: .jobID)
        try container.encode(filename, forKey: .filename)
        try container.encode(pdfHash, forKey: .pdfHash)
        try container.encode(chunkSource, forKey: .chunkSource)
        try container.encode(status, forKey: .status)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(coverageThreshold, forKey: .coverageThreshold)
        try container.encode(pageSize, forKey: .pageSize)
        try container.encode(text, forKey: .text)
        try container.encode(pages, forKey: .pages)
        try container.encode(attributions, forKey: .attributions)
        try container.encode(store, forKey: .store)
        try container.encode(vectorSpotCheck, forKey: .vectorSpotCheck)
        try container.encode(retrieval, forKey: .retrieval)
        try container.encode(spotChecks, forKey: .spotChecks)
    }

    var focusPage: Int {
        if let page = pages.first(where: { $0.status != "green" })?.page {
            return page
        }
        return spotChecks.first?.page ?? pages.first?.page ?? 1
    }
}

extension VerificationReport.Attribution {
    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case page
        case pageEnd = "page_end"
        case similarity, matched
        case suggestedPage = "suggested_page"
    }
}

extension VerificationReport.CheckBlock.Issue {
    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case kind, detail
    }
}

extension VerificationReport.CheckBlock.Sample {
    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case cosine, status
    }
}

extension VerificationReport.CheckBlock.Query {
    enum CodingKeys: String, CodingKey {
        case query
        case expectedChunkID = "expected_chunk_id"
        case expectedPage = "expected_page"
        case topChunkID = "top_chunk_id"
        case topPage = "top_page"
        case passed
    }
}

extension VerificationReport.SpotCheck {
    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case page, bbox, preview
    }
}

extension VerificationReport.CheckBlock {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "skipped"
        issues = try container.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        samples = try container.decodeIfPresent([Sample].self, forKey: .samples) ?? []
        queries = try container.decodeIfPresent([Query].self, forKey: .queries) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(issues, forKey: .issues)
        try container.encode(samples, forKey: .samples)
        try container.encode(queries, forKey: .queries)
    }

    private enum CodingKeys: String, CodingKey {
        case status, issues, samples, queries
    }
}

struct VerificationBBox: Codable, Equatable {
    var l: Double
    var t: Double
    var r: Double
    var b: Double
    var origin: String

    private enum CodingKeys: String, CodingKey {
        case l, t, r, b, origin
    }

    init(l: Double, t: Double, r: Double, b: Double, origin: String = "bottom_left") {
        self.l = l
        self.t = t
        self.r = r
        self.b = b
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        l = try container.decode(Double.self, forKey: .l)
        t = try container.decode(Double.self, forKey: .t)
        r = try container.decode(Double.self, forKey: .r)
        b = try container.decode(Double.self, forKey: .b)
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? "bottom_left"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(l, forKey: .l)
        try container.encode(t, forKey: .t)
        try container.encode(r, forKey: .r)
        try container.encode(b, forKey: .b)
        try container.encode(origin, forKey: .origin)
    }

    func rect(pageWidth: Double, pageHeight: Double, in area: CGRect) -> CGRect {
        let width = max(pageWidth, 1)
        let height = max(pageHeight, 1)
        let top: Double
        let boxHeight: Double
        if origin == "top_left" || t < b {
            top = t
            boxHeight = abs(b - t)
        } else {
            top = height - t
            boxHeight = abs(t - b)
        }
        return CGRect(
            x: area.minX + l / width * area.width,
            y: area.minY + top / height * area.height,
            width: abs(r - l) / width * area.width,
            height: boxHeight / height * area.height
        )
    }
}

enum VerificationStatusColor {
    static func color(_ status: String) -> Color {
        switch status {
        case "green":
            return AppTheme.statusGreen
        case "red":
            return AppTheme.statusRed
        default:
            return AppTheme.statusOrange
        }
    }
}

enum VerificationPayload {
    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }

    static func logged(_ settings: [String: Any]) -> [String: Any] {
        var copy = settings
        copy.removeValue(forKey: "qdrant_api_key")
        return copy
    }

    static func chunkRows(_ chunks: [ChunkingService.DocumentChunk]) -> [[String: Any]] {
        chunks.map { chunk in
            var row: [String: Any] = [
                "id": chunk.id,
                "text": chunk.text,
                "chunk_index": chunk.chunkIndex,
            ]
            if let page = chunk.page { row["page"] = page }
            if let pageEnd = chunk.pageEnd { row["page_end"] = pageEnd }
            if let embedding = chunk.embeddingText, !embedding.isEmpty { row["embedding_text"] = embedding }
            if let raw = chunk.bboxesJSON,
               let data = raw.data(using: .utf8),
               let boxes = try? JSONSerialization.jsonObject(with: data) {
                row["bboxes"] = boxes
            }
            return row
        }
    }

    static func qdrantTarget(settings: AppSettings, collection: String?, cloud: Bool) -> (url: String, key: String, collection: String) {
        let name = (collection?.isEmpty == false ? collection! : settings.defaultCollection)
        if cloud {
            return (settings.qdrantCloudURL, settings.qdrantAPIKey, name)
        }
        return ("", "", name)
    }
}
