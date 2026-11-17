import QdrantCore
import QdrantProto

extension SparseVectorModifier {
    var grpc: Qdrant_Modifier {
        switch self {
        case .idf: .idf
        }
    }
}
