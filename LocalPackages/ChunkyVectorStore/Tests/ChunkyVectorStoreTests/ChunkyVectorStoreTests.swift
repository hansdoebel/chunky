import XCTest
@testable import ChunkyVectorStore

final class ScriptedSQL: SQLExecuting, @unchecked Sendable {
    var statements: [SQLStatement] = []
    var meta: [SQLRow] = []
    var hits: [SQLRow] = []

    func execute(_ statement: SQLStatement) async throws -> [SQLRow] {
        statements.append(statement)
        let sql = statement.sql.lowercased()
        if sql.contains("from \(PgIdentifiers.meta.lowercased()) where") || sql.contains("where collection") {
            return meta
        }
        if sql.contains(" as score") {
            return hits
        }
        if sql.hasPrefix("select collection") {
            return meta
        }
        return []
    }
}

final class ChunkyVectorStoreTests: XCTestCase {
    func testMissingKindStaysOnQdrantAndDoesNotAddWorkerFields() {
        XCTAssertEqual(VectorStoreKind.resolved(stored: nil), .qdrant)
        XCTAssertEqual(VectorStoreKind.resolved(stored: "nope"), .qdrant)
        XCTAssertEqual(VectorStoreKind.resolved(stored: "PGVECTOR"), .pgvector)
        XCTAssertTrue(WorkerStoreRequest.fields(kind: .qdrant, url: "http://qdrant", apiKey: "secret").isEmpty)
        XCTAssertEqual(
            WorkerStoreRequest.fields(kind: .weaviate, url: "https://weaviate.example", apiKey: "token"),
            ["vector_store": "weaviate", "vector_store_url": "https://weaviate.example", "vector_store_api_key": "token"]
        )
        XCTAssertEqual(VectorStoreKeychain.qdrantURL, "qdrant_url")
        XCTAssertEqual(VectorStoreKeychain.qdrantAPIKey, "qdrant_api_key")
    }

    func testRoutingAndCapabilities() {
        XCTAssertEqual(StoreRouting.route(kind: .qdrant, devbox: false), .qdrant)
        XCTAssertEqual(StoreRouting.route(kind: .pgvector, devbox: false), .pgvector)
        XCTAssertEqual(StoreRouting.route(kind: .pgvector, devbox: true), .worker(.pgvector))
        XCTAssertEqual(StoreRouting.route(kind: .chroma, devbox: false), .needsWorker(.chroma))
        XCTAssertEqual(StoreRouting.route(kind: .milvus, devbox: true), .worker(.milvus))
        let pg = StoreCapabilities.of(.pgvector)
        XCTAssertTrue(pg.hybrid)
        XCTAssertTrue(pg.directFromMac)
        XCTAssertFalse(pg.snapshots)
        XCTAssertFalse(pg.localRuntime)
        XCTAssertFalse(pg.papersFirst)
        XCTAssertFalse(pg.tenantIndex)
        XCTAssertFalse(StoreCapabilities.of(.chroma).hybrid)
        XCTAssertTrue(StoreCapabilities.of(.qdrant).snapshots)
    }

    func testPostgresURLHidesThePasswordAndHTTPRejectsCredentials() throws {
        let target = try PostgresURL.parse("postgresql://chunky:s3cret@127.0.0.1:5432/chunks?sslmode=require")
        XCTAssertEqual(target.host, "127.0.0.1")
        XCTAssertEqual(target.port, 5432)
        XCTAssertEqual(target.username, "chunky")
        XCTAssertEqual(target.password, "s3cret")
        XCTAssertEqual(target.database, "chunks")
        XCTAssertTrue(target.tls)
        XCTAssertFalse(target.redacted.contains("s3cret"))
        XCTAssertThrowsError(try PostgresURL.parse("postgresql://db.internal/chunks#secret"))
        XCTAssertThrowsError(try PostgresURL.validateHTTP("https://user:pass@weaviate.example"))
        XCTAssertEqual(try PostgresURL.validateHTTP("https://weaviate.example/v1"), "https://weaviate.example/v1")
    }

