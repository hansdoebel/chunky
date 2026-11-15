import CryptoKit
import Foundation
import SwiftData

@Model
final class RetrievalEvalRecord {
    var runID: UUID
    var createdAt: Date
    var setName: String
    var embeddingModel: String
    var chunking: String
    var hybrid: Bool
    var reranker: Bool
    var k: Int
    var setIdentity: String
    var recallAtK: Double
    var mrr: Double
    var ndcgAtK: Double
    var hitRate: Double
    var latencyMs: Double
    var queries: Int
    var scope: String = ""

    init(draft: RetrievalEvalDraft) {
        runID = draft.runID
        createdAt = draft.createdAt
        setName = draft.setName
        embeddingModel = draft.embeddingModel
        chunking = draft.chunking
        hybrid = draft.hybrid
        reranker = draft.reranker
        k = draft.score.k
        setIdentity = draft.setIdentity
        recallAtK = draft.score.recallAtK
        mrr = draft.score.mrr
        ndcgAtK = draft.score.ndcgAtK
        hitRate = draft.score.hitRate
        latencyMs = draft.score.latencyMs
        queries = draft.score.queries
        scope = draft.scope
    }
}

struct RetrievalEvalQuery: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var question: String
    var relevantIDs: [String]
    var sourceChunkID: String?

    init(id: UUID = UUID(), question: String, relevantIDs: [String], sourceChunkID: String? = nil) {
        self.id = id
        self.question = question
        self.relevantIDs = relevantIDs
        self.sourceChunkID = sourceChunkID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try container.decode(String.self, forKey: .question)
        relevantIDs = try container.decodeIfPresent([String].self, forKey: .relevantIDs) ?? []
        sourceChunkID = try container.decodeIfPresent(String.self, forKey: .sourceChunkID)
    }
}

struct RetrievalEvalSet: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var queries: [RetrievalEvalQuery]

    init(id: UUID = UUID(), name: String, queries: [RetrievalEvalQuery]) {
        self.id = id
        self.name = name
        self.queries = queries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "eval"
        queries = try container.decodeIfPresent([RetrievalEvalQuery].self, forKey: .queries) ?? []
    }
}

struct RetrievalEvalConfig: Equatable, Sendable {
    var collection: String
    var embeddingBackend: String
    var embeddingModel: String
    var chunking: String
    var hybrid: Bool
    var reranker: Bool
    var k: Int
    var rrfWeights: [Double]?
    var rerank: RerankConfig?
    var filters: [RetrievalFilter] = []

    var label: String {
        let fusion = hybrid ? "hybrid" : "dense"
        let rank = reranker ? "rerank" : "no rerank"
        return "\(embeddingModel) · \(chunking) · \(fusion) · \(rank)"
    }

    static func chunkingLabel(tokens: Int, overlap: Int) -> String {
        "\(tokens)/\(overlap)"
    }
}

struct RetrievalEvalScore: Equatable, Sendable {
    var recallAtK: Double
    var mrr: Double
    var ndcgAtK: Double
    var hitRate: Double
    var latencyMs: Double
    var k: Int
    var queries: Int
}

struct RetrievalEvalDraft: Equatable, Identifiable, Sendable {
    var runID: UUID
    var createdAt: Date
    var setName: String
    var embeddingModel: String
    var chunking: String
    var hybrid: Bool
    var reranker: Bool
    var setIdentity: String
    var score: RetrievalEvalScore
    var scope: String

    var id: UUID { runID }

    var label: String {
        let fusion = hybrid ? "hybrid" : "dense"
        let rank = reranker ? "rerank" : "no rerank"
        let base = "\(setIdentity) · k\(score.k) · \(embeddingModel) · \(chunking) · \(fusion) · \(rank)"
        return scope.isEmpty ? base : "\(base) · \(scope)"
    }

    init(record: RetrievalEvalRecord) {
        runID = record.runID
        createdAt = record.createdAt
        setName = record.setName
        embeddingModel = record.embeddingModel
        chunking = record.chunking
        hybrid = record.hybrid
        reranker = record.reranker
        setIdentity = record.setIdentity
        score = RetrievalEvalScore(
            recallAtK: record.recallAtK,
            mrr: record.mrr,
            ndcgAtK: record.ndcgAtK,
            hitRate: record.hitRate,
            latencyMs: record.latencyMs,
            k: record.k,
            queries: record.queries
        )
        scope = record.scope
    }

