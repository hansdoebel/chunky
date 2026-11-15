import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct QdrantCloudTests {
    @Test func suspendedClusterShowsPhaseAlertsAndKeyExpiry() async throws {
        let transport = ScriptedCloudTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let created = now.addingTimeInterval(-(80 * 24 * 60 * 60))
        let expires = now.addingTimeInterval(3 * 24 * 60 * 60)
        transport.body = { url in
            if url.path.hasSuffix("/unsuspend") { return Data("{\"cluster\":{\"id\":\"c1\"}}".utf8) }
            if url.path.hasSuffix("/database-api-keys") {
                return Data("""
                {"items":[{"name":"app","created_at":"\(Self.stamp(created))","expires_at":"\(Self.stamp(expires))"}]}
                """.utf8)
            }
            if url.path.hasSuffix("/alerts") {
                return Data("{\"items\":[{\"name\":\"Disk is high\",\"state\":\"FIRING\"},{\"name\":\"Resolved\",\"state\":\"RESOLVED\"}]}".utf8)
            }
            if url.path.hasSuffix("/summary-metrics") { return Data("{\"summary\":{\"ram\":1}}".utf8) }
            if url.path.hasSuffix("/usage-metrics") { return Data("{\"items\":[{\"value\":1},{\"value\":2}]}".utf8) }
            if url.path.hasSuffix("/logs") { return Data("{\"items\":[{}]}".utf8) }
            if url.path.hasSuffix("/events") { return Data("{\"items\":[{},{}]}".utf8) }
            if url.path.hasSuffix("/metrics/inference") { return Data("{\"tokens\":42}".utf8) }
            return Data(Self.clusterJSON.utf8)
        }
        let client = CloudManagementClient(transport: transport)
        let overview = try await client.load(accountID: "acct", clusterID: "clus", managementKey: "mgmt-secret", now: now)
        #expect(overview.phase == "SUSPENDED")
        #expect(overview.version == "v1.16.3")
        #expect(overview.canUnsuspend)
        #expect(overview.ram == "1.0")
        #expect(overview.alerts == ["Disk is high"])
        #expect(overview.usagePoints == 2)
        #expect(overview.events == 2)
        #expect(overview.logs == 1)
        #expect(overview.inferenceTokens == 42)
        #expect(overview.summary.contains("ram") == true)
        #expect(overview.accountID == "acct")
        #expect(overview.clusterID == "clus")
        #expect(overview.missing.isEmpty)
        #expect(overview.keyWarning?.contains("7 days") == true)
        #expect(transport.authorizations.allSatisfy { $0 == "apikey mgmt-secret" })
        #expect(transport.methods.contains("GET"))
        try await client.unsuspend(accountID: "acct", clusterID: "clus", managementKey: "mgmt-secret")
        #expect(transport.methods.last == "POST")
        #expect(transport.paths.last?.hasSuffix("/clusters/clus/unsuspend") == true)
        #expect(QdrantHealthError.http(403).errorDescription?.contains("mgmt-secret") == false)
    }

    @Test func aClearedExpirationDoesNotWarnAndKeepAliveStaysOff() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(DatabaseKeyExpiry.warning(created: now, expires: nil, expiresWasNull: true, now: now) == nil)
        let created = now.addingTimeInterval(-(85 * 24 * 60 * 60))
        #expect(DatabaseKeyExpiry.warning(created: created, expires: nil, expiresWasNull: false, now: now)?.contains("90 days") == true)
        #expect(!QdrantKeepAlive.shouldPing(enabled: false, last: nil, now: now))
        #expect(QdrantKeepAlive.shouldPing(enabled: true, last: nil, now: now))
        #expect(!QdrantKeepAlive.shouldPing(enabled: true, last: now.addingTimeInterval(-60), now: now))
        let url = try? QdrantKeepAlive.collectionsURL(baseURL: "http://127.0.0.1:6334")
        #expect(url?.path == "/collections")
        #expect(url?.host == "127.0.0.1")
        let settings = IsolatedSettings.make()
        #expect(!settings.qdrantKeepAlive)
        #expect(settings.qdrantCloudManagementKey.isEmpty)
        settings.qdrantCloudManagementKey = "mgmt-secret"
        #expect(settings.qdrantCloudManagementKey == "mgmt-secret")
        #expect(settings.qdrantAPIKey.isEmpty)
        settings.processingHost = .devbox
        settings.devboxIngestTarget = .qdrantCloud
        settings.qdrantURL = "http://127.0.0.1:6334"
        settings.qdrantCloudURL = "https://example.cloud.qdrant.io:6333"
        #expect(QdrantKeepAlive.databaseURL(settings: settings) == "https://example.cloud.qdrant.io:6333")
        settings.devboxIngestTarget = .localDocker
        #expect(QdrantKeepAlive.databaseURL(settings: settings) == "http://127.0.0.1:6334")
    }

    @Test func aFailedLogRequestKeepsTheSuspendedCluster() async throws {
        let transport = ScriptedCloudTransport()
        transport.failures = ["/api/monitoring/v1/accounts/acct/cluster/clus/logs"]
        transport.body = { url in
            if url.path.hasSuffix("/logs") { return Data() }
            if url.path.hasSuffix("/database-api-keys") { return Data("{\"items\":[]}".utf8) }
            if url.path.hasSuffix("/alerts") { return Data("{\"items\":[]}".utf8) }
            if url.path.hasSuffix("/summary-metrics") { return Data("{\"summary\":{\"cpu\":0.5}}".utf8) }
            if url.path.hasSuffix("/usage-metrics") { return Data("{\"items\":[]}".utf8) }
            if url.path.hasSuffix("/events") { return Data("{\"items\":[]}".utf8) }
            if url.path.hasSuffix("/metrics/inference") { return Data("{\"tokens\":0}".utf8) }
            return Data(Self.clusterJSON.utf8)
        }
        let overview = try await CloudManagementClient(transport: transport).load(
            accountID: "acct",
            clusterID: "clus",
            managementKey: "mgmt-secret",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(overview.phase == "SUSPENDED")
        #expect(overview.canUnsuspend)
        #expect(overview.missing == ["logs"])
        #expect(overview.summary == "cpu 0.5")
    }

    @MainActor
    @Test func rendersTheCloudSection() throws {
        let cloud = CloudOverview(
            accountID: "account",
            clusterID: "cluster",
            name: "papers",
            phase: "SUSPENDED",
            version: "v1.16.3",
            nodesUp: 0,
            ram: "1.0",
            disk: "4.0",
            cpu: "0.5",
            summary: "cpu 0.5",
            alerts: ["Disk is high"],
            events: 2,
            logs: 1,
            usagePoints: 2,
            inferenceTokens: 42,
            keyWarning: "A database API key expires within 7 days. The default lifetime is 90 days.",
            missing: []
        )
        let data = try QdrantCloudRenderer.png(cloud: cloud)
        #expect(data.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-health-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("qdrant-cloud.png"))
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static let clusterJSON = """
    {"cluster":{"name":"papers","state":{"phase":"CLUSTER_PHASE_SUSPENDED","version":"v1.16.3","nodes_up":0,"resources":{"ram":{"available":1},"disk":{"available":4},"cpu":{"available":0.5}}}}}
    """
}

private final class ScriptedCloudTransport: CloudManagementTransport, @unchecked Sendable {
    var body: (URL) -> Data = { _ in Data() }
    var methods: [String] = []
    var paths: [String] = []
    var authorizations: [String] = []

    var failures: Set<String> = []

    func send(method: String, url: URL, managementKey: String) async throws -> (status: Int, body: Data) {
        methods.append(method)
        paths.append(url.path)
        authorizations.append(CloudManagementClient.authorization(managementKey))
        if failures.contains(url.path) {
            throw URLError(.timedOut)
        }
        return (200, body(url))
    }
}

@MainActor
private enum QdrantCloudRenderer {
    static func png(cloud: CloudOverview) throws -> Data {
        let size = NSSize(width: 720, height: 980)
        let view = QdrantHealthScreen(
            report: .empty,
            status: "Cloud management key accepted.",
            cloud: cloud,
            cloudStatus: "Cloud management key accepted.",
            accountID: "account",
            clusterID: "cluster",
            managementKey: "",
            keepAlive: false,
            onAccount: { _ in },
            onCluster: { _ in },
            onManagementKey: { _ in },
            onKeepAlive: { _ in },
            onUnsuspend: {},
            onRefresh: {},
            onClose: {}
        )
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]), data.count > 1000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
}
