import Foundation

public enum QuantizationConfig: Sendable {
    case scalar(quantile: Float?, alwaysRam: Bool?)
    case binary(alwaysRam: Bool?)
    case product(compression: ProductCompression, alwaysRam: Bool?)
}

public enum ProductCompression: Sendable {
    case x4, x8, x16, x32, x64
}
