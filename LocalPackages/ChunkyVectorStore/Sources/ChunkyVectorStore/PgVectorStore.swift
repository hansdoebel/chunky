public struct PgVectorStore: Sendable {
    public var database: any SQLExecuting
    public var distance: String

    public init(database: any SQLExecuting, distance: String = "cosine") {
        self.database = database
        self.distance = distance
    }

    public func listCollections() async throws -> [String] {
        let rows = try await database.execute(SQLStatement(
            sql: "SELECT collection FROM \(PgIdentifiers.meta) ORDER BY collection"
        ))
        return rows.compactMap { $0.text("collection") }
    }

    public func deleteCollection(_ name: String) async throws {
        let table = try PgIdentifiers.table(name)
        _ = try await database.execute(SQLStatement(sql: "DROP TABLE IF EXISTS \(table)"))
        _ = try await database.execute(numbered(
            "DELETE FROM \(PgIdentifiers.meta) WHERE collection = $@",
            parameters: [.text(try PgIdentifiers.collection(name))]
        ))
    }

    public func deletePoints(collection: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let table = try PgIdentifiers.table(collection)
        let slots = ids.map { _ in "$@" }.joined(separator: ", ")
        _ = try await database.execute(numbered(
            "DELETE FROM \(table) WHERE id IN (\(slots))",
            parameters: ids.map { .text($0) }
        ))
    }

    public func deleteSource(collection: String, source: String, libraryID: String?) async throws {
        let table = try PgIdentifiers.table(collection)
        if let libraryID, !libraryID.isEmpty {
            _ = try await database.execute(numbered(
                "DELETE FROM \(table) WHERE payload->>'source' = $@ AND payload->>'library_id' = $@",
                parameters: [.text(source), .text(libraryID)]
            ))
        } else {
            _ = try await database.execute(numbered(
                "DELETE FROM \(table) WHERE payload->>'source' = $@",
                parameters: [.text(source)]
            ))
        }
    }

    public func ensureCollection(name: String, vectorSize: Int, distance: String) async throws {
        guard vectorSize > 0 else { throw VectorStoreFailure.invalidVector }
        let table = try PgIdentifiers.table(name)
        let collection = try PgIdentifiers.collection(name)
        let index = try PgIdentifiers.index(name)
        let ops = try indexOps(distance)
        _ = try await database.execute(SQLStatement(sql: "CREATE EXTENSION IF NOT EXISTS vector"))
        _ = try await database.execute(SQLStatement(
            sql: "CREATE TABLE IF NOT EXISTS \(PgIdentifiers.meta) (collection text PRIMARY KEY, dimensions integer NOT NULL, distance text NOT NULL)"
        ))
        let existing = try await database.execute(numbered(
            "SELECT dimensions, distance FROM \(PgIdentifiers.meta) WHERE collection = $@",
            parameters: [.text(collection)]
        ))
        if let row = existing.first {
            let found = row.integer("dimensions") ?? -1
            let stored = row.text("distance") ?? ""
            if found != vectorSize {
                throw VectorStoreFailure.dimensionMismatch(collection: collection, existing: found, actual: vectorSize)
            }
            if stored != distance {
                throw VectorStoreFailure.distanceMismatch(collection: collection, existing: stored)
            }
            return
        }
        _ = try await database.execute(SQLStatement(
            sql: "CREATE TABLE IF NOT EXISTS \(table) (id text PRIMARY KEY, embedding vector(\(vectorSize)) NOT NULL, payload jsonb NOT NULL)"
        ))
        _ = try await database.execute(SQLStatement(
            sql: "CREATE INDEX IF NOT EXISTS \(index) ON \(table) USING hnsw (embedding \(ops))"
        ))
        _ = try await database.execute(numbered(
            "INSERT INTO \(PgIdentifiers.meta) (collection, dimensions, distance) VALUES ($@, $@, $@) ON CONFLICT (collection) DO NOTHING",
            parameters: [.text(collection), .integer(vectorSize), .text(distance)]
        ))
    }

    public func upsert(collection: String, points: [VectorRecord], vectorSize: Int, batchSize: Int) async throws -> Int {
        guard batchSize > 0 else { throw VectorStoreFailure.unsupported("batch size must be at least 1") }
        try await ensureCollection(name: collection, vectorSize: vectorSize, distance: distance)
        let table = try PgIdentifiers.table(collection)
        var written = 0
        var start = 0
        while start < points.count {
            let end = min(start + batchSize, points.count)
            let batch = Array(points[start..<end])
            var parameters: [SQLValue] = []
            var tuples: [String] = []
            for point in batch {
                guard point.vector.count == vectorSize else { throw VectorStoreFailure.invalidVector }
                tuples.append("($@, $@::vector, $@::jsonb)")
                parameters.append(.text(point.id))
                parameters.append(.text(try PgSQL.vectorText(point.vector)))
                parameters.append(.text(point.payload.encoded()))
            }
            _ = try await database.execute(numbered(
                "INSERT INTO \(table) (id, embedding, payload) VALUES \(tuples.joined(separator: ",")) ON CONFLICT (id) DO UPDATE SET embedding = EXCLUDED.embedding, payload = EXCLUDED.payload",
                parameters: parameters
            ))
            written += batch.count
            start = end
        }
        return written
    }

    public func search(
        collection: String,
        vector: [Double],
        text: String,
        mode: String,
        limit: Int,
        offset: Int,
        filters: [VectorFilter],
        scoreThreshold: Double?,
        weights: [Double]?
    ) async throws -> [VectorHit] {
        let stored = try await describe(collection)
        guard let stored else { throw VectorStoreFailure.notFound(collection) }
        guard stored.vectorSize == vector.count else {
            throw VectorStoreFailure.dimensionMismatch(collection: collection, existing: stored.vectorSize, actual: vector.count)
        }
        if mode == "hybrid" {
            let window = max(limit + max(offset, 0), 1)
            let dense = try await dense(collection: collection, vector: vector, distance: stored.distance, filters: filters, limit: window, offset: 0)
            let lexical = try await lexical(collection: collection, text: text, filters: filters, limit: window)
            return applyThreshold(fuse(dense, lexical, weights: weights, limit: limit, offset: offset), scoreThreshold)
        }
        guard mode == "dense" else { throw VectorStoreFailure.unsupported("mode must be dense or hybrid") }
        return applyThreshold(try await dense(collection: collection, vector: vector, distance: stored.distance, filters: filters, limit: limit, offset: offset), scoreThreshold)
    }

    public func describe(_ collection: String) async throws -> (vectorSize: Int, distance: String)? {
        let rows = try await database.execute(numbered(
            "SELECT dimensions, distance FROM \(PgIdentifiers.meta) WHERE collection = $@",
            parameters: [.text(try PgIdentifiers.collection(collection))]
        ))
        guard let row = rows.first, let size = row.integer("dimensions"), let distance = row.text("distance") else { return nil }
        return (size, distance)
    }

    private func dense(collection: String, vector: [Double], distance: String, filters: [VectorFilter], limit: Int, offset: Int) async throws -> [VectorHit] {
        let table = try PgIdentifiers.table(collection)
        let metric = try PgSQL.metric(distance)
        let clause = try PgSQL.filter(filters)
        let whereSQL = clause.0.isEmpty ? "" : " WHERE \(clause.0)"
        let literal = try PgSQL.vectorText(vector)
        var parameters: [SQLValue] = [.text(literal)]
        parameters.append(contentsOf: clause.1)
        parameters.append(.text(literal))
        parameters.append(.integer(limit))
        parameters.append(.integer(offset))
        let rows = try await database.execute(numbered(
            "SELECT id, payload::text AS payload, \(metric.score) AS score FROM \(table)\(whereSQL) ORDER BY \(metric.order) LIMIT $@ OFFSET $@",
            parameters: parameters
        ))
        return rows.compactMap(hit)
    }

    private func lexical(collection: String, text: String, filters: [VectorFilter], limit: Int) async throws -> [VectorHit] {
        let table = try PgIdentifiers.table(collection)
        let document = "to_tsvector('simple', coalesce(payload->>'text','') || ' ' || coalesce(payload->>'embedding_text',''))"
        let clause = try PgSQL.filter(filters)
        let extra = clause.0.isEmpty ? "" : " AND \(clause.0)"
        var parameters: [SQLValue] = [.text(text), .text(text)]
        parameters.append(contentsOf: clause.1)
        parameters.append(.integer(limit))
        let rows = try await database.execute(numbered(
            "SELECT id, payload::text AS payload, ts_rank_cd(\(document), plainto_tsquery('simple', $@)) AS score FROM \(table) WHERE \(document) @@ plainto_tsquery('simple', $@)\(extra) ORDER BY score DESC LIMIT $@",
            parameters: parameters
        ))
        return rows.compactMap(hit)
    }

    private func hit(_ row: SQLRow) -> VectorHit? {
        guard let id = row.text("id"), let score = row.double("score") else { return nil }
        let payload = row.text("payload").flatMap(JSONValue.parse) ?? .object([:])
        return VectorHit(id: id, score: score, payload: payload)
    }
}

