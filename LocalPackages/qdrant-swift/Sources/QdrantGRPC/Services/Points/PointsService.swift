import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import QdrantCore
import QdrantProto

public final class PointsService: Sendable {
    private let base: PointsServiceBase
    private let crud: PointsCRUDService
    private let search: SearchService
    private let query: QueryService
    private let recommend: RecommendService
    private let discover: DiscoverService
    private let payload: PayloadService
    private let vector: VectorService
    private let index: IndexService
    private let batch: BatchService

    internal init(client: GRPCClient<HTTP2ClientTransport.Posix>, apiKey: String?) {
        self.base = PointsServiceBase(client: client, apiKey: apiKey)
        self.crud = PointsCRUDService(base: base)
        self.search = SearchService(base: base)
        self.query = QueryService(base: base)
        self.recommend = RecommendService(base: base)
        self.discover = DiscoverService(base: base)
        self.payload = PayloadService(base: base)
        self.vector = VectorService(base: base)
        self.index = IndexService(base: base)
        self.batch = BatchService(base: base)
    }

    public func upsert(
        collection: String,
        points: [Point],
        wait: Bool = true
    ) async throws {
        try await crud.upsert(collection: collection, points: points, wait: wait)
    }

    public func get(
        collection: String,
        ids: [PointID],
        withPayload: Bool = true,
        withVectors: Bool = false
    ) async throws -> [RetrievedPoint] {
        try await crud.get(
            collection: collection, ids: ids, withPayload: withPayload, withVectors: withVectors)
    }

    public func delete(
        collection: String,
        ids: [PointID],
        wait: Bool = true
    ) async throws {
        try await crud.delete(collection: collection, ids: ids, wait: wait)
    }

    public func delete(
        collection: String,
        filter: Filter,
        wait: Bool = true
    ) async throws {
        try await crud.delete(collection: collection, filter: filter, wait: wait)
    }

    public func scroll(
        collection: String,
        filter: Filter? = nil,
        limit: UInt32 = 10,
        offset: PointID? = nil,
        withPayload: Bool = true,
        withVectors: Bool = false
    ) async throws -> ScrollResult {
        try await crud.scroll(
            collection: collection, filter: filter, limit: limit, offset: offset,
            withPayload: withPayload, withVectors: withVectors)
    }

    public func count(
        collection: String,
        filter: Filter? = nil,
        exact: Bool = true
    ) async throws -> UInt64 {
        try await crud.count(collection: collection, filter: filter, exact: exact)
    }

    public func search(
        collection: String,
        vector: [Float],
        limit: UInt64 = 10,
        filter: Filter? = nil,
        scoreThreshold: Float? = nil,
        offset: UInt64? = nil,
        withPayload: Bool = true,
        withVectors: Bool = false,
        vectorName: String? = nil
    ) async throws -> [ScoredPoint] {
        try await search.search(
            collection: collection, vector: vector, limit: limit, filter: filter,
            scoreThreshold: scoreThreshold, offset: offset, withPayload: withPayload,
            withVectors: withVectors, vectorName: vectorName)
    }

    public func search(
        collection: String,
        vector: [Double],
        limit: UInt64 = 10,
        filter: Filter? = nil,
        scoreThreshold: Float? = nil,
        offset: UInt64? = nil,
        withPayload: Bool = true,
        withVectors: Bool = false,
        vectorName: String? = nil
    ) async throws -> [ScoredPoint] {
        try await search(
            collection: collection,
            vector: vector.map { Float($0) },
            limit: limit,
            filter: filter,
            scoreThreshold: scoreThreshold,
            offset: offset,
            withPayload: withPayload,
            withVectors: withVectors,
            vectorName: vectorName
        )
    }

    public func searchBatch(
        collection: String,
        searches: [SearchRequest]
    ) async throws -> [[ScoredPoint]] {
        try await search.searchBatch(collection: collection, searches: searches)
    }

    public func searchGroups(
        collection: String,
        vector: [Float],
        groupBy: String,
        limit: UInt32 = 10,
        groupSize: UInt32 = 3,
        filter: Filter? = nil,
        withPayload: Bool = true
    ) async throws -> [PointGroup] {
        try await search.searchGroups(
            collection: collection, vector: vector, groupBy: groupBy, limit: limit,
            groupSize: groupSize, filter: filter, withPayload: withPayload)
    }

    public func searchMatrixPairs(
        collection: String,
        filter: Filter? = nil,
        sample: UInt64 = 10,
        limit: UInt64 = 3,
        using: String? = nil
    ) async throws -> SearchMatrixPairsResult {
        try await search.searchMatrixPairs(
            collection: collection, filter: filter, sample: sample, limit: limit, using: using)
    }

    public func searchMatrixOffsets(
        collection: String,
        filter: Filter? = nil,
        sample: UInt64 = 10,
        limit: UInt64 = 3,
        using: String? = nil
    ) async throws -> SearchMatrixOffsetsResult {
        try await search.searchMatrixOffsets(
            collection: collection, filter: filter, sample: sample, limit: limit, using: using)
    }

    public func query(
        collection: String,
        query queryInput: QueryInput? = nil,
        prefetch: [PrefetchQuery] = [],
        using: String? = nil,
        filter: Filter? = nil,
        limit: UInt64 = 10,
        offset: UInt64? = nil,
        scoreThreshold: Float? = nil,
        withPayload: Bool = true,
        withVectors: Bool = false
    ) async throws -> [ScoredPoint] {
        try await self.query.query(
            collection: collection, query: queryInput, prefetch: prefetch, using: using,
            filter: filter, limit: limit, offset: offset, scoreThreshold: scoreThreshold,
            withPayload: withPayload, withVectors: withVectors)
    }

