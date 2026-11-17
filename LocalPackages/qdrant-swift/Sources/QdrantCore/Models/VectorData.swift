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
        } else if let mixed = try? container.decode([String: NamedVectorValue].self) {
            var dense: [String: [Float]] = [:]
            var sparse: [String: SparseVector] = [:]
            for (name, value) in mixed {
                switch value {
                case .dense(let values): dense[name] = values
                case .sparse(let values): sparse[name] = values
                }
            }
            self = .namedWithSparse(dense: dense, sparse: sparse)
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
        case .namedWithSparse(let dense, let sparse):
            var values = dense.mapValues { NamedVectorValue.dense($0) }
            for (name, vector) in sparse { values[name] = .sparse(vector) }
            try container.encode(values)
        }
    }
}

private enum NamedVectorValue: Codable {
    case dense([Float])
    case sparse(SparseVector)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([Float].self) {
            self = .dense(values)
        } else {
            self = .sparse(try container.decode(SparseVector.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dense(let values): try container.encode(values)
        case .sparse(let values): try container.encode(values)
        }
    }
}
