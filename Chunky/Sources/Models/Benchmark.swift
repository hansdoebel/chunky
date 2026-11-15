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
        copy.embeddingModel = runtime.embeddingModel
        copy.embeddingBackend = runtime.embeddingBackend
        copy.doclingModel = runtime.vlmModel
        copy.doOCR = runtime.ocr
        copy.devboxIngestTarget = .localDocker
        return copy
    }
}