    public func queryBatch(
        collection: String,
        queries: [QueryRequest]
    ) async throws -> [[ScoredPoint]] {
        try await query.queryBatch(collection: collection, queries: queries)
    }

    public func queryGroups(
        collection: String,
        query queryInput: QueryInput? = nil,
        groupBy: String,
        limit: UInt64 = 10,
        groupSize: UInt64 = 3,
        prefetch: [PrefetchQuery] = [],
        using: String? = nil,
        filter: Filter? = nil,
        scoreThreshold: Float? = nil,
        withPayload: Bool = true
    ) async throws -> [PointGroup] {
        try await query.queryGroups(
            collection: collection, query: queryInput, groupBy: groupBy, limit: limit,
            groupSize: groupSize, prefetch: prefetch, using: using, filter: filter,
            scoreThreshold: scoreThreshold, withPayload: withPayload)
    }

    public func recommend(
        collection: String,
        positive: [PointID],
        negative: [PointID] = [],
        limit: UInt64 = 10,
        filter: Filter? = nil,
        scoreThreshold: Float? = nil,
        withPayload: Bool = true,
        withVectors: Bool = false
    ) async throws -> [ScoredPoint] {
        try await recommend.recommend(
            collection: collection, positive: positive, negative: negative, limit: limit,
            filter: filter, scoreThreshold: scoreThreshold, withPayload: withPayload,
            withVectors: withVectors)
    }

    public func recommendBatch(
        collection: String,
        requests: [RecommendRequest]
    ) async throws -> [[ScoredPoint]] {
        try await recommend.recommendBatch(collection: collection, requests: requests)
    }

    public func recommendGroups(
        collection: String,
        positive: [PointID],
        negative: [PointID] = [],
        groupBy: String,
        limit: UInt32 = 10,
        groupSize: UInt32 = 3,
        filter: Filter? = nil,
        scoreThreshold: Float? = nil,
        withPayload: Bool = true
    ) async throws -> [PointGroup] {
        try await recommend.recommendGroups(
            collection: collection, positive: positive, negative: negative, groupBy: groupBy,
            limit: limit, groupSize: groupSize, filter: filter, scoreThreshold: scoreThreshold,
            withPayload: withPayload)
    }

    public func discover(
        collection: String,
        target: DiscoverTarget,
        context: [ContextPair],
        limit: UInt64 = 10,
        filter: Filter? = nil,
        withPayload: Bool = true
    ) async throws -> [ScoredPoint] {
        try await discover.discover(
            collection: collection, target: target, context: context, limit: limit, filter: filter,
            withPayload: withPayload)
    }

    public func discoverBatch(
        collection: String,
        requests: [DiscoverRequest]
    ) async throws -> [[ScoredPoint]] {
        try await discover.discoverBatch(collection: collection, requests: requests)
    }

    public func setPayload(
        collection: String,
        ids: [PointID],
        payload: [String: PayloadValue],
        wait: Bool = true
    ) async throws {
        try await self.payload.setPayload(
            collection: collection, ids: ids, payload: payload, wait: wait)
    }

    public func overwritePayload(
        collection: String,
        ids: [PointID],
        payload: [String: PayloadValue],
        wait: Bool = true
    ) async throws {
        try await self.payload.overwritePayload(
            collection: collection, ids: ids, payload: payload, wait: wait)
    }

    public func deletePayload(
        collection: String,
        ids: [PointID],
        keys: [String],
        wait: Bool = true
    ) async throws {
        try await payload.deletePayload(collection: collection, ids: ids, keys: keys, wait: wait)
    }

    public func clearPayload(
        collection: String,
        ids: [PointID],
        wait: Bool = true
    ) async throws {
        try await payload.clearPayload(collection: collection, ids: ids, wait: wait)
    }

    public func updateVectors(
        collection: String,
        points: [(id: PointID, vector: VectorData)],
        wait: Bool = true
    ) async throws {
        try await vector.updateVectors(collection: collection, points: points, wait: wait)
    }

    public func deleteVectors(
        collection: String,
        ids: [PointID],
        vectorNames: [String],
        wait: Bool = true
    ) async throws {
        try await vector.deleteVectors(
            collection: collection, ids: ids, vectorNames: vectorNames, wait: wait)
    }

    public func createFieldIndex(
        collection: String,
        fieldName: String,
        fieldType: FieldType,
        wait: Bool = true,
        isTenant: Bool = false
    ) async throws {
        try await index.createFieldIndex(
            collection: collection,
            fieldName: fieldName,
            fieldType: fieldType,
            wait: wait,
            isTenant: isTenant
        )
    }

    public func deleteFieldIndex(
        collection: String,
        fieldName: String,
        wait: Bool = true
    ) async throws {
        try await index.deleteFieldIndex(collection: collection, fieldName: fieldName, wait: wait)
    }

    public func facet(
        collection: String,
        key: String,
        filter: Filter? = nil,
        limit: UInt64 = 10,
        exact: Bool = false
    ) async throws -> FacetResult {
        try await index.facet(
            collection: collection, key: key, filter: filter, limit: limit, exact: exact)
    }

    public func updateBatch(
        collection: String,
        operations: [PointsUpdateOperation],
        wait: Bool = true
    ) async throws -> BatchUpdateResult {
        try await batch.updateBatch(collection: collection, operations: operations, wait: wait)
    }
}
