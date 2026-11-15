import Foundation

struct WorkerEndpoint: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: String

    static let starterNames = ["Mac Studio 10GbE", "Wi-Fi LAN", "Tailscale"]

    static func starters() -> [WorkerEndpoint] {
        starterNames.map { WorkerEndpoint(id: UUID(), name: $0, url: "") }
    }
}

enum WorkerEndpointStore {
    static let listKey = "chunky.workerEndpoints"
    static let activeKey = "chunky.workerEndpointActive"

    static func tokenKey(_ id: UUID) -> String {
        "worker_endpoint.\(id.uuidString)"
    }

    static func load(defaults: UserDefaults) -> [WorkerEndpoint] {
        guard let data = defaults.data(forKey: listKey),
              let decoded = try? JSONDecoder().decode([WorkerEndpoint].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ endpoints: [WorkerEndpoint], defaults: UserDefaults) {
        let data = (try? JSONEncoder().encode(endpoints)) ?? Data()
        defaults.set(data, forKey: listKey)
    }

    static func activeID(defaults: UserDefaults) -> UUID? {
        guard let raw = defaults.string(forKey: activeKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func setActive(_ id: UUID?, defaults: UserDefaults) {
        defaults.set(id?.uuidString, forKey: activeKey)
    }
}

enum WorkerProbeKind: String, Equatable {
    case invalidURL
    case unreachable
    case unauthorized
    case appTransportSecurity
    case connected
}

struct WorkerProbeReport: Equatable {
    var kind: WorkerProbeKind
    var latencyMs: Int
    var message: String
}

enum WorkerProbe {
    static func isCurrent(started: Int, url: String, token: String, generation: Int, currentURL: String, currentToken: String) -> Bool {
        started == generation && url == currentURL && token == currentToken
    }

    static func accepts(url: String) -> Bool {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil else {
            return false
        }
        return true
    }

    static func classify(
        url: String,
        healthStatus: Int?,
        healthFailedSecure: Bool,
        healthUnreachable: Bool,
        modelsStatus: Int?,
        modelsFailedSecure: Bool,
        modelsUnreachable: Bool,
        elapsed: TimeInterval
    ) -> WorkerProbeReport {
        let latency = max(0, Int((elapsed * 1000).rounded()))
        if !accepts(url: url) {
            return WorkerProbeReport(kind: .invalidURL, latencyMs: latency, message: "Invalid worker URL: \(url)")
        }
        if healthFailedSecure || modelsFailedSecure {
            return WorkerProbeReport(
                kind: .appTransportSecurity,
                latencyMs: latency,
                message: "App Transport Security blocked \(url). Use HTTPS, or a LAN address."
            )
        }
        if healthUnreachable || healthStatus == nil {
            return WorkerProbeReport(
                kind: .unreachable,
                latencyMs: latency,
                message: "Cannot reach \(url)."
            )
        }
        if let healthStatus, healthStatus != 200 {
            return WorkerProbeReport(
                kind: .unreachable,
                latencyMs: latency,
                message: "Health check returned HTTP \(healthStatus) for \(url)."
            )
        }
        if modelsUnreachable {
            return WorkerProbeReport(
                kind: .unreachable,
                latencyMs: latency,
                message: "Health succeeded, then \(url) became unreachable."
            )
        }
        if modelsStatus == 401 || modelsStatus == 403 {
            return WorkerProbeReport(
                kind: .unauthorized,
                latencyMs: latency,
                message: "Worker rejected the token (HTTP \(modelsStatus ?? 401)) in \(latency) ms."
            )
        }
        if modelsStatus != 200 {
            return WorkerProbeReport(
                kind: .unreachable,
                latencyMs: latency,
                message: "Models check returned HTTP \(modelsStatus ?? 0) for \(url)."
            )
        }
        return WorkerProbeReport(
            kind: .connected,
            latencyMs: latency,
            message: "Connected in \(latency) ms."
        )
    }
}
