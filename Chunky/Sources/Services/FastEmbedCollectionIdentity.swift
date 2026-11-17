import Foundation

enum FastEmbedCollectionIdentity {
    static func validate(collection: String, backend: String, model: String, defaults: UserDefaults = .standard, allowPreembeddedQuery: Bool = false) throws {
        try DatasetCloudCollectionIdentity.validate(collection: collection, backend: backend, model: model, defaults: defaults)
        if !allowPreembeddedQuery, try DatasetCloudCollectionIdentity.profile(collection: collection, defaults: defaults) != nil {
            throw DatasetCloudEmbeddingError.invalid("Pre-embedded dataset collections cannot receive ordinary document ingestion. Import another dataset into a new collection to preserve its verified vector identity.")
        }
        let plan = CollectionPlanStore.load(name: collection, defaults: defaults)
        guard backend == "fastembed" || plan?.embeddingBackend == "fastembed" else { return }
        guard let plan, plan.embeddingBackend == backend, plan.embeddingModel == model,
              model == FastEmbedService.model, plan.vectorSize == FastEmbedService.dimensions else {
            throw NSError(domain: "Chunky.FastEmbed", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Collection \(collection) does not have a verified matching local CPU model plan. Create a separate collection for \(FastEmbedService.model) (512 dimensions); existing collections are never converted automatically."])
        }
    }
}
