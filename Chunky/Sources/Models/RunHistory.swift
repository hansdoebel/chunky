import CryptoKit
import Foundation
import SwiftData

@Model
final class RunRecord {
    var runID: UUID
    var createdAt: Date
    var fileName: String
    var contentHash: String
    var host: String
    var runtime: String
    var pages: Int?
    var chunks: Int
    var tokens: Int?
    var embeddingsPerSecond: Double?
    var wallMs: Double
    var upsertMs: Double
    var upsertStatus: String
    var errorMessage: String?
    var stagesJSON: String

    init(draft: RunDraft) {
        self.runID = draft.runID
        self.createdAt = draft.createdAt
        self.fileName = draft.fileName
        self.contentHash = draft.contentHash
        self.host = draft.host
        self.runtime = draft.runtime
        self.pages = draft.pages
        self.chunks = draft.chunks
        self.tokens = draft.tokens
        self.embeddingsPerSecond = draft.embeddingsPerSecond
        self.wallMs = draft.wallMs
        self.upsertMs = draft.upsertMs
        self.upsertStatus = draft.upsertStatus
        self.errorMessage = draft.errorMessage
        self.stagesJSON = draft.encodedStages()
    }
}

struct RunDraft: Identifiable, Codable, Equatable {
    var runID: UUID
    var createdAt: Date
    var fileName: String
    var contentHash: String
    var host: String
    var runtime: String
    var pages: Int?
    var chunks: Int
    var tokens: Int?
    var embeddingsPerSecond: Double?
    var wallMs: Double
    var upsertMs: Double
    var upsertStatus: String
    var errorMessage: String?
    var stages: [StageMetric]

    var id: UUID { runID }

    init(record: RunRecord) {
        runID = record.runID
        createdAt = record.createdAt
        fileName = record.fileName
        contentHash = record.contentHash
        host = record.host
        runtime = record.runtime
        pages = record.pages
        chunks = record.chunks
        tokens = record.tokens
        embeddingsPerSecond = record.embeddingsPerSecond
        wallMs = record.wallMs
        upsertMs = record.upsertMs
        upsertStatus = record.upsertStatus
        errorMessage = record.errorMessage
        stages = Self.decodeStages(record.stagesJSON)
    }

    init(
        runID: UUID = UUID(),
        createdAt: Date = Date(),
        fileName: String,
        contentHash: String,
        host: String,
        runtime: String,
        pages: Int?,
        chunks: Int,
        tokens: Int?,
        embeddingsPerSecond: Double?,
        wallMs: Double,
        upsertMs: Double,
        upsertStatus: String,
        errorMessage: String?,
        stages: [StageMetric]
    ) {
        self.runID = runID
        self.createdAt = createdAt
        self.fileName = fileName
        self.contentHash = contentHash
        self.host = host
        self.runtime = runtime
        self.pages = pages
        self.chunks = chunks
        self.tokens = tokens
        self.embeddingsPerSecond = embeddingsPerSecond
        self.wallMs = wallMs
        self.upsertMs = upsertMs
        self.upsertStatus = upsertStatus
        self.errorMessage = errorMessage
        self.stages = stages
    }

    func encodedStages() -> String {
        let data = (try? JSONEncoder().encode(stages)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeStages(_ json: String) -> [StageMetric] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([StageMetric].self, from: data)) ?? []
    }

