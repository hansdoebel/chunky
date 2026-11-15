import Foundation
import QdrantCore
import QdrantProto

public typealias CollectionStatus = QdrantCore.CollectionStatus
public typealias CollectionInfo = QdrantCore.CollectionInfo
public typealias CollectionDescription = QdrantCore.CollectionDescription
public typealias AliasDescription = QdrantCore.AliasDescription

extension CollectionStatus {
    internal init(grpc: Qdrant_CollectionStatus) {
        self =
            switch grpc {
            case .green: .green
            case .yellow: .yellow
            case .red: .red
            case .grey: .grey
            default: .unknown
            }
    }
}

extension CollectionInfo {
    internal init(name: String, grpc: Qdrant_CollectionInfo) {
        self.init(
            name: name,
            status: CollectionStatus(grpc: grpc.status),
            indexedVectorsCount: grpc.hasIndexedVectorsCount ? grpc.indexedVectorsCount : nil,
            pointsCount: grpc.hasPointsCount ? grpc.pointsCount : nil,
            segmentsCount: grpc.segmentsCount,
            vectorSize: Self.denseVectorSize(from: grpc),
            vectorName: Self.denseVectorName(from: grpc)
        )
    }

    static func denseVectorName(from grpc: Qdrant_CollectionInfo) -> String? {
        guard grpc.hasConfig, grpc.config.hasParams, grpc.config.params.hasVectorsConfig else {
            return nil
        }
        switch grpc.config.params.vectorsConfig.config {
        case .params:
            return nil
        case .paramsMap(let map):
            if map.map["dense"] != nil {
                return "dense"
            }
            if map.map.count == 1 {
                return map.map.keys.first
            }
            return nil
        case nil:
            return nil
        }
    }

    static func denseVectorSize(from grpc: Qdrant_CollectionInfo) -> UInt64? {
        guard grpc.hasConfig, grpc.config.hasParams, grpc.config.params.hasVectorsConfig else {
            return nil
        }
        switch grpc.config.params.vectorsConfig.config {
        case .params(let params):
            return params.size
        case .paramsMap(let map):
            if let dense = map.map["dense"] {
                return dense.size
            }
            return map.map.values.first?.size
        case nil:
            return nil
        }
    }
}

extension CollectionDescription {
    internal init(grpc: Qdrant_CollectionDescription) {
        self.init(name: grpc.name)
    }
}

extension AliasDescription {
    internal init(grpc: Qdrant_AliasDescription) {
        self.init(aliasName: grpc.aliasName, collectionName: grpc.collectionName)
    }
}