    init(
        runID: UUID = UUID(),
        createdAt: Date = Date(),
        setName: String,
        embeddingModel: String,
        chunking: String,
        hybrid: Bool,
        reranker: Bool,
        setIdentity: String,
        score: RetrievalEvalScore,
        scope: String = ""
    ) {
        self.runID = runID
        self.createdAt = createdAt
        self.setName = setName
        self.embeddingModel = embeddingModel
        self.chunking = chunking
        self.hybrid = hybrid
        self.reranker = reranker
        self.setIdentity = setIdentity
        self.score = score
        self.scope = scope
    }
}

struct RetrievalEvalComparison: Equatable, Identifiable, Sendable {
    var label: String
    var runs: Int
    var recallAtK: Double
    var mrr: Double
    var ndcgAtK: Double
    var hitRate: Double
    var latencyMs: Double

    var id: String { label }
}

enum RetrievalEvalChartMetric: String, CaseIterable, Identifiable, Sendable {
    case recall = "Recall@k"
    case mrr = "MRR"
    case ndcg = "nDCG@k"
    case hit = "Hit rate"
    case latency = "Latency ms"

    var id: String { rawValue }

    func value(_ comparison: RetrievalEvalComparison) -> Double {
        switch self {
        case .recall: return comparison.recallAtK
        case .mrr: return comparison.mrr
        case .ndcg: return comparison.ndcgAtK
        case .hit: return comparison.hitRate
        case .latency: return comparison.latencyMs
        }
    }
}

enum RetrievalEvalMetrics {
    struct Row: Equatable, Sendable {
        var relevant: [String]
        var retrieved: [String]
        var latencyMs: Double
    }

    static func recall(relevant: [String], retrieved: [String], k: Int) -> Double {
        let gold = Set(relevant)
        guard !gold.isEmpty, k > 0 else { return 0 }
        let top = Set(retrieved.prefix(k))
        return Double(gold.intersection(top).count) / Double(gold.count)
    }

    static func reciprocalRank(relevant: [String], retrieved: [String], k: Int) -> Double {
        let gold = Set(relevant)
        guard !gold.isEmpty, k > 0 else { return 0 }
        for (index, id) in retrieved.prefix(k).enumerated() where gold.contains(id) {
            return 1 / Double(index + 1)
        }
        return 0
    }

    static func hit(relevant: [String], retrieved: [String], k: Int) -> Double {
        reciprocalRank(relevant: relevant, retrieved: retrieved, k: k) > 0 ? 1 : 0
    }

    static func ndcg(relevant: [String], retrieved: [String], k: Int) -> Double {
        let gold = Set(relevant)
        guard !gold.isEmpty, k > 0 else { return 0 }
        var seen: Set<String> = []
        let gains = retrieved.prefix(k).map { id in
            gold.contains(id) && seen.insert(id).inserted ? 1.0 : 0.0
        }
        let ideal = Array(repeating: 1.0, count: min(k, gold.count))
        let idealScore = discounted(ideal)
        guard idealScore > 0 else { return 0 }
        return discounted(Array(gains)) / idealScore
    }

    static func summarize(_ rows: [Row], k: Int) -> RetrievalEvalScore {
        guard !rows.isEmpty else {
            return RetrievalEvalScore(recallAtK: 0, mrr: 0, ndcgAtK: 0, hitRate: 0, latencyMs: 0, k: k, queries: 0)
        }
        let count = Double(rows.count)
        func mean(_ value: (Row) -> Double) -> Double {
            rows.reduce(0) { $0 + value($1) } / count
        }
        return RetrievalEvalScore(
            recallAtK: mean { recall(relevant: $0.relevant, retrieved: $0.retrieved, k: k) },
            mrr: mean { reciprocalRank(relevant: $0.relevant, retrieved: $0.retrieved, k: k) },
            ndcgAtK: mean { ndcg(relevant: $0.relevant, retrieved: $0.retrieved, k: k) },
            hitRate: mean { hit(relevant: $0.relevant, retrieved: $0.retrieved, k: k) },
            latencyMs: mean(\.latencyMs),
            k: k,
            queries: rows.count
        )
    }

    static func identifiers(of hit: RetrievalHit) -> Set<String> {
        var ids: Set<String> = [hit.id]
        if !hit.source.isEmpty {
            ids.insert(hit.source)
        }
        if let document = hit.payload["document_id"], !document.isEmpty {
            ids.insert(document)
        }
        return ids
    }

    static func rankedIDs(hits: [RetrievalHit], relevant: Set<String>) -> [String] {
        hits.map { hit in
            let ids = identifiers(of: hit)
            if let match = relevant.first(where: { ids.contains($0) }) {
                return match
            }
            return hit.id
        }
    }

