import Foundation
import Testing
import QdrantCore
import QdrantProto
@testable import QdrantGRPC

@Suite("Chunky compatibility")
struct ChunkyCompatibilityTests {
    @Test func hybridUpsertPreservesDenseAndSparseVectors() throws {
        let values = VectorData.namedWithSparse(dense: ["dense": [0.1, 0.2]], sparse: ["sparse": SparseVector(indices: [4, 12], values: [0.5, 1])])
        #expect(values.grpc.vectors.vectors["dense"]?.dense.data == [0.1, 0.2])
        #expect(values.grpc.vectors.vectors["sparse"]?.sparse.indices == [4, 12])
        let encoded = try JSONEncoder().encode(values)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let sparse = try #require(object["sparse"] as? [String: Any])
        #expect(sparse["indices"] as? [Int] == [4, 12])
        let decoded = try JSONDecoder().decode(VectorData.self, from: encoded)
        #expect(decoded.grpc.vectors.vectors["sparse"]?.sparse.values == [0.5, 1])
    }

    @Test func namedDenseIdentitySurvivesMetadataMapping() {
        var raw = Qdrant_CollectionInfo()
        var dense = Qdrant_VectorParams()
        dense.size = 1024
        var other = Qdrant_VectorParams()
        other.size = 384
        var map = Qdrant_VectorParamsMap()
        map.map = ["dense": dense, "other": other]
        raw.config.params.vectorsConfig.paramsMap = map
        let info = QdrantCore.CollectionInfo(name: "fixture", grpc: raw)
        #expect(info.vectorSize == 1024)
        #expect(info.vectorName == "dense")
        map.map = ["custom": other]
        raw.config.params.vectorsConfig.paramsMap = map
        let custom = QdrantCore.CollectionInfo(name: "fixture", grpc: raw)
        #expect(custom.vectorName == "custom")
        #expect(custom.vectorSize == 384)
    }

    @Test func tenantIndexIsPreserved() {
        let request = IndexService.legacyIndexRequest(collection: "fixture", fieldName: "library_id", fieldType: .keyword, wait: false, isTenant: true)
        #expect(request.fieldIndexParams.keywordIndexParams.isTenant)
        #expect(!request.wait)
        let ordinary = IndexService.legacyIndexRequest(collection: "fixture", fieldName: "source", fieldType: .keyword, wait: false, isTenant: false)
        #expect(!ordinary.hasFieldIndexParams)
    }

    @Test func ambiguousNamedVectorsDoNotInventIdentity() {
        var raw = Qdrant_CollectionInfo()
        var params = Qdrant_VectorParams()
        params.size = 384
        var map = Qdrant_VectorParamsMap()
        map.map = ["first": params, "second": params]
        raw.config.params.vectorsConfig.paramsMap = map
        let info = QdrantCore.CollectionInfo(name: "fixture", grpc: raw)
        #expect(info.vectorSize == nil)
        #expect(info.vectorName == nil)
    }

    @Test func unnamedAndMissingIdentityStayDistinct() {
        var raw = Qdrant_CollectionInfo()
        #expect(QdrantCore.CollectionInfo(name: "fixture", grpc: raw).vectorSize == nil)
        raw.config.params.vectorsConfig.params.size = 768
        let info = QdrantCore.CollectionInfo(name: "fixture", grpc: raw)
        #expect(info.vectorSize == 768)
        #expect(info.vectorName == nil)
    }

    @Test func legacyHybridCreationPreservesSparseAndQuantizationOptions() {
        let request = CollectionsService.legacyCreateRequest(name: "fixture", vectors: .named(["dense": VectorConfig(size: 1024, distance: .cosine, onDisk: true)]), sparseVectors: ["sparse": SparseVectorParams(modifier: .idf)], onDiskPayload: true, quantizationConfig: .scalar(quantile: 0.99, alwaysRam: false))
        #expect(request.collectionName == "fixture")
        #expect(request.vectorsConfig.paramsMap.map["dense"]?.size == 1024)
        #expect(request.vectorsConfig.paramsMap.map["dense"]?.onDisk == true)
        #expect(request.sparseVectorsConfig.map["sparse"]?.modifier == .idf)
        #expect(request.onDiskPayload)
        #expect(request.quantizationConfig.scalar.quantile == 0.99)
        #expect(request.quantizationConfig.scalar.hasAlwaysRam)
        #expect(!request.quantizationConfig.scalar.alwaysRam)
    }

    @Test func legacyBinaryAndProductRemainAvailable() {
        #expect(QuantizationConfig.binary(alwaysRam: true).grpc.binary.alwaysRam)
        #expect(QuantizationConfig.product(compression: .x16, alwaysRam: nil).grpc.product.compression == .x16)
    }
}