    func testEnsureUpsertSearchDelete() async throws {
        let sql = ScriptedSQL()
        let store = PgVectorStore(database: sql, distance: "cosine")
        let payload = JSONValue.object([
            "text": .string("Hello"),
            "year": .int(2024),
            "headings": .array([.string("Intro")]),
        ])
        let written = try await store.upsert(
            collection: "documents",
            points: [VectorRecord(id: "a", vector: [0.1, 0.2, 0.3], payload: payload)],
            vectorSize: 3,
            batchSize: 10
        )
        XCTAssertEqual(written, 1)
        let joined = sql.statements.map(\.sql).joined(separator: "\n")
        XCTAssertTrue(joined.contains("CREATE EXTENSION IF NOT EXISTS vector"))
        XCTAssertTrue(joined.contains("embedding vector(3)"))
        XCTAssertTrue(joined.contains("vector_cosine_ops"))
        XCTAssertTrue(joined.contains("ON CONFLICT (id) DO UPDATE"))
        XCTAssertEqual(payload.encoded(), "{\"headings\":[\"Intro\"],\"text\":\"Hello\",\"year\":2024}")

        sql.meta = [SQLRow(columns: ["dimensions": .integer(3), "distance": .text("cosine"), "collection": .text("documents")])]
        sql.hits = [SQLRow(columns: [
            "id": .text("a"),
            "payload": .text(payload.encoded()),
            "score": .double(0.75),
        ])]
        let hits = try await store.search(
            collection: "documents",
            vector: [0.1, 0.2, 0.3],
            text: "Hello",
            mode: "dense",
            limit: 5,
            offset: 0,
            filters: [VectorFilter(key: "year", match: .int(2024))],
            scoreThreshold: 0.5,
            weights: nil
        )
        XCTAssertEqual(hits.first?.id, "a")
        XCTAssertEqual(hits.first?.payload, payload)
        let query = sql.statements.last
        XCTAssertTrue(query?.sql.contains("<=>") == true)
        XCTAssertTrue(query?.sql.contains("payload @>") == true)
        XCTAssertTrue(query?.parameters.contains(.text("{\"year\":2024}")) == true)

        sql.hits = [
            SQLRow(columns: ["id": .text("b"), "payload": .text("{\"text\":\"b\"}"), "score": .double(0.9)]),
            SQLRow(columns: ["id": .text("a"), "payload": .text("{\"text\":\"a\"}"), "score": .double(0.2)]),
        ]
        let hybrid = try await store.search(
            collection: "documents",
            vector: [0.1, 0.2, 0.3],
            text: "b",
            mode: "hybrid",
            limit: 1,
            offset: 0,
            filters: [],
            scoreThreshold: nil,
            weights: [1, 1]
        )
        XCTAssertEqual(hybrid.first?.id, "b")
        XCTAssertTrue(sql.statements.contains { $0.sql.contains("plainto_tsquery") })

        try await store.deletePoints(collection: "documents", ids: ["a"])
        try await store.deleteSource(collection: "documents", source: "paper.pdf", libraryID: "default")
        try await store.deleteCollection("documents")
        XCTAssertTrue(sql.statements.contains { $0.sql.contains("DROP TABLE IF EXISTS") })
        XCTAssertTrue(sql.statements.contains { $0.sql.contains("payload->>'source'") })
        XCTAssertThrowsError(try PgIdentifiers.table("has space"))
    }

    func testPostgresNIOConfigurationKeepsTheParsedTarget() throws {
        let target = try PostgresURL.parse("postgresql://chunky:s3cret@db.internal:5433/chunks")
        let configuration = PostgresNIODatabase.configuration(for: target)
        XCTAssertEqual(configuration.host, "db.internal")
        XCTAssertEqual(configuration.port, 5433)
        XCTAssertEqual(configuration.username, "chunky")
        XCTAssertEqual(configuration.password, "s3cret")
        XCTAssertEqual(configuration.database, "chunks")
        let plain = try PostgresURL.parse("postgresql://127.0.0.1/chunks")
        XCTAssertEqual(PostgresNIODatabase.configuration(for: plain).username, "postgres")
        XCTAssertNil(PostgresNIODatabase.configuration(for: plain).password)
    }

    func testDimensionMismatchAndDotDistance() async throws {
        let sql = ScriptedSQL()
        sql.meta = [SQLRow(columns: ["dimensions": .integer(4), "distance": .text("cosine")])]
        let store = PgVectorStore(database: sql, distance: "cosine")
        do {
            try await store.ensureCollection(name: "documents", vectorSize: 3, distance: "cosine")
            XCTFail("expected a dimension mismatch")
        } catch VectorStoreFailure.dimensionMismatch(let collection, let existing, let actual) {
            XCTAssertEqual(collection, "documents")
            XCTAssertEqual(existing, 4)
            XCTAssertEqual(actual, 3)
        }
        let dot = try PgSQL.metric("dot")
        XCTAssertTrue(dot.score.contains("<#>"))
        let clause = try PgSQL.filter([
            VectorFilter(key: "doi", match: .text("10.1/x"), negated: true),
            VectorFilter(key: "source", match: .contains("paper"), should: true),
        ])
        XCTAssertTrue(clause.0.contains("NOT"))
        XCTAssertTrue(clause.0.contains("ILIKE"))
    }
}
