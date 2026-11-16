import Foundation

struct BenchmarkSample: Identifiable, Equatable, Codable {
    var id: String
    var filename: String
    var kind: String
}

struct BenchmarkRuntime: Identifiable, Equatable, Codable {
    var id: String
    var label: String
    var embeddingModel: String
    var embeddingBackend: String
    var vlmModel: String
    var ocr: Bool
}

enum BenchmarkPhase: String, Equatable, Codable {
    case warmup
    case timed

    var label: String {
        switch self {
        case .warmup: return "warm-up"
        case .timed: return "timed"
        }
    }
}

struct BenchmarkCell: Identifiable, Equatable {
    var host: ProcessingHost
    var runtime: BenchmarkRuntime
    var sample: BenchmarkSample
    var phase: BenchmarkPhase

    var id: String { "\(host.rawValue)|\(runtime.id)|\(sample.id)|\(phase.rawValue)" }
}

enum BenchmarkPlanner {
    static let samples: [BenchmarkSample] = [
        BenchmarkSample(id: "sample", filename: "sample.pdf", kind: "Sample"),
        BenchmarkSample(id: "multipage", filename: "benchmark-multipage.pdf", kind: "Born-digital"),
        BenchmarkSample(id: "scan", filename: "benchmark-scan.pdf", kind: "Scan-like"),
        BenchmarkSample(id: "tables", filename: "benchmark-tables.pdf", kind: "Tables"),
    ]

    static func offeredRuntimes(settings: AppSettings) -> [BenchmarkRuntime] {
        let model = settings.embeddingModel
        let backend = settings.embeddingBackend
        var runtimes = [
            BenchmarkRuntime(id: "embed", label: "Embed only", embeddingModel: model, embeddingBackend: backend, vlmModel: "standard", ocr: false),
            BenchmarkRuntime(id: "ocr", label: "OCR", embeddingModel: model, embeddingBackend: backend, vlmModel: "standard", ocr: true),
        ]
        if settings.doclingModel != "standard" {
            runtimes.append(
                BenchmarkRuntime(
                    id: "vlm",
                    label: "VLM",
                    embeddingModel: model,
                    embeddingBackend: backend,
                    vlmModel: settings.doclingModel,
                    ocr: false
                )
            )
        }
        return runtimes
    }

    static func collectionName(production: String) -> String {
        var name = "chunky-benchmark-\(UUID().uuidString.prefix(8))"
        if name == production {
            name += "-run"
        }
        return String(name)
    }

    static func accepts(collection: String, production: String) -> Bool {
        collection.hasPrefix("chunky-benchmark-") && collection != production
    }

    static func cells(
        hosts: [ProcessingHost],
        runtimes: [BenchmarkRuntime],
        samples: [BenchmarkSample]
    ) -> [BenchmarkCell] {
        var planned: [BenchmarkCell] = []
        for host in hosts {
            for runtime in runtimes {
                for sample in samples {
                    planned.append(BenchmarkCell(host: host, runtime: runtime, sample: sample, phase: .warmup))
                    planned.append(BenchmarkCell(host: host, runtime: runtime, sample: sample, phase: .timed))
                }
            }
        }
        return planned
    }

    static func summary(completed: Int, failed: Int, skipped: Int, cancelled: Bool) -> String {
        let counts = "\(completed) completed, \(failed) failed, \(skipped) skipped"
        if cancelled {
            return "Cancelled. \(counts)."
        }
        if failed > 0 || skipped > 0 {
            return counts + "."
        }
        return "\(completed) completed."
    }

    static func url(for sample: BenchmarkSample) -> URL? {
        let stem = (sample.filename as NSString).deletingPathExtension
        if let bundled = Bundle.main.url(forResource: stem, withExtension: "pdf", subdirectory: "Benchmark") {
            return bundled
        }
        return Bundle.main.url(forResource: stem, withExtension: "pdf")
    }
}

extension AppSettings {
    func benchmarkCopy(collection: String, host: ProcessingHost, runtime: BenchmarkRuntime) -> AppSettings {
        let name = "chunky-benchmark-defaults-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("chunky.") {
            suite.set(value, forKey: key)
        }
        let memory = MemorySecretStore()
        memory.set(ollamaURL, for: KeychainService.ollamaURLKey)
        memory.set(qdrantURL, for: KeychainService.qdrantURLKey)
        memory.set(qdrantCloudURL, for: KeychainService.qdrantCloudURLKey)
        memory.set(qdrantAPIKey, for: KeychainService.qdrantAPIKeyKey)
        memory.set(workerToken, for: KeychainService.workerTokenKey)
        let copy = AppSettings(defaults: suite, secrets: memory)
        copy.defaultCollection = collection
        copy.processingHost = host
        copy.doclingAccelerator = host.defaultAccelerator.rawValue
        copy.embeddingModel = runtime.embeddingModel
        copy.embeddingBackend = runtime.embeddingBackend
        copy.doclingModel = runtime.vlmModel
        copy.doOCR = runtime.ocr
        copy.devboxIngestTarget = .localDocker
        copy.enableEmbeddingCache = false
        return copy
    }
}