    private static func discounted(_ gains: [Double]) -> Double {
        gains.enumerated().reduce(0) { partial, item in
            partial + item.element / log2(Double(item.offset + 2))
        }
    }
}

enum RetrievalEvalSets {
    static func synthetic(name: String, chunks: [(id: String, text: String)]) -> RetrievalEvalSet {
        RetrievalEvalSet(
            name: name,
            queries: chunks.map { chunk in
                RetrievalEvalQuery(
                    question: question(from: chunk.text),
                    relevantIDs: [chunk.id],
                    sourceChunkID: chunk.id
                )
            }
        )
    }

    static func question(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        return "What does this passage cover: \(words)?"
    }

    static func decode(_ data: Data) throws -> RetrievalEvalSet {
        try JSONDecoder().decode(RetrievalEvalSet.self, from: data)
    }

    static func identity(name: String, queries: [RetrievalEvalQuery]) -> String {
        let body = queries.map { query in
            let ids = query.relevantIDs.joined(separator: ",")
            return "\(query.question)|\(ids)|\(query.sourceChunkID ?? "")"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(body.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(name)#\(hex)"
    }
}

struct TokenOverlapJudge: Sendable {
    var minimumOverlap: Int = 2

    func relevantIDs(question: String, hits: [RetrievalHit]) -> [String] {
        let queryTokens = Self.tokens(question)
        return hits.compactMap { hit in
            let overlap = queryTokens.intersection(Self.tokens(hit.text)).count
            return overlap >= minimumOverlap ? hit.id : nil
        }
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }
}

enum RetrievalEvalHistory {
    static func compare(_ runs: [RetrievalEvalDraft]) -> [RetrievalEvalComparison] {
        let grouped = Dictionary(grouping: runs, by: \.label)
        return grouped.keys.sorted().map { label in
            let items = grouped[label] ?? []
            let count = Double(items.count)
            func mean(_ value: (RetrievalEvalScore) -> Double) -> Double {
                guard !items.isEmpty else { return 0 }
                return items.reduce(0) { $0 + value($1.score) } / count
            }
            return RetrievalEvalComparison(
                label: label,
                runs: items.count,
                recallAtK: mean(\.recallAtK),
                mrr: mean(\.mrr),
                ndcgAtK: mean(\.ndcgAtK),
                hitRate: mean(\.hitRate),
                latencyMs: mean(\.latencyMs)
            )
        }
    }
}

struct RetrievalEvalRunner {
    var service: RetrievalService = RetrievalService()
    var judge: TokenOverlapJudge = TokenOverlapJudge()

    func run(
        set: RetrievalEvalSet,
        config: RetrievalEvalConfig,
        settings: AppSettings,
        index: (any RetrievalIndex)?
    ) async throws -> RetrievalEvalDraft {
        var rows: [RetrievalEvalMetrics.Row] = []
        for query in set.queries {
            let started = Date()
            let request = RetrievalRequest.make(
                text: query.question,
                collection: config.collection,
                mode: config.hybrid ? .hybrid : .dense,
                limit: config.k,
                backend: config.embeddingBackend,
                model: config.embeddingModel,
                filters: config.filters,
                rrfWeights: config.hybrid ? config.rrfWeights : nil,
                rerank: config.reranker ? config.rerank : nil,
                settings: settings
            )
            let page = try await service.search(request, index: index)
            let latency = Date().timeIntervalSince(started) * 1000
            var relevant = query.relevantIDs
            if relevant.isEmpty {
                relevant = judge.relevantIDs(question: query.question, hits: page.hits)
            }
            rows.append(
                RetrievalEvalMetrics.Row(
                    relevant: relevant,
                    retrieved: RetrievalEvalMetrics.rankedIDs(hits: page.hits, relevant: Set(relevant)),
                    latencyMs: latency
                )
            )
        }
        return RetrievalEvalDraft(
            setName: set.name,
            embeddingModel: config.embeddingModel,
            chunking: config.chunking,
            hybrid: config.hybrid,
            reranker: config.reranker,
            setIdentity: RetrievalEvalSets.identity(name: set.name, queries: set.queries),
            score: RetrievalEvalMetrics.summarize(rows, k: config.k),
            scope: RetrievalFilter.scopeLabel(config.filters + [RetrievalFilter(key: PaperLibrary.field, match: .text(LibraryFilter.assignedID(settings.activeLibraryID)))])
        )
    }
}
