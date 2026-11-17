import Foundation

@MainActor
struct DatasetCloudQdrant {
    var baseURL: String
    var apiKey: String
    var tier: DatasetCloudTier
    var transport: any SnapshotTransport = LiveSnapshotTransport()

    func capacity() async throws -> DatasetCloudBudget {
        let response = try await transport.send(method: "GET", url: endpoint("sys_metrics"), apiKey: apiKey, body: nil)
        guard response.status == 200, let text = String(data: response.body, encoding: .utf8) else {
            throw DatasetBenchmarkError.invalid("Cloud capacity metrics could not be read. No import can start or continue without fresh per-node RAM and disk measurements.")
        }
        return try Self.capacity(samples: PrometheusText.samples(in: text), tier: tier)
    }

    static func capacity(samples: [PrometheusSample], tier: DatasetCloudTier) throws -> DatasetCloudBudget {
        func minimum(usedName: String, limitName: String, identity: [String], memory: Bool) throws -> Double {
            let used = samples.filter { $0.name == usedName && (!memory || $0.labels["container"] == "qdrant") }
            let limits = samples.filter { $0.name == limitName && (!memory || ($0.labels["resource"] == "memory" && $0.labels["container"] == "qdrant")) }
            guard !used.isEmpty, used.count == limits.count else { throw DatasetBenchmarkError.invalid("Incomplete Cloud node metrics. Check available capacity in the Cloud Console.") }
            var seen = Set<String>()
            return try used.map { sample -> Double in
                let values = identity.compactMap { sample.labels[$0] }
                guard values.count == identity.count, values.allSatisfy({ !$0.isEmpty }), sample.value.isFinite, sample.value >= 0 else {
                    throw DatasetBenchmarkError.invalid("Cloud metrics lack valid per-node identities or usage.")
                }
                let key = values.joined(separator: "|")
                let matching = limits.filter { limit in identity.allSatisfy { limit.labels[$0] == sample.labels[$0] } }
                guard seen.insert(key).inserted, matching.count == 1, let limit = matching.first?.value, limit.isFinite, limit > 0 else {
                    throw DatasetBenchmarkError.invalid("Ambiguous Cloud node metrics; capacity cannot be safely inferred.")
                }
                return max(0, limit * 0.8 - sample.value)
            }.min() ?? 0
        }
        let ram = try minimum(usedName: "container_memory_working_set_bytes", limitName: "kube_pod_container_resource_limits", identity: ["namespace", "pod", "container"], memory: true)
        let disk = try minimum(usedName: "kubelet_volume_stats_used_bytes", limitName: "kubelet_volume_stats_capacity_bytes", identity: ["namespace", "persistentvolumeclaim"], memory: false)
        return DatasetCloudBudget(tier: tier, ram: tier == .free ? min(ram, 1_000_000_000) : ram, disk: tier == .free ? min(disk, 4_000_000_000) : disk)
    }

    static func createBody(_ estimate: DatasetCloudEstimate) -> [String: Any] {
        ["vectors": ["size": estimate.dimensions, "distance": "Cosine", "memory": "cold"],
         "hnsw_config": ["m": 16, "memory": "cold"], "payload": ["memory": "cold"],
         "shard_number": 1, "replication_factor": 1,
         "strict_mode_config": ["enabled": true, "max_collection_vector_size_bytes": estimate.vectorCap, "max_collection_payload_size_bytes": estimate.payloadCap]]
    }

    func create(name: String, estimate: DatasetCloudEstimate) async throws {
        try DatasetBenchmarkSafety.validateCollection(name, production: "")
        let data = try JSONSerialization.data(withJSONObject: Self.createBody(estimate))
        let response = try await transport.send(method: "PUT", url: endpoint("collections/" + name), apiKey: apiKey, body: data)
        guard (200..<300).contains(response.status),
              let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any], object["result"] as? Bool == true else {
            throw DatasetBenchmarkError.invalid("Cloud rejected guarded collection creation (HTTP \(response.status)). No unguarded fallback is attempted.")
        }
    }

    func verify(name: String, estimate: DatasetCloudEstimate) async throws {
        let response = try await transport.send(method: "GET", url: endpoint("collections/" + name), apiKey: apiKey, body: nil)
        guard response.status == 200 else { throw DatasetBenchmarkError.invalid("Cannot verify the new Cloud collection.") }
        try Self.verify(response.body, estimate: estimate)
    }

    func write(name: String, points: [ChunkPoint]) async throws {
        try DatasetBenchmarkSafety.validateCollection(name, production: "")
        guard (1...16).contains(points.count) else { throw DatasetBenchmarkError.invalid("Invalid import batch size.") }
        guard var components = URLComponents(url: try endpoint("collections/\(name)/points"), resolvingAgainstBaseURL: false) else { throw DatasetBenchmarkError.invalid("Invalid Cloud endpoint.") }
        components.queryItems = [URLQueryItem(name: "wait", value: "true")]
        guard let url = components.url else { throw DatasetBenchmarkError.invalid("Invalid Cloud endpoint.") }
        let rows: [[String: Any]] = points.map { point in
            var payload = point.metadata
            payload["text"] = point.text
            payload["source"] = point.source
            return ["id": point.id, "vector": point.vector, "payload": payload]
        }
        let body = try JSONSerialization.data(withJSONObject: ["points": rows])
        guard body.count <= 16 * 1024 * 1024 else { throw DatasetBenchmarkError.invalid("The encoded upload batch exceeds 16 MiB.") }
        let response = try await transport.send(method: "PUT", url: url, apiKey: apiKey, body: body)
        guard (200..<300).contains(response.status),
              let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let result = root["result"] as? [String: Any], result["status"] as? String == "completed" else {
            throw DatasetBenchmarkError.invalid("Cloud did not acknowledge the upload as completed (HTTP \(response.status)). The request may have written points; no automatic retry is attempted.")
        }
    }

    static func verify(_ data: Data, estimate: DatasetCloudEstimate) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = root?["result"] as? [String: Any]
        let config = result?["config"] as? [String: Any]
        let params = config?["params"] as? [String: Any]
        let vectors = params?["vectors"] as? [String: Any]
        let payload = params?["payload"] as? [String: Any]
        let graph = config?["hnsw_config"] as? [String: Any]
        let strict = config?["strict_mode_config"] as? [String: Any]
        guard vectors?["size"] as? Int == estimate.dimensions, vectors?["distance"] as? String == "Cosine",
              vectors?["memory"] as? String == "cold", params?["shard_number"] as? Int == 1,
              payload?["memory"] as? String == "cold", graph?["memory"] as? String == "cold", graph?["m"] as? Int == 16,
              params?["replication_factor"] as? Int == 1,
              strict?["enabled"] as? Bool == true,
              strict?["max_collection_vector_size_bytes"] as? Int == estimate.vectorCap,
              strict?["max_collection_payload_size_bytes"] as? Int == estimate.payloadCap else {
            throw DatasetBenchmarkError.invalid("The new collection's dimensions, storage or byte safeguards do not match the plan. No vectors were written.")
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = CollectionSnapshots.restBase(qdrantURL: baseURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, !apiKey.isEmpty else {
            throw DatasetBenchmarkError.invalid("Configure a valid HTTPS Cloud endpoint and database API key in Preferences.")
        }
        return url.appendingPathComponent(path)
    }
}
