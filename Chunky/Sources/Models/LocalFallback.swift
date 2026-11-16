import Foundation

enum LocalFallbackError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "The worker is unreachable. Local fallback cannot start: \(reason)"
        }
    }
}

enum LocalFallbackPolicy {
    static func isUnreachable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet, .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }

    static func isLoopback(_ raw: String) -> Bool {
        guard let url = URLComponents(string: raw),
              url.scheme == "http" || url.scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

struct LocalFallbackPlan {
    let settings: AppSettings
    let defaultsDomain: String
    let cacheDirectory: URL
    let notice: String

    static func make(from original: AppSettings, mode: ProcessingMode, collection: String) throws -> LocalFallbackPlan {
        let needsVLMAPI = original.doPictureDescription
            && original.resolvedPictureDescriptionPreset == PictureDescriptionPreset.api.rawValue
        guard !needsVLMAPI || LocalFallbackPolicy.isLoopback(original.vlmServerURL) else {
            throw LocalFallbackError.unavailable("the VLM server must be local.")
        }
        guard let model = DoclingModel(rawValue: original.doclingModel) else {
            throw LocalFallbackError.unavailable("select a supported local conversion model.")
        }
        if mode == .full {
            guard LocalFallbackPolicy.isLoopback(original.ollamaURL) else {
                throw LocalFallbackError.unavailable("set the Ollama URL to a loopback address before enabling fallback.")
            }
            guard original.embeddingBackend == EmbeddingBackendKind.ollama.rawValue else {
                throw LocalFallbackError.unavailable("automatic fallback currently requires the Ollama embedding provider.")
            }
            guard LocalFallbackPolicy.isLoopback(original.qdrantURL), original.qdrantAPIKey.isEmpty else {
                throw LocalFallbackError.unavailable("use a loopback Qdrant server without a Cloud API key.")
            }
            guard let plan = CollectionPlanStore.load(name: collection, defaults: original.defaults),
                  plan.target == .localDocker,
                  plan.embeddingBackend == original.embeddingBackend,
                  plan.embeddingModel == original.embeddingModel,
                  plan.vectorSize == original.embeddingDimensions else {
                throw LocalFallbackError.unavailable("save a Local Docker collection plan with the selected embedding model and dimensions first.")
            }
        }
        let domain = "chunky.local-fallback.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw LocalFallbackError.unavailable("temporary settings could not be created.")
        }
        for (key, value) in original.defaults.dictionaryRepresentation() where key.hasPrefix("chunky.") {
            defaults.set(value, forKey: key)
        }
        let snapshot = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        snapshot.processingHost = .localMac
        snapshot.allowLocalFallback = false
        snapshot.ollamaURL = original.ollamaURL
        snapshot.qdrantURL = original.qdrantURL
        snapshot.devboxIngestTarget = .localDocker
        snapshot.devboxWorkerURL = ""
        snapshot.embeddingAPIURL = ""
        snapshot.chatModel = ""
        snapshot.chatAPIURL = ""
        if !needsVLMAPI { snapshot.vlmServerURL = "" }
        snapshot.enableEmbeddingCache = false
        snapshot.doclingAccelerator = ProcessingHost.localMac.defaultAccelerator.rawValue
        switch model {
        case .graniteDoclingTransformers: snapshot.doclingModel = DoclingModel.graniteDoclingMLX.rawValue
        case .smoldoclingTransformers: snapshot.doclingModel = DoclingModel.smoldoclingMLX.rawValue
        default: snapshot.doclingModel = model.rawValue
        }
        let destination = mode == .full ? "local Ollama and local Qdrant" : "local conversion and export"
        return LocalFallbackPlan(
            settings: snapshot,
            defaultsDomain: domain,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true),
            notice: "Worker unreachable. Running on Local Mac with \(snapshot.doclingModel), \(destination)."
        )
    }

    func discard() {
        settings.defaults.removePersistentDomain(forName: defaultsDomain)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
