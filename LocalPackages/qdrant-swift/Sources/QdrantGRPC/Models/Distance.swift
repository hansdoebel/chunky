import Foundation
import QdrantCore
import QdrantProto

public typealias Distance = QdrantCore.Distance

extension Distance {

    internal var grpc: Qdrant_Distance {
        switch self {
        case .cosine: .cosine
        case .euclid: .euclid
        case .dot: .dot
        case .manhattan: .manhattan
        }
    }

    internal init?(grpc: Qdrant_Distance) {
        switch grpc {
        case .cosine: self = .cosine
        case .euclid: self = .euclid
        case .dot: self = .dot
        case .manhattan: self = .manhattan
        default: return nil
        }
    }
}
