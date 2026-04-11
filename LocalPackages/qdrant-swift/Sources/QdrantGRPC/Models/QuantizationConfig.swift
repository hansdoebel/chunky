import Foundation
import QdrantCore
import QdrantProto

extension QuantizationConfig {
    internal var grpc: Qdrant_QuantizationConfig {
        var config = Qdrant_QuantizationConfig()
        switch self {
        case .scalar(let quantile, let alwaysRam):
            var scalar = Qdrant_ScalarQuantization()
            scalar.type = .int8
            if let quantile { scalar.quantile = quantile }
            if let alwaysRam { scalar.alwaysRam = alwaysRam }
            config.scalar = scalar
        case .binary(let alwaysRam):
            var binary = Qdrant_BinaryQuantization()
            if let alwaysRam { binary.alwaysRam = alwaysRam }
            config.binary = binary
        case .product(let compression, let alwaysRam):
            var product = Qdrant_ProductQuantization()
            product.compression = compression.grpc
            if let alwaysRam { product.alwaysRam = alwaysRam }
            config.product = product
        }
        return config
    }
}

extension ProductCompression {
    internal var grpc: Qdrant_CompressionRatio {
        switch self {
        case .x4: .x4
        case .x8: .x8
        case .x16: .x16
        case .x32: .x32
        case .x64: .x64
        }
    }
}