    static func make(job: ProcessingJob, settings: AppSettings, contentHash: String) -> RunDraft {
        let metrics = job.metrics
        let secrets = [settings.qdrantAPIKey, settings.workerToken]
        let stages = (metrics?.stages ?? []).map { stage in
            var copy = stage
            if let runtime = copy.runtime {
                copy.runtime = RunHistory.redact(runtime, secrets: secrets)
            }
            return copy
        }
        let upsert = stages.first { $0.name == "qdrant_upsert" }
        let stagePages = stages.compactMap(\.pages).max()
        let stageTokens = stages.compactMap(\.tokens).reduce(0, +)
        let pages = job.pageCount ?? stagePages
        let tokens = (job.tokenCount ?? 0) > 0 ? job.tokenCount : (stageTokens > 0 ? stageTokens : nil)
        let stageError = stages.first { $0.status == "error" }.map { "\($0.name) failed" }
        let error = [job.error, stageError]
            .compactMap { $0 }
            .map { RunHistory.redact($0, secrets: secrets) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        let runtime = stages.first { $0.name == "embedding" }?.runtime
            ?? stages.compactMap(\.runtime).first
            ?? "docling"
        return RunDraft(
            fileName: job.fileName,
            contentHash: contentHash,
            host: metrics?.host ?? settings.processingHost.rawValue,
            runtime: runtime,
            pages: pages,
            chunks: job.chunksCount,
            tokens: tokens,
            embeddingsPerSecond: metrics?.embeddingsPerSecond,
            wallMs: job.totalTime.map { $0 * 1000 } ?? metrics?.wallMs ?? 0,
            upsertMs: upsert?.durationMs ?? (job.uploadTime ?? 0) * 1000,
            upsertStatus: upsert?.status ?? "skipped",
            errorMessage: error.isEmpty ? nil : error,
            stages: stages
        )
    }
}

enum RunGroup: String, CaseIterable, Identifiable {
    case host
    case runtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: return "Host"
        case .runtime: return "Runtime"
        }
    }
}

struct RunAggregate: Equatable, Identifiable {
    var key: String
    var runs: Int
    var averageEmbeddingsPerSecond: Double?
    var averageWallMs: Double

    var id: String { key }
}

enum RunHistory {
    nonisolated static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func contentHash(ofFile url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return contentHash(of: Data(url.path.utf8))
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1024 * 1024)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result = result.replacingOccurrences(of: trimmed, with: "[redacted]")
        }
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)(bearer\\s+)\\S+"
        ) else {
            return result
        }
        let range = NSRange(result.startIndex..., in: result)
        return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[redacted]")
    }

    static func aggregate(_ runs: [RunDraft], by group: RunGroup) -> [RunAggregate] {
        let grouped = Dictionary(grouping: runs) { run in
            group == .host ? run.host : run.runtime
        }
        return grouped.keys.sorted().map { key in
            let items = grouped[key] ?? []
            let rates = items.compactMap(\.embeddingsPerSecond)
            let averageRate = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
            let averageWall = items.isEmpty ? 0 : items.map(\.wallMs).reduce(0, +) / Double(items.count)
            return RunAggregate(
                key: key,
                runs: items.count,
                averageEmbeddingsPerSecond: averageRate,
                averageWallMs: averageWall
            )
        }
    }
}

final class RunHistoryStore {
    let container: ModelContainer

    init(inMemory: Bool) throws {
        if inMemory {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: RunRecord.self, configurations: configuration)
        } else {
            let configuration = ModelConfiguration(url: Self.diskURL())
            container = try ModelContainer(for: RunRecord.self, configurations: configuration)
        }
    }

    static func makeDefault() -> RunHistoryStore {
        if let store = try? RunHistoryStore(inMemory: false) {
            return store
        }
        return try! RunHistoryStore(inMemory: true)
    }

    func insert(_ draft: RunDraft) throws {
        let context = ModelContext(container)
        context.insert(RunRecord(draft: draft))
        try context.save()
    }

    func allDrafts() throws -> [RunDraft] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RunRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(RunDraft.init(record:))
    }

    func drafts(contentHash: String) throws -> [RunDraft] {
        let context = ModelContext(container)
        let hash = contentHash
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.contentHash == hash },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(RunDraft.init(record:))
    }

    func aggregates(by group: RunGroup) throws -> [RunAggregate] {
        RunHistory.aggregate(try allDrafts(), by: group)
    }

    private static func diskURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Chunky", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("run-history.store")
    }
}
