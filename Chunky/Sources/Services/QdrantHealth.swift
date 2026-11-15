import Foundation

struct PrometheusSample: Equatable, Sendable {
    var name: String
    var labels: [String: String]
    var value: Double
}

enum PrometheusText {
    static func samples(in text: String) -> [PrometheusSample] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return sample(String(trimmed))
        }
    }

    static func total(
        _ samples: [PrometheusSample],
        _ name: String,
        label: String? = nil,
        equals: String? = nil
    ) -> Double? {
        let matched = samples.filter { sample in
            guard sample.name == name else { return false }
            if let label, let equals {
                return sample.labels[label] == equals
            }
            return true
        }
        guard !matched.isEmpty else { return nil }
        return matched.reduce(0) { $0 + $1.value }
    }

    private static func sample(_ line: String) -> PrometheusSample? {
        let nameEnd = line.firstIndex(where: { $0 == "{" || $0 == " " }) ?? line.endIndex
        let name = String(line[..<nameEnd])
        guard !name.isEmpty else { return nil }
        var rest = line[nameEnd...]
        var labels: [String: String] = [:]
        if rest.first == "{" {
            guard let close = rest.firstIndex(of: "}") else { return nil }
            labels = parseLabels(String(rest[rest.index(after: rest.startIndex)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        let valueToken = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let value = Double(valueToken) else { return nil }
        return PrometheusSample(name: name, labels: labels, value: value)
    }

    private static func parseLabels(_ text: String) -> [String: String] {
        var labels: [String: String] = [:]
        var rest = text[...]
        while let equal = rest.firstIndex(of: "=") {
            let key = rest[..<equal].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ","))
            rest = rest[rest.index(after: equal)...]
            guard rest.first == "\"" else { break }
            rest = rest.dropFirst()
            var value = ""
            var escaped = false
            var consumed = 0
            for character in rest {
                consumed += 1
                if escaped {
                    value.append(character)
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if character == "\"" {
                    break
                }
                value.append(character)
            }
            if !key.isEmpty {
                labels[key] = value
            }
            rest = rest.dropFirst(consumed)
        }
        return labels
    }
}

struct MemoryComponent: Equatable, Identifiable, Sendable {
    var name: String
    var disk: Double
    var ram: Double
    var cached: Double

    var id: String { name }
}

enum CollectionMemory {
    static let order = ["Vectors", "HNSW", "Quantization", "Payload", "Payload indexes", "ID tracker"]

    static func components(from data: Data) -> [MemoryComponent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let result = (object["result"] as? [String: Any]) ?? object
        var totals: [String: (disk: Double, ram: Double, cached: Double)] = [:]
        walk(result, path: [], into: &totals)
        return order.compactMap { name in
            guard let row = totals[name], row.disk > 0 || row.ram > 0 || row.cached > 0 else { return nil }
            return MemoryComponent(name: name, disk: row.disk, ram: row.ram, cached: row.cached)
        }
    }

    private static func walk(_ value: Any, path: [String], into totals: inout [String: (disk: Double, ram: Double, cached: Double)]) {
        guard let object = value as? [String: Any] else { return }
        if object["disk_bytes"] != nil || object["ram_bytes"] != nil || object["cached_bytes"] != nil {
            let name = bucket(path)
            let current = totals[name] ?? (0, 0, 0)
            totals[name] = (
                current.disk + number(object["disk_bytes"]),
                current.ram + number(object["ram_bytes"]),
                current.cached + number(object["cached_bytes"])
            )
            return
        }
        for (key, child) in object.sorted(by: { $0.key < $1.key }) {
            walk(child, path: path + [key], into: &totals)
        }
    }

    private static func bucket(_ path: [String]) -> String {
        let joined = path.joined(separator: "/").lowercased()
        if joined.contains("quant") { return "Quantization" }
        if joined.contains("hnsw") || path.contains("index") { return "HNSW" }
        if joined.contains("payload_index") { return "Payload indexes" }
        if joined.contains("id_tracker") { return "ID tracker" }
        if joined.contains("payload") { return "Payload" }
        return "Vectors"
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

struct CollectionHealth: Equatable, Sendable {
    var name: String
    var status: String
    var optimizer: String
    var warnings: [String]
    var points: Int?
    var indexedVectors: Int?
    var segments: Int?
    var summary: String
}

enum CollectionHealthParser {
    static func parse(_ data: Data, name: String) -> CollectionHealth? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = (object["result"] as? [String: Any]) ?? object
        let status = (result["status"] as? String) ?? "unknown"
        let optimizer = optimizerText(result["optimizer_status"])
        let warnings = warningText(result["warnings"])
        let config = result["config"] as? [String: Any]
        return CollectionHealth(
            name: name,
            status: status,
            optimizer: optimizer,
            warnings: warnings,
            points: integer(result["points_count"]),
            indexedVectors: integer(result["indexed_vectors_count"]),
            segments: integer(result["segments_count"]),
            summary: summary(config)
        )
    }

    private static func optimizerText(_ value: Any?) -> String {
        if let text = value as? String, !text.isEmpty { return text }
        if let object = value as? [String: Any] {
            if let error = object["error"] as? String, !error.isEmpty { return error }
            return "optimizing"
        }
        return "unknown"
    }

    private static func warningText(_ value: Any?) -> [String] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { row in
            if let text = row as? String, !text.isEmpty { return text }
            if let object = row as? [String: Any], let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            return nil
        }
    }

    private static func summary(_ config: [String: Any]?) -> String {
        guard let config else { return "" }
        let params = config["params"] as? [String: Any]
        let vectors = vectorSummary(params?["vectors"])
        var parts: [String] = []
        if !vectors.isEmpty { parts.append(vectors) }
        if (params?["on_disk_payload"] as? NSNumber)?.boolValue == true {
            parts.append("payload on disk")
        }
        let hnsw = config["hnsw_config"] as? [String: Any]
        if (hnsw?["on_disk"] as? NSNumber)?.boolValue == true {
            parts.append("HNSW on disk")
        } else if hnsw != nil {
            parts.append("HNSW in memory")
        }
        if let quantization = config["quantization_config"] as? [String: Any], !quantization.isEmpty {
            if quantization["scalar"] != nil {
                parts.append("scalar quantization")
            } else if quantization["product"] != nil {
                parts.append("product quantization")
            } else if quantization["binary"] != nil {
                parts.append("binary quantization")
            } else {
                parts.append("quantized")
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func vectorSummary(_ value: Any?) -> String {
        guard let value else { return "" }
        if let named = value as? [String: Any], named["size"] == nil, let first = named.values.compactMap({ $0 as? [String: Any] }).first {
            return vectorSummary(first)
        }
        guard let object = value as? [String: Any] else { return "" }
        let distance = (object["distance"] as? String) ?? ""
        let size = integer(object["size"])
        if let size, !distance.isEmpty { return "\(distance) · \(size) dimensions" }
        if let size { return "\(size) dimensions" }
        return distance
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

struct QdrantHealthReport: Equatable, Sendable {
    var source: String
    var ramBytes: Double?
    var ramLimitBytes: Double?
    var diskBytes: Double?
    var diskLimitBytes: Double?
    var collections: Double?
    var points: Double?
    var vectors: Double?
    var recoveryMode: Bool
    var cpuThrottled: Bool
    var cpuThrottleCount: Double?
    var collection: CollectionHealth?
    var memory: [MemoryComponent]
    var memoryNote: String?
    var warnings: [String]
    var idleWarning: String?

    static let empty = QdrantHealthReport(
        source: "",
        ramBytes: nil,
        ramLimitBytes: nil,
        diskBytes: nil,
        diskLimitBytes: nil,
        collections: nil,
        points: nil,
        vectors: nil,
        recoveryMode: false,
        cpuThrottled: false,
        cpuThrottleCount: nil,
        collection: nil,
        memory: [],
        memoryNote: nil,
        warnings: [],
        idleWarning: nil
    )
}

enum QdrantIdle {
    static let warnAfter: TimeInterval = 5 * 24 * 60 * 60

    static func warning(last: Date?, now: Date) -> String? {
        guard let last else { return nil }
        guard now.timeIntervalSince(last) >= warnAfter else { return nil }
        return "No successful Qdrant request for 5 days. Free clusters suspend after a week without activity."
    }
}

enum QdrantHealth {
    static let alertRatio = 0.8

    static func report(
        samples: [PrometheusSample],
        source: String,
        lastSuccess: Date?,
        now: Date,
        previousThrottle: Double? = nil
    ) -> QdrantHealthReport {
        let ram = PrometheusText.total(samples, "container_memory_working_set_bytes")
            ?? PrometheusText.total(samples, "node_rssanon_bytes")
            ?? PrometheusText.total(samples, "memory_resident_bytes")
        let ramLimit = PrometheusText.total(samples, "kube_pod_container_resource_limits", label: "resource", equals: "memory")
        let disk = PrometheusText.total(samples, "kubelet_volume_stats_used_bytes")
        let diskLimit = PrometheusText.total(samples, "kubelet_volume_stats_capacity_bytes")
        let recovery = (PrometheusText.total(samples, "app_status_recovery_mode") ?? 0) >= 1
        let throttleCount = PrometheusText.total(samples, "container_cpu_cfs_throttled_periods_total")
        let throttled = QdrantHealth.throttleIncreased(current: throttleCount, previous: previousThrottle)
        let idle = QdrantIdle.warning(last: lastSuccess, now: now)
        return QdrantHealthReport(
            source: source,
            ramBytes: ram,
            ramLimitBytes: ramLimit,
            diskBytes: disk,
            diskLimitBytes: diskLimit,
            collections: PrometheusText.total(samples, "collections_total")
                ?? PrometheusText.total(samples, "qdrant_collection_number_of_collections"),
            points: PrometheusText.total(samples, "qdrant_collection_shard_segment_num_points"),
            vectors: PrometheusText.total(samples, "collections_vector_total"),
            recoveryMode: recovery,
            cpuThrottled: throttled,
            cpuThrottleCount: throttleCount,
            collection: nil,
            memory: [],
            memoryNote: nil,
            warnings: warnings(ram: ram, ramLimit: ramLimit, disk: disk, diskLimit: diskLimit, throttled: throttled, idle: idle),
            idleWarning: idle
        )
    }

    static func warnings(
        ram: Double?,
        ramLimit: Double?,
        disk: Double?,
        diskLimit: Double?,
        throttled: Bool,
        idle: String?
    ) -> [String] {
        var lines: [String] = []
        if let ratio = ratio(ram, ramLimit), ratio >= alertRatio {
            lines.append("RAM is \(percent(ratio)) of the limit. Qdrant Cloud alerts at 80%.")
        }
        if let ratio = ratio(disk, diskLimit), ratio >= alertRatio {
            lines.append("Disk is \(percent(ratio)) of capacity. Qdrant Cloud alerts at 80%.")
        }
        if throttled {
            lines.append("CPU demand exceeded this instance since the last check. Requests may slow down.")
        }
        if let idle {
            lines.append(idle)
        }
        return lines
    }

    static func ratio(_ used: Double?, _ limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return used / limit
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func throttleIncreased(current: Double?, previous: Double?) -> Bool {
        guard let current, let previous else { return false }
        return current > previous
    }
}

enum ByteText {
    static func string(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var index = 0
        while abs(value) >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(value)) \(units[index])" }
        return String(format: "%.1f %@", value, units[index])
    }
}

protocol QdrantHealthTransport: Sendable {
    func get(url: URL, apiKey: String) async throws -> (status: Int, body: Data)
}

struct QdrantHealthClient: Sendable {
    var transport: any QdrantHealthTransport

    func load(
        baseURL: String,
        apiKey: String,
        collection: String,
        lastSuccess: Date?,
        now: Date,
        previousThrottle: Double? = nil
    ) async -> QdrantHealthReport {
        let metrics: (samples: [PrometheusSample], source: String)
        do {
            metrics = try await self.metrics(baseURL: baseURL, apiKey: apiKey)
        } catch {
            var report = QdrantHealthReport.empty
            report.idleWarning = QdrantIdle.warning(last: lastSuccess, now: now)
            report.warnings = report.idleWarning.map { [$0] } ?? []
            report.memoryNote = error.localizedDescription
            return report
        }
        var report = QdrantHealth.report(
            samples: metrics.samples,
            source: metrics.source,
            lastSuccess: lastSuccess,
            now: now,
            previousThrottle: previousThrottle
        )
        guard !collection.isEmpty else { return report }
        do {
            let infoURL = try Self.url(baseURL, "collections/\(collection)")
            let info = try await transport.get(url: infoURL, apiKey: apiKey)
            if (200..<300).contains(info.status), let parsed = CollectionHealthParser.parse(info.body, name: collection) {
                report.collection = parsed
                if report.points == nil, let points = parsed.points {
                    report.points = Double(points)
                }
            }
        } catch {
            report.memoryNote = "Collection details could not be loaded."
        }
        do {
            let memoryURL = try Self.url(baseURL, "collections/\(collection)/memory")
            let memory = try await transport.get(url: memoryURL, apiKey: apiKey)
            if (200..<300).contains(memory.status) {
                report.memory = CollectionMemory.components(from: memory.body)
            } else if memory.status == 404 {
                report.memoryNote = report.memoryNote ?? "Memory breakdown needs Qdrant 1.18 or newer."
            } else {
                report.memoryNote = "Memory breakdown could not be loaded."
            }
        } catch {
            report.memoryNote = "Memory breakdown could not be loaded."
        }
        return report
    }

    private func metrics(baseURL: String, apiKey: String) async throws -> (samples: [PrometheusSample], source: String) {
        let cloudURL = try Self.url(baseURL, "sys_metrics")
        let cloud = try await transport.get(url: cloudURL, apiKey: apiKey)
        if (200..<300).contains(cloud.status), let text = String(data: cloud.body, encoding: .utf8), !text.isEmpty {
            return (PrometheusText.samples(in: text), "Cloud metrics")
        }
        let localURL = try Self.url(baseURL, "metrics")
        let local = try await transport.get(url: localURL, apiKey: apiKey)
        guard (200..<300).contains(local.status), let text = String(data: local.body, encoding: .utf8) else {
            throw QdrantHealthError.http(local.status)
        }
        return (PrometheusText.samples(in: text), "Database metrics")
    }

    static func url(_ baseURL: String, _ path: String) throws -> URL {
        guard var url = CollectionSnapshots.restBase(qdrantURL: baseURL) else {
            throw QdrantHealthError.invalidURL(baseURL)
        }
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }
}

enum QdrantHealthError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Qdrant URL is not valid: \(url)"
        case .http(let status):
            return "Qdrant metrics request failed with HTTP \(status)."
        }
    }
}

struct LiveQdrantHealthTransport: QdrantHealthTransport {
    func get(url: URL, apiKey: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}
