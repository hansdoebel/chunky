import Foundation

enum EmbeddingPreferences {
    static let cpuModel = FastEmbedService.model
    static let cpuDimensions = FastEmbedService.dimensions

    static func host(backend: String, processingHost: ProcessingHost) -> String {
        backend == "fastembed" ? "Local Mac" : processingHost.rawValue
    }

    static func problem(backend: String, model: String, dimensions: Int, processingHost: ProcessingHost, plan: CollectionPlan?) -> String? {
        if backend == "fastembed" {
            if processingHost == .devbox {
                return "FastEmbed runs on the Local Mac CPU. Choose Local Mac processing before indexing; Devbox jobs cannot use this provider."
            }
            if model != cpuModel || dimensions != cpuDimensions {
                return "FastEmbed requires \(cpuModel) with \(cpuDimensions) dimensions."
            }
        }
        if backend == "fastembed" && plan == nil {
            return "This collection has no saved embedding model identity. Create a new collection for this CPU model before indexing or retrieval."
        }
        if let plan {
            if plan.embeddingBackend != backend || plan.embeddingModel != model {
                return "Collection \(plan.name) uses \(plan.embeddingBackend) / \(plan.embeddingModel). Choose its original embedding model or create a new collection. Matching dimensions alone do not establish compatibility."
            }
            if plan.vectorSize != dimensions {
                return "Collection \(plan.name) has \(plan.vectorSize) dimensions; the selected model uses \(dimensions). Create a new collection."
            }
        }
        return nil
    }
}

extension AppSettings {
    func selectEmbeddingBackend(_ backend: String) {
        guard backend != embeddingBackend else { return }
        let previous = "chunky.embeddingSelection.\(embeddingBackend)."
        defaults.set(embeddingModel, forKey: previous + "model")
        defaults.set(embeddingDimensions, forKey: previous + "dimensions")
        let next = "chunky.embeddingSelection.\(backend)."
        embeddingBackend = backend
        if backend == "fastembed" {
            embeddingModel = EmbeddingPreferences.cpuModel
            embeddingDimensions = EmbeddingPreferences.cpuDimensions
        } else if let saved = defaults.string(forKey: next + "model") {
            embeddingModel = saved
            embeddingDimensions = defaults.integer(forKey: next + "dimensions")
        } else if backend == "ollama" {
            embeddingModel = EmbeddingWidth.defaultModel
            embeddingDimensions = EmbeddingWidth.defaultDimensions
        } else {
            embeddingModel = "Qwen/Qwen3-Embedding-0.6B"
            embeddingDimensions = 1024
        }
    }

    var embeddingHostDescription: String {
        if embeddingBackend == "fastembed" { return "Local Mac" }
        let endpoint = embeddingBackend == "openai" ? embeddingAPIURL : ollamaURL
        return "\(endpoint) (from \(processingHost.rawValue))"
    }

    var embeddingConfigurationProblem: String? {
        EmbeddingPreferences.problem(
            backend: embeddingBackend, model: embeddingModel, dimensions: embeddingDimensions,
            processingHost: processingHost,
            plan: CollectionPlanStore.load(name: defaultCollection, defaults: defaults)
        )
    }
}
