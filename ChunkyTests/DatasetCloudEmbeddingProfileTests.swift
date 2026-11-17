import Foundation
import Testing

@testable import Chunky

@MainActor
struct DatasetCloudEmbeddingProfileTests {
    let profile = DatasetCloudEmbeddingProfile.dbpedia

    @Test func sourceIdentityIncludesRevisionConfigurationAndSplit() {
        #expect(DatasetCloudEmbeddingProfile.matching(datasetID: profile.datasetID, revision: profile.revision, config: "default", split: "train") == profile)
        #expect(DatasetCloudEmbeddingProfile.matching(datasetID: profile.datasetID, revision: String(repeating: "a", count: 40), config: "default", split: "train") == nil)
        #expect(DatasetCloudEmbeddingProfile.matching(datasetID: profile.datasetID, revision: profile.revision, config: "other", split: "train") == nil)
        #expect(DatasetCloudEmbeddingProfile.matching(datasetID: "another/dataset", revision: profile.revision, config: "default", split: "train") == nil)
    }

    @Test func equalDimensionsDoNotPermitAnotherModelOrBackend() throws {
        try profile.validateConfiguration(backend: "openai", model: "text-embedding-3-small", dimensions: 1536)
        #expect(throws: Error.self) { try profile.validateConfiguration(backend: "openai", model: "text-embedding-ada-002", dimensions: 1536) }
        #expect(throws: Error.self) { try profile.validateConfiguration(backend: "ollama", model: profile.model, dimensions: 1536) }
        #expect(throws: Error.self) { try profile.validateConfiguration(backend: profile.backend, model: profile.model, dimensions: 512) }
    }

    @Test func namedColumnNeverFallsBackToLegacyOpenAIColumn() throws {
        let old = Array(repeating: -0.25, count: 1536)
        var row: [String: Any] = ["_id": "source", "combined_text": "Complete original input", "openai": old]
        #expect(throws: Error.self) { try profile.decodeRow(JSONSerialization.data(withJSONObject: row)) }
        row[profile.vectorField] = Array(repeating: 0.5, count: 1536)
        let result = try profile.decodeRow(JSONSerialization.data(withJSONObject: row))
        #expect(result.vector == Array(repeating: Float(0.5), count: 1536))
        #expect(result.text == "Complete original input")
        #expect(result.sourceID == "source")
    }

    @Test func invalidVectorsAndMissingTextAreRejected() throws {
        for bad: Any in [Array(repeating: 0, count: 1536), Array(repeating: true, count: 1536), Array(repeating: "0.1", count: 1536), Array(repeating: 1e300, count: 1536), [0.1]] {
            let data = try JSONSerialization.data(withJSONObject: ["_id": "id", "combined_text": "Text", profile.vectorField: bad])
            #expect(throws: Error.self) { try profile.decodeRow(data) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["_id": "id", "combined_text": "  ", profile.vectorField: Array(repeating: 0.1, count: 1536)])
        #expect(throws: Error.self) { try profile.decodeRow(data) }
    }

    @Test func queryResponseMustConfirmExactModelAndDimensions() throws {
        let row: [String: Any] = ["index": 0, "embedding": Array(repeating: 0.1, count: 1536)]
        #expect(try profile.decodeQueryResponse(JSONSerialization.data(withJSONObject: ["model": profile.model, "data": [row]])).count == 1536)
        for model in ["text-embedding-ada-002", "unknown", ""] {
            #expect(throws: Error.self) { try profile.decodeQueryResponse(JSONSerialization.data(withJSONObject: ["model": model, "data": [row]])) }
        }
        #expect(throws: Error.self) { try profile.decodeQueryResponse(JSONSerialization.data(withJSONObject: ["model": profile.model, "data": [row, row]])) }
        #expect(throws: Error.self) { try profile.decodeQueryResponse(JSONSerialization.data(withJSONObject: ["model": profile.model, "data": [["index": 0, "embedding": [0.1]]]])) }
    }

    @Test func queryRequestUsesDeclaredModelAndRejectsEmbeddedCredentials() throws {
        let request = try DatasetCloudPreembeddedQuery.request(profile: profile, endpoint: "http://localhost:8080", text: "Question")
        #expect(request.url?.path == "/v1/embeddings")
        let requestBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["model"] as? String == profile.model)
        #expect(body["input"] as? [String] == ["Question"])
        #expect(throws: Error.self) { try DatasetCloudPreembeddedQuery.request(profile: profile, endpoint: "https://user:secret@example.invalid", text: "Question") }
    }

    @Test func registryGuardsOnlyNewRegisteredCollections() throws {
        let suite = "DatasetProfileTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try DatasetCloudCollectionIdentity.validate(collection: "existing", backend: "ollama", model: "unchanged", defaults: defaults)
        try FastEmbedCollectionIdentity.validate(collection: "existing", backend: "ollama", model: "unchanged", defaults: defaults)
        #expect(throws: Error.self) { try DatasetCloudCollectionIdentity.register(collection: "existing", profile: profile, defaults: defaults) }
        let name = "chunky-dataset-test-" + UUID().uuidString.lowercased()
        try DatasetCloudCollectionIdentity.register(collection: name, profile: profile, defaults: defaults)
        #expect(try DatasetCloudCollectionIdentity.profile(collection: name, defaults: defaults) == profile)
        #expect(throws: Error.self) { try DatasetCloudCollectionIdentity.validate(collection: name, backend: "openai", model: "text-embedding-ada-002", defaults: defaults) }
        #expect(throws: Error.self) { try FastEmbedCollectionIdentity.validate(collection: name, backend: profile.backend, model: profile.model, defaults: defaults) }
        try FastEmbedCollectionIdentity.validate(collection: name, backend: profile.backend, model: profile.model, defaults: defaults, allowPreembeddedQuery: true)
    }

    @Test func corruptSavedIdentityFailsClosed() throws {
        let suite = "DatasetProfileTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "chunky.datasetCloud.embeddingProfiles")
        #expect(throws: Error.self) { try DatasetCloudCollectionIdentity.profile(collection: "anything", defaults: defaults) }
    }

    #if os(macOS)
    @Test func strictQueryChecksTheActualGatewayResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DatasetProfileURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        #expect(try await DatasetCloudPreembeddedQuery.embed(profile: profile, endpoint: "https://matching.invalid", text: "Question", session: session).count == 1536)
        await #expect(throws: Error.self) {
            try await DatasetCloudPreembeddedQuery.embed(profile: profile, endpoint: "https://mismatch.invalid", text: "Question", session: session)
        }
    }
    #endif
}

#if os(macOS)
nonisolated private final class DatasetProfileURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let model = request.url?.host == "matching.invalid" ? "text-embedding-3-small" : "text-embedding-ada-002"
        let data = try! JSONSerialization.data(withJSONObject: ["model": model, "data": [["index": 0, "embedding": Array(repeating: 0.1, count: 1536)]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
