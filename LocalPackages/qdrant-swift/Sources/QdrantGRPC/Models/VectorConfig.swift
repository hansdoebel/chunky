import Foundation
import QdrantCore
import QdrantProto

public typealias VectorConfig = QdrantCore.VectorConfig
public typealias VectorsConfig = QdrantCore.VectorsConfig
public typealias SparseVectorParams = QdrantCore.SparseVectorParams
public typealias SparseVectorModifier = QdrantCore.SparseVectorModifier

extension VectorConfig {

    internal var grpcParams: Qdrant_VectorParams {
        var params = Qdrant_VectorParams()
        params.size = size
        params.distance = distance.grpc
        if let onDisk = onDisk {
            params.onDisk = onDisk
        }
        return params
    }
}

extension VectorsConfig {

    internal var grpc: Qdrant_VectorsConfig {
        var config = Qdrant_VectorsConfig()
        switch self {
        case .single(let vectorConfig):
            config.params = vectorConfig.grpcParams
        case .named(let namedConfigs):
            var paramsMap = Qdrant_VectorParamsMap()
            for (name, vectorConfig) in namedConfigs {
                paramsMap.map[name] = vectorConfig.grpcParams
            }
            config.paramsMap = paramsMap
        }
        return config
    }
}