private func indexOps(_ distance: String) throws -> String {
    switch distance {
    case "cosine": return "vector_cosine_ops"
    case "euclid": return "vector_l2_ops"
    case "dot": return "vector_ip_ops"
    default: throw VectorStoreFailure.unsupported("Unsupported distance: \(distance)")
    }
}

func fuse(_ left: [VectorHit], _ right: [VectorHit], weights: [Double]?, limit: Int, offset: Int) -> [VectorHit] {
    let denseWeight = weights?.first ?? 1
    let lexicalWeight = weights?.dropFirst().first ?? 1
    var scores: [String: Double] = [:]
    var payloads: [String: JSONValue] = [:]
    for (rank, hit) in left.enumerated() {
        scores[hit.id, default: 0] += denseWeight / (60 + Double(rank + 1))
        payloads[hit.id] = hit.payload
    }
    for (rank, hit) in right.enumerated() {
        scores[hit.id, default: 0] += lexicalWeight / (60 + Double(rank + 1))
        if payloads[hit.id] == nil { payloads[hit.id] = hit.payload }
    }
    let ordered = scores.keys.sorted { lhs, rhs in
        let leftScore = scores[lhs] ?? 0
        let rightScore = scores[rhs] ?? 0
        if leftScore == rightScore { return lhs < rhs }
        return leftScore > rightScore
    }
    return ordered.dropFirst(offset).prefix(limit).map { id in
        VectorHit(id: id, score: scores[id] ?? 0, payload: payloads[id] ?? .object([:]))
    }
}

func applyThreshold(_ hits: [VectorHit], _ threshold: Double?) -> [VectorHit] {
    guard let threshold else { return hits }
    return hits.filter { $0.score >= threshold }
}
