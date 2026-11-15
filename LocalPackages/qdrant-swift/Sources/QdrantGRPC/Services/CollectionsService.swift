import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import QdrantCore
import QdrantProto

public final class CollectionsService: Sendable {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let apiKey: String?

    internal init(client: GRPCClient<HTTP2ClientTransport.Posix>, apiKey: String?) {
        self.grpcClient = client
        self.apiKey = apiKey
    }

    private var metadata: Metadata {
        var metadata = Metadata()
        if let apiKey = apiKey {
            metadata.addString(apiKey, forKey: "api-key")
        }
        return metadata
    }

    public func list() async throws -> [CollectionDescription] {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)
        let request = ClientRequest(message: Qdrant_ListCollectionsRequest(), metadata: metadata)

        do {
            let response: Qdrant_ListCollectionsResponse = try await client.list(request: request)
            return response.collections.map { CollectionDescription(grpc: $0) }
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func get(name: String) async throws -> CollectionInfo {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_GetCollectionInfoRequest()
        grpcRequest.collectionName = name

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_GetCollectionInfoResponse = try await client.get(request: request)
            guard response.hasResult else {
                throw QdrantError.unexpectedResponse("No collection info returned")
            }
            return CollectionInfo(name: name, grpc: response.result)
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func exists(name: String) async throws -> Bool {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_CollectionExistsRequest()
        grpcRequest.collectionName = name

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionExistsResponse = try await client.collectionExists(
                request: request)
            return response.result.exists
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func create(
        name: String,
        vectorSize: UInt64,
        distance: Distance,
        onDiskPayload: Bool? = nil,
        quantizationConfig: QuantizationConfig? = nil
    ) async throws {
        let config = VectorConfig(size: vectorSize, distance: distance)
        try await create(name: name, vectors: .single(config), onDiskPayload: onDiskPayload, quantizationConfig: quantizationConfig)
    }

    public func create(
        name: String,
        vectorSize: Int,
        distance: Distance,
        onDiskPayload: Bool? = nil,
        quantizationConfig: QuantizationConfig? = nil
    ) async throws {
        try await create(
            name: name, vectorSize: UInt64(vectorSize), distance: distance,
            onDiskPayload: onDiskPayload, quantizationConfig: quantizationConfig)
    }

    public func create(
        name: String,
        vectors: [String: VectorConfig],
        onDiskPayload: Bool? = nil,
        quantizationConfig: QuantizationConfig? = nil
    ) async throws {
        try await create(name: name, vectors: .named(vectors), onDiskPayload: onDiskPayload, quantizationConfig: quantizationConfig)
    }

    public func create(
        name: String,
        vectors: VectorsConfig,
        sparseVectors: [String: SparseVectorParams]? = nil,
        onDiskPayload: Bool? = nil,
        quantizationConfig: QuantizationConfig? = nil
    ) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_CreateCollection()
        grpcRequest.collectionName = name
        grpcRequest.vectorsConfig = vectors.grpc

        if let sparseVectors = sparseVectors {
            var sparseConfig = Qdrant_SparseVectorConfig()
            for (name, params) in sparseVectors {
                var grpcParams = Qdrant_SparseVectorParams()
                if let modifier = params.modifier {
                    grpcParams.modifier = modifier.grpc
                }
                sparseConfig.map[name] = grpcParams
            }
            grpcRequest.sparseVectorsConfig = sparseConfig
        }

        if let onDiskPayload = onDiskPayload {
            grpcRequest.onDiskPayload = onDiskPayload
        }

        if let quantizationConfig = quantizationConfig {
            grpcRequest.quantizationConfig = quantizationConfig.grpc
        }

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionOperationResponse = try await client.create(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Collection creation failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func update(
        name: String,
        replicationFactor: UInt32? = nil,
        writeConsistencyFactor: UInt32? = nil,
        onDiskPayload: Bool? = nil,
        indexingThreshold: UInt64? = nil
    ) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_UpdateCollection()
        grpcRequest.collectionName = name

        if replicationFactor != nil || writeConsistencyFactor != nil || onDiskPayload != nil {
            var params = Qdrant_CollectionParamsDiff()
            if let replicationFactor = replicationFactor {
                params.replicationFactor = replicationFactor
            }
            if let writeConsistencyFactor = writeConsistencyFactor {
                params.writeConsistencyFactor = writeConsistencyFactor
            }
            if let onDiskPayload = onDiskPayload {
                params.onDiskPayload = onDiskPayload
            }
            grpcRequest.params = params
        }

        if let indexingThreshold = indexingThreshold {
            var optimizers = Qdrant_OptimizersConfigDiff()
            optimizers.indexingThreshold = indexingThreshold
            grpcRequest.optimizersConfig = optimizers
        }

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionOperationResponse = try await client.update(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Collection update failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func delete(name: String) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_DeleteCollection()
        grpcRequest.collectionName = name

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionOperationResponse = try await client.delete(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Collection deletion failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func createAlias(alias: String, collection: String) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var createAlias = Qdrant_CreateAlias()
        createAlias.collectionName = collection
        createAlias.aliasName = alias

        var action = Qdrant_AliasOperations()
        action.createAlias = createAlias

        var grpcRequest = Qdrant_ChangeAliases()
        grpcRequest.actions = [action]

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionOperationResponse = try await client.updateAliases(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Alias creation failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func renameAlias(oldAlias: String, newAlias: String) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var renameAlias = Qdrant_RenameAlias()
        renameAlias.oldAliasName = oldAlias
        renameAlias.newAliasName = newAlias

        var action = Qdrant_AliasOperations()
        action.renameAlias = renameAlias

        var grpcRequest = Qdrant_ChangeAliases()
        grpcRequest.actions = [action]

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionOperationResponse = try await client.updateAliases(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Alias rename failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func deleteAlias(alias: String) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var deleteAlias = Qdrant_DeleteAlias()
        deleteAlias.aliasName = alias

        var action = Qdrant_AliasOperations()
        action.deleteAlias = deleteAlias

        var grpcRequest = Qdrant_ChangeAliases()
        grpcRequest.actions = [action]

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionOperationResponse = try await client.updateAliases(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Alias deletion failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func listAliases(collection: String) async throws -> [AliasDescription] {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_ListCollectionAliasesRequest()
        grpcRequest.collectionName = collection

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_ListAliasesResponse = try await client.listCollectionAliases(
                request: request)
            return response.aliases.map { AliasDescription(grpc: $0) }
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func listAllAliases() async throws -> [AliasDescription] {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        let grpcRequest = Qdrant_ListAliasesRequest()
        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_ListAliasesResponse = try await client.listAliases(
                request: request)
            return response.aliases.map { AliasDescription(grpc: $0) }
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func collectionClusterInfo(name: String) async throws -> CollectionClusterInfo {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_CollectionClusterInfoRequest()
        grpcRequest.collectionName = name

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CollectionClusterInfoResponse =
                try await client.collectionClusterInfo(request: request)
            return CollectionClusterInfo(grpc: response)
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func createShardKey(
        collection: String,
        shardKey: ShardKey,
        shardsNumber: UInt32? = nil,
        replicationFactor: UInt32? = nil,
        placement: [UInt64] = []
    ) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var createRequest = Qdrant_CreateShardKey()
        createRequest.shardKey = shardKey.grpc

        if let shardsNumber = shardsNumber {
            createRequest.shardsNumber = shardsNumber
        }

        if let replicationFactor = replicationFactor {
            createRequest.replicationFactor = replicationFactor
        }

        createRequest.placement = placement

        var grpcRequest = Qdrant_CreateShardKeyRequest()
        grpcRequest.collectionName = collection
        grpcRequest.request = createRequest

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_CreateShardKeyResponse = try await client.createShardKey(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Shard key creation failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func deleteShardKey(
        collection: String,
        shardKey: ShardKey
    ) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var deleteRequest = Qdrant_DeleteShardKey()
        deleteRequest.shardKey = shardKey.grpc

        var grpcRequest = Qdrant_DeleteShardKeyRequest()
        grpcRequest.collectionName = collection
        grpcRequest.request = deleteRequest

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_DeleteShardKeyResponse = try await client.deleteShardKey(
                request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Shard key deletion failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }

    public func updateCollectionClusterSetup(
        collection: String,
        operation: ClusterOperation
    ) async throws {
        let client = Qdrant_Collections.Client(wrapping: grpcClient)

        var grpcRequest = Qdrant_UpdateCollectionClusterSetupRequest()
        grpcRequest.collectionName = collection

        switch operation {
        case .moveShard(let from, let to, let shardId, let method):
            var move = Qdrant_MoveShard()
            move.shardID = shardId
            move.fromPeerID = from
            move.toPeerID = to
            if let method = method {
                move.method = method.grpc
            }
            grpcRequest.moveShard = move

        case .replicateShard(let from, let to, let shardId, let method):
            var replicate = Qdrant_ReplicateShard()
            replicate.shardID = shardId
            replicate.fromPeerID = from
            replicate.toPeerID = to
            if let method = method {
                replicate.method = method.grpc
            }
            grpcRequest.replicateShard = replicate

        case .abortTransfer(let from, let to, let shardId):
            var abort = Qdrant_AbortShardTransfer()
            abort.shardID = shardId
            abort.fromPeerID = from
            abort.toPeerID = to
            grpcRequest.abortTransfer = abort

        case .dropReplica(let peerId, let shardId):
            var drop = Qdrant_Replica()
            drop.shardID = shardId
            drop.peerID = peerId
            grpcRequest.dropReplica = drop

        case .createShardKey(let key, let shardsNumber, let replicationFactor, let placement):
            var create = Qdrant_CreateShardKey()
            create.shardKey = key.grpc
            if let shardsNumber = shardsNumber {
                create.shardsNumber = shardsNumber
            }
            if let replicationFactor = replicationFactor {
                create.replicationFactor = replicationFactor
            }
            create.placement = placement
            grpcRequest.createShardKey = create

        case .deleteShardKey(let key):
            var delete = Qdrant_DeleteShardKey()
            delete.shardKey = key.grpc
            grpcRequest.deleteShardKey = delete

        case .restartTransfer(let from, let to, let shardId, let method):
            var restart = Qdrant_RestartTransfer()
            restart.shardID = shardId
            restart.fromPeerID = from
            restart.toPeerID = to
            if let method = method {
                restart.method = method.grpc
            }
            grpcRequest.restartTransfer = restart
        }

        let request = ClientRequest(message: grpcRequest, metadata: metadata)

        do {
            let response: Qdrant_UpdateCollectionClusterSetupResponse =
                try await client.updateCollectionClusterSetup(request: request)
            if !response.result {
                throw QdrantError.unexpectedResponse("Cluster setup update failed")
            }
        } catch let error as QdrantError {
            throw error
        } catch {
            throw QdrantError.from(error)
        }
    }
}

public struct CollectionClusterInfo: Sendable {

    public let peerId: UInt64

    public let shardCount: UInt64

    public let localShards: [LocalShardInfo]

    public let remoteShards: [RemoteShardInfo]

    public let shardTransfers: [ShardTransferInfo]

    internal init(grpc: Qdrant_CollectionClusterInfoResponse) {
        self.peerId = grpc.peerID
        self.shardCount = grpc.shardCount
        self.localShards = grpc.localShards.map { LocalShardInfo(grpc: $0) }
        self.remoteShards = grpc.remoteShards.map { RemoteShardInfo(grpc: $0) }
        self.shardTransfers = grpc.shardTransfers.map { ShardTransferInfo(grpc: $0) }
    }
}

public struct LocalShardInfo: Sendable {

    public let shardId: UInt32

    public let pointsCount: UInt64

    public let state: ReplicaState

    public let shardKey: ShardKey?

    internal init(grpc: Qdrant_LocalShardInfo) {
        self.shardId = grpc.shardID
        self.pointsCount = grpc.pointsCount
        self.state = ReplicaState(grpc: grpc.state)
        self.shardKey = grpc.hasShardKey ? ShardKey(grpc: grpc.shardKey) : nil
    }
}

public struct RemoteShardInfo: Sendable {

    public let shardId: UInt32

    public let peerId: UInt64

    public let state: ReplicaState

    public let shardKey: ShardKey?

    internal init(grpc: Qdrant_RemoteShardInfo) {
        self.shardId = grpc.shardID
        self.peerId = grpc.peerID
        self.state = ReplicaState(grpc: grpc.state)
        self.shardKey = grpc.hasShardKey ? ShardKey(grpc: grpc.shardKey) : nil
    }
}

public struct ShardTransferInfo: Sendable {

    public let shardId: UInt32

    public let from: UInt64

    public let to: UInt64

    public let sync: Bool

    internal init(grpc: Qdrant_ShardTransferInfo) {
        self.shardId = grpc.shardID
        self.from = grpc.from
        self.to = grpc.to
        self.sync = grpc.sync
    }
}

public enum ReplicaState: Sendable {
    case active
    case dead
    case partial
    case initializing
    case listener
    case partialSnapshot
    case recovery
    case resharding
    case unknown

    internal init(grpc: Qdrant_ReplicaState) {
        switch grpc {
        case .active: self = .active
        case .dead: self = .dead
        case .partial: self = .partial
        case .initializing: self = .initializing
        case .listener: self = .listener
        case .partialSnapshot: self = .partialSnapshot
        case .recovery: self = .recovery
        case .resharding: self = .resharding
        default: self = .unknown
        }
    }
}

public enum ShardKey: Sendable {

    case keyword(String)

    case number(UInt64)

    internal var grpc: Qdrant_ShardKey {
        var key = Qdrant_ShardKey()
        switch self {
        case .keyword(let s):
            key.keyword = s
        case .number(let n):
            key.number = n
        }
        return key
    }

    internal init(grpc: Qdrant_ShardKey) {
        switch grpc.key {
        case .keyword(let s):
            self = .keyword(s)
        case .number(let n):
            self = .number(n)
        case .none:
            self = .keyword("")
        }
    }
}

public enum ClusterOperation: Sendable {

    case moveShard(from: UInt64, to: UInt64, shardId: UInt32, method: ShardTransferMethod?)

    case replicateShard(from: UInt64, to: UInt64, shardId: UInt32, method: ShardTransferMethod?)

    case abortTransfer(from: UInt64, to: UInt64, shardId: UInt32)

    case dropReplica(peerId: UInt64, shardId: UInt32)

    case createShardKey(
        key: ShardKey, shardsNumber: UInt32?, replicationFactor: UInt32?, placement: [UInt64])

    case deleteShardKey(key: ShardKey)

    case restartTransfer(from: UInt64, to: UInt64, shardId: UInt32, method: ShardTransferMethod?)
}

public enum ShardTransferMethod: Sendable {

    case streamRecords

    case snapshot

    case walDelta

    case reshardingStreamRecords

    internal var grpc: Qdrant_ShardTransferMethod {
        switch self {
        case .streamRecords:
            return .streamRecords
        case .snapshot:
            return .snapshot
        case .walDelta:
            return .walDelta
        case .reshardingStreamRecords:
            return .reshardingStreamRecords
        }
    }
}

extension SparseVectorModifier {
    internal var grpc: Qdrant_Modifier {
        switch self {
        case .idf: return .idf
        }
    }
}
