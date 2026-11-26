import NIOSSL
import PostgresNIO

public struct PostgresNIODatabase: SQLExecuting {
    public var target: PostgresConnectionTarget

    public init(target: PostgresConnectionTarget) {
        self.target = target
    }

    public init(url: String) throws {
        self.target = try PostgresURL.parse(url)
    }

    public func execute(_ statement: SQLStatement) async throws -> [SQLRow] {
        let client = PostgresClient(configuration: Self.configuration(for: target))
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await client.run()
            }
            defer { group.cancelAll() }
            var rows: [SQLRow] = []
            let result = try await client.query(Self.query(statement))
            for try await row in result {
                rows.append(try Self.row(row))
            }
            return rows
        }
    }

    public static func configuration(for target: PostgresConnectionTarget) -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        if target.tls {
            tls = .require(.makeClientConfiguration())
        } else {
            tls = .disable
        }
        let username = target.username.isEmpty ? "postgres" : target.username
        return PostgresClient.Configuration(
            host: target.host,
            port: target.port,
            username: username,
            password: target.password.isEmpty ? nil : target.password,
            database: target.database,
            tls: tls
        )
    }

    static func query(_ statement: SQLStatement) throws -> PostgresQuery {
        var binds = PostgresBindings(capacity: statement.parameters.count)
        for parameter in statement.parameters {
            switch parameter {
            case .text(let value):
                binds.append(value)
            case .integer(let value):
                binds.append(value)
            case .double(let value):
                binds.append(value)
            case .boolean(let value):
                binds.append(value)
            case .null:
                binds.appendNull()
            }
        }
        return PostgresQuery(unsafeSQL: statement.sql, binds: binds)
    }

    static func row(_ row: PostgresRow) throws -> SQLRow {
        var columns: [String: SQLValue] = [:]
        for cell in row {
            columns[cell.columnName] = try value(cell)
        }
        return SQLRow(columns: columns)
    }

    static func value(_ cell: PostgresCell) throws -> SQLValue {
        guard cell.bytes != nil else { return .null }
        switch cell.dataType {
        case .int2, .int4, .int8:
            return .integer(try cell.decode(Int.self))
        case .float4, .float8, .numeric:
            return .double(try cell.decode(Double.self))
        case .bool:
            return .boolean(try cell.decode(Bool.self))
        default:
            return .text(try cell.decode(String.self))
        }
    }
}
