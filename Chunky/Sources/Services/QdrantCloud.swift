import Foundation

struct CloudOverview: Equatable, Sendable {
    var name: String
    var phase: String
    var version: String
    var nodesUp: Int?
    var ram: String
    var disk: String
    var cpu: String
    var alerts: [String]
    var events: Int
    var logs: Int
    var usagePoints: Int
    var inferenceTokens: Double?
    var keyWarning: String?

    var canUnsuspend: Bool {
        phase == "SUSPENDED" || phase == "FAILED_TO_RESUME"
    }
}

enum QdrantCloudJSON {
    static func value(_ object: [String: Any], _ snake: String) -> Any? {
        if let found = object[snake] { return found }
        let camel = snake.split(separator: "_").enumerated().map { index, part in
            index == 0 ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
        return object[camel]
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func rows(_ object: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let rows = value(object, key) as? [[String: Any]] { return rows }
            if let rows = value(object, key) as? [Any] {
                return rows.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    static func date(_ value: Any?) -> Date? {
        if value is NSNull { return nil }
        guard let text = text(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum DatabaseKeyExpiry {
    static let defaultDays = 90
    static let warnWithin: TimeInterval = 7 * 24 * 60 * 60

    static func warning(created: Date?, expires: Date?, expiresWasNull: Bool, now: Date) -> String? {
        let deadline: Date?
        if expiresWasNull {
            deadline = nil
        } else if let expires {
            deadline = expires
        } else if let created {
            deadline = created.addingTimeInterval(Double(defaultDays) * 24 * 60 * 60)
        } else {
            deadline = nil
        }
        guard let deadline else { return nil }
        if deadline <= now {
            return "A database API key has expired. Create a new key before requests start failing."
        }
        if deadline.timeIntervalSince(now) <= warnWithin {
            return "A database API key expires within 7 days. The default lifetime is 90 days."
        }
        return nil
    }
}

enum CloudClusterParser {
    static func phase(_ raw: String) -> String {
        raw.replacingOccurrences(of: "CLUSTER_PHASE_", with: "")
    }

    static func overview(cluster data: Data, keys dataKeys: Data, alerts alertData: Data, summary summaryData: Data, usage usageData: Data, logs logData: Data, events eventData: Data, inference inferenceData: Data, now: Date) -> CloudOverview? {
        guard let root = json(data) else { return nil }
        let cluster = QdrantCloudJSON.object(QdrantCloudJSON.value(root, "cluster")) ?? root
        let state = QdrantCloudJSON.object(QdrantCloudJSON.value(cluster, "state")) ?? [:]
        let resources = QdrantCloudJSON.object(QdrantCloudJSON.value(state, "resources")) ?? [:]
        let phase = phase(QdrantCloudJSON.text(QdrantCloudJSON.value(state, "phase")) ?? "UNKNOWN")
        let keyWarning = keyWarning(from: dataKeys, now: now)
        return CloudOverview(
            name: QdrantCloudJSON.text(QdrantCloudJSON.value(cluster, "name")) ?? "",
            phase: phase,
            version: QdrantCloudJSON.text(QdrantCloudJSON.value(state, "version")) ?? "",
            nodesUp: (QdrantCloudJSON.value(state, "nodes_up") as? NSNumber)?.intValue,
            ram: resource(resources, "ram"),
            disk: resource(resources, "disk"),
            cpu: resource(resources, "cpu"),
            alerts: firingAlerts(alertData),
            events: count(eventData, keys: ["events", "items"]),
            logs: count(logData, keys: ["logs", "items"]),
            usagePoints: count(usageData, keys: ["values", "items", "points"]),
            inferenceTokens: inferenceTokens(inferenceData),
            keyWarning: keyWarning
        )
    }

    static func keyWarning(from data: Data, now: Date) -> String? {
        guard let root = json(data) else { return nil }
        let rows = QdrantCloudJSON.rows(root, keys: ["items", "database_api_keys"])
        for row in rows {
            let created = QdrantCloudJSON.date(QdrantCloudJSON.value(row, "created_at"))
            let expiresValue = QdrantCloudJSON.value(row, "expires_at")
            let expiresWasNull = expiresValue is NSNull
            let expires = QdrantCloudJSON.date(expiresValue)
            if let warning = DatabaseKeyExpiry.warning(created: created, expires: expires, expiresWasNull: expiresWasNull, now: now) {
                return warning
            }
        }
        return nil
    }

    private static func firingAlerts(_ data: Data) -> [String] {
        guard let root = json(data) else { return [] }
        return QdrantCloudJSON.rows(root, keys: ["items", "alerts"]).compactMap { row in
            let state = (QdrantCloudJSON.text(QdrantCloudJSON.value(row, "state")) ?? "").uppercased()
            guard state.isEmpty || state.contains("FIRING") || state.contains("ACTIVE") else { return nil }
            return QdrantCloudJSON.text(QdrantCloudJSON.value(row, "name"))
                ?? QdrantCloudJSON.text(QdrantCloudJSON.value(row, "title"))
        }
    }

    private static func resource(_ resources: [String: Any], _ name: String) -> String {
        guard let node = QdrantCloudJSON.object(QdrantCloudJSON.value(resources, name)),
              let available = QdrantCloudJSON.number(QdrantCloudJSON.value(node, "available"))
        else { return "" }
        return String(format: "%.1f", available)
    }

    private static func count(_ data: Data, keys: [String]) -> Int {
        guard let root = json(data) else { return 0 }
        return QdrantCloudJSON.rows(root, keys: keys).count
    }

    private static func inferenceTokens(_ data: Data) -> Double? {
        guard let root = json(data) else { return nil }
        if let tokens = QdrantCloudJSON.number(QdrantCloudJSON.value(root, "tokens")) { return tokens }
        if let total = QdrantCloudJSON.number(QdrantCloudJSON.value(root, "total")) { return total }
        let nested = QdrantCloudJSON.object(QdrantCloudJSON.value(root, "inference")) ?? root
        return QdrantCloudJSON.number(QdrantCloudJSON.value(nested, "tokens"))
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum QdrantKeepAlive {
    static let interval: TimeInterval = 24 * 60 * 60

    static func shouldPing(enabled: Bool, last: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    static func collectionsURL(baseURL: String) throws -> URL {
        guard var url = CollectionSnapshots.restBase(qdrantURL: baseURL) else {
            throw QdrantHealthError.invalidURL(baseURL)
        }
        url.appendPathComponent("collections")
        return url
    }
}

protocol CloudManagementTransport: Sendable {
    func send(method: String, url: URL, managementKey: String) async throws -> (status: Int, body: Data)
}

struct CloudManagementClient: Sendable {
    static let base = URL(string: "https://api.cloud.qdrant.io")!
    var transport: any CloudManagementTransport

    func load(accountID: String, clusterID: String, managementKey: String, now: Date) async throws -> CloudOverview {
        let cluster = try await get(path: "api/cluster/v1/accounts/\(accountID)/clusters/\(clusterID)", key: managementKey)
        let keys = try await get(path: "api/cluster/auth/v2/accounts/\(accountID)/database-api-keys", key: managementKey, query: "cluster_id=\(clusterID)")
        let alerts = try await get(path: "api/cluster/v1/accounts/\(accountID)/clusters/\(clusterID)/alerts", key: managementKey)
        let summary = try await get(path: "api/monitoring/v1/accounts/\(accountID)/cluster/\(clusterID)/summary-metrics", key: managementKey)
        let usage = try await get(path: "api/monitoring/v1/accounts/\(accountID)/cluster/\(clusterID)/usage-metrics", key: managementKey)
        let logs = try await get(path: "api/monitoring/v1/accounts/\(accountID)/cluster/\(clusterID)/logs", key: managementKey)
        let events = try await get(path: "api/monitoring/v1/accounts/\(accountID)/cluster/\(clusterID)/events", key: managementKey)
        let inference = try await get(path: "api/monitoring/v1/accounts/\(accountID)/cluster/\(clusterID)/metrics/inference", key: managementKey)
        guard let overview = CloudClusterParser.overview(
            cluster: cluster,
            keys: keys,
            alerts: alerts,
            summary: summary,
            usage: usage,
            logs: logs,
            events: events,
            inference: inference,
            now: now
        ) else {
            throw QdrantHealthError.http(200)
        }
        return overview
    }

    func unsuspend(accountID: String, clusterID: String, managementKey: String) async throws {
        let url = try Self.url("api/cluster/v1/accounts/\(accountID)/clusters/\(clusterID)/unsuspend")
        let response = try await transport.send(method: "POST", url: url, managementKey: managementKey)
        guard (200..<300).contains(response.status) else {
            throw QdrantHealthError.http(response.status)
        }
    }

    static func authorization(_ managementKey: String) -> String {
        "apikey \(managementKey)"
    }

    private func get(path: String, key: String, query: String = "") async throws -> Data {
        var url = try Self.url(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
            url = components.url ?? url
        }
        let response = try await transport.send(method: "GET", url: url, managementKey: key)
        guard (200..<300).contains(response.status) else {
            throw QdrantHealthError.http(response.status)
        }
        return response.body
    }

    static func url(_ path: String) throws -> URL {
        var url = base
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }
}

struct LiveCloudManagementTransport: CloudManagementTransport {
    func send(method: String, url: URL, managementKey: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !managementKey.isEmpty {
            request.setValue(CloudManagementClient.authorization(managementKey), forHTTPHeaderField: "Authorization")
        }
        if method == "POST" {
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum QdrantKeepAliveLoop {
    static func tick(settings: AppSettings, now: Date, ping: () async -> Bool) async {
        guard QdrantKeepAlive.shouldPing(enabled: settings.qdrantKeepAlive, last: settings.qdrantLastSuccessAt, now: now) else {
            return
        }
        if await ping() {
            settings.noteQdrantSuccess(at: now)
        }
    }
}
