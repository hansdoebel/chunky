import Foundation
import Testing

@testable import Chunky

struct EmbeddingDimensionTests {

    @Test func cacheStoresTheProbedWidthOnce() {
        var cache = EmbeddingDimensionCache()
        var probes = 0
        let first = try! cache.store(model: "qwen3-embedding", vector: [0, 1, 2])
        probes += 1
        #expect(first == 3)
        #expect(cache.cached("qwen3-embedding") == 3)

        let again = try! cache.store(model: "qwen3-embedding", vector: [9])
        #expect(again == 3)
        #expect(probes == 1)
    }

    @Test func emptyProbeFails() {
        var cache = EmbeddingDimensionCache()
        #expect(throws: EmbeddingDimensionError.emptyProbe("missing")) {
            try cache.store(model: "missing", vector: [])
        }
    }

    @Test func mismatchNamesTheCollectionAndBothSizes() {
        #expect(throws: EmbeddingDimensionError.self) {
            try EmbeddingDimensionError.validate(
                existing: 1024,
                probed: 768,
                collection: "documents",
                model: "qwen3-embedding"
            )
        }
        do {
            try EmbeddingDimensionError.validate(
                existing: 1024,
                probed: 768,
                collection: "documents",
                model: "qwen3-embedding"
            )
            Issue.record("expected a mismatch")
        } catch let error as EmbeddingDimensionError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("documents"))
            #expect(message.contains("1024"))
            #expect(message.contains("768"))
            #expect(message.contains("qwen3-embedding"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func matchingOrMissingCollectionIsAllowed() throws {
        try EmbeddingDimensionError.validate(
            existing: 1024,
            probed: 1024,
            collection: "documents",
            model: "qwen3-embedding"
        )
        try EmbeddingDimensionError.validate(
            existing: nil,
            probed: 768,
            collection: "documents",
            model: "qwen3-embedding"
        )
    }
}