struct EmbeddingBenchmarkReport: Codable, Equatable {
    struct QueryResult: Codable, Equatable {
        var queryID: UUID
        var retrievedIDs: [String]
        var latencyMs: Double
    }

    struct Run: Codable, Equatable, Identifiable {
        var id: UUID
        var corpusSHA256: String
        var model: String
        var modelRevision: String
        var dimensions: Int
        var machine: String
        var runtime: String
        var collection: String
        var hybrid: Bool
        var coldStartupMs: Double
        var warmStartupMs: Double
        var embeddingSeconds: Double
        var indexingSeconds: Double
        var peakMemoryBytes: UInt64
        var results: [QueryResult]

        func score(set: RetrievalEvalSet) -> RetrievalEvalScore {
            let labels = Dictionary(uniqueKeysWithValues: set.queries.map { ($0.id, $0.relevantIDs) })
            return RetrievalEvalMetrics.summarize(results.map {
                RetrievalEvalMetrics.Row(relevant: labels[$0.queryID] ?? [], retrieved: $0.retrievedIDs, latencyMs: $0.latencyMs)
            }, k: 10)
        }
    }

    var schemaVersion: Int
    var corpusSHA256: String
    var chunkCount: Int
    var chunking: String
    var set: RetrievalEvalSet
    var runs: [Run]

    static func decode(_ data: Data, productionCollection: String) throws -> Self {
        let report = try JSONDecoder().decode(Self.self, from: data)
        try report.validate(productionCollection: productionCollection)
        return report
    }

    func validate(productionCollection: String) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "EmbeddingBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try require(schemaVersion == 1, "Unsupported benchmark report version.")
        try require(corpusSHA256.count == 64 && corpusSHA256.allSatisfy { $0.isHexDigit }, "Record the SHA-256 of the frozen cached chunks.")
        try require(chunkCount > 0 && !chunking.isEmpty, "Record the cached chunk count and chunking configuration.")
        let queryIDs = Set(set.queries.map(\.id))
        try require(!queryIDs.isEmpty && queryIDs.count == set.queries.count, "The fixed query set must contain unique IDs.")
        try require(set.queries.allSatisfy { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.relevantIDs.isEmpty }, "Every query needs a question and relevance labels.")
        try require(!runs.isEmpty && Set(runs.map(\.id)).count == runs.count, "Include uniquely identified measured runs.")
        for run in runs {
            try require(run.corpusSHA256 == corpusSHA256, "Each model must use the identical frozen cached chunks.")
            try require([run.model, run.modelRevision, run.machine, run.runtime].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "Record model revision, machine and inference runtime.")
            try require(run.dimensions > 0 && run.peakMemoryBytes > 0, "Record measured vector dimensions and embedding-host peak memory.")
            try require(BenchmarkPlanner.accepts(collection: run.collection, production: productionCollection), "Benchmark collections must be separate from production.")
            try require([run.coldStartupMs, run.warmStartupMs, run.embeddingSeconds, run.indexingSeconds].allSatisfy { $0.isFinite && $0 >= 0 } && run.embeddingSeconds > 0 && run.indexingSeconds >= run.embeddingSeconds, "Timings must be finite, nonnegative measurements with positive embedding duration.")
            try require(Set(run.results.map(\.queryID)) == queryIDs && run.results.count == queryIDs.count, "Every run must evaluate exactly the same labeled queries once.")
            try require(run.results.allSatisfy { $0.latencyMs.isFinite && $0.latencyMs >= 0 && Set($0.retrievedIDs).count == $0.retrievedIDs.count }, "Query timings must be finite and ranked IDs must be unique.")
        }
        let groups = Dictionary(grouping: runs, by: { [$0.model, $0.modelRevision, String($0.dimensions), $0.machine, $0.runtime].joined(separator: "|") })
        try require(Set(runs.map(\.model)).count >= 2 && groups.values.allSatisfy { Set($0.map(\.hybrid)) == [false, true] }, "Compare at least two models, each with dense and BM25 hybrid runs.")
        for group in groups.values {
            try require(Set(group.map(\.collection)).count == 1, "Dense and hybrid retrieval must use the same indexed collection for each model.")
        }
        let modelCollections = groups.values.compactMap { $0.first?.collection }
        try require(Set(modelCollections).count == modelCollections.count, "Different model configurations require separate benchmark collections.")
    }
}
