import Foundation

public struct SparseVector: Sendable, Codable, Hashable {
    public let indices: [UInt32]
    public let values: [Float]

    public init(indices: [UInt32], values: [Float]) {
        self.indices = indices
        self.values = values
    }
}

public enum VectorData: Sendable {
    case dense([Float])

    case named([String: [Float]])

    case namedWithSparse(dense: [String: [Float]], sparse: [String: SparseVector])

    public static func from(_ data: [Float]) -> VectorData {
        .dense(data)
    }

    public static func from(_ data: [Double]) -> VectorData {
        .dense(data.map { Float($0) })
    }
}

extension VectorData: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let array = try? container.decode([Float].self) {
            self = .dense(array)
        } else if let dict = try? container.decode([String: [Float]].self) {
            self = .named(dict)
        } else {
            throw DecodingError.typeMismatch(
                VectorData.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected [Float] or [String: [Float]]")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dense(let array): try container.encode(array)
        case .named(let dict): try container.encode(dict)
        case .namedWithSparse(let dense, _): try container.encode(dense)
        }
    }
}
