import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct QdrantHealthTests {
    @Test func cloudMetricsWarnAtEightyPercentAndShowRecovery() {
        let samples = PrometheusText.samples(in: """
        # comment
        app_status_recovery_mode 1
        collections_total 2
        collections_vector_total 1000
        qdrant_collection_shard_segment_num_points{collection="documents"} 400
        qdrant_collection_shard_segment_num_points{collection="notes"} 100
        node_rssanon_bytes 100
        container_memory_working_set_bytes 900
        kube_pod_container_resource_limits{resource="memory",container="qdrant"} 1000
        kube_pod_container_resource_limits{resource="cpu",container="qdrant"} 2
        kubelet_volume_stats_used_bytes 3500
        kubelet_volume_stats_capacity_bytes 4000
        container_cpu_cfs_throttled_periods_total 12
        """)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let last = now.addingTimeInterval(-(5 * 24 * 60 * 60))
        let report = QdrantHealth.report(samples: samples, source: "Cloud metrics", lastSuccess: last, now: now, previousThrottle: 0)
        #expect(report.recoveryMode)
        #expect(report.cpuThrottled)
        #expect(report.collections == 2)
        #expect(report.points == 500)
        #expect(report.vectors == 1000)
        #expect(report.ramLimitBytes == 1000)
        #expect(report.ramBytes == 900)
        #expect(report.warnings.contains { $0.contains("RAM is 90%") })
        #expect(report.warnings.contains { $0.contains("Disk is 88%") })
        #expect(report.warnings.contains { $0.contains("since the last check") })
        let unchanged = QdrantHealth.report(samples: samples, source: "Cloud metrics", lastSuccess: last, now: now, previousThrottle: 12)
        #expect(!unchanged.cpuThrottled)
        let first = QdrantHealth.report(samples: samples, source: "Cloud metrics", lastSuccess: last, now: now)
        #expect(!first.cpuThrottled)
        #expect(QdrantIdle.warning(last: now.addingTimeInterval(-24 * 60 * 60), now: now) == nil)
    }

    @Test func selfHostedMetricsFallBackWhenCloudMetricsAreMissing() async throws {
        let transport = ScriptedHealthTransport()
        transport.bodies["/sys_metrics"] = (404, Data())
        transport.bodies["/metrics"] = (200, Data("""
        app_status_recovery_mode 0
        collections_total 1
        collections_vector_total 10
        memory_resident_bytes 100
        """.utf8))
        transport.bodies["/collections/documents"] = (200, Data(Self.collectionJSON.utf8))
        transport.bodies["/collections/documents/memory"] = (404, Data())
        let client = QdrantHealthClient(transport: transport)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let report = await client.load(
            baseURL: "http://127.0.0.1:6334",
            apiKey: "db-secret",
            collection: "documents",
            lastSuccess: nil,
            now: now
        )
        #expect(report.source == "Database metrics")
        #expect(report.ramBytes == 100)
        #expect(report.ramLimitBytes == nil)
        #expect(!report.recoveryMode)
        #expect(report.collection?.status == "yellow")
        #expect(report.collection?.optimizer == "indexing")
        #expect(report.collection?.warnings == ["payload index is building", "segment is not indexed"])
        #expect(report.collection?.summary.contains("Cosine") == true)
        #expect(report.collection?.summary.contains("scalar quantization") == true)
        #expect(report.memoryNote == "Memory breakdown needs Qdrant 1.18 or newer.")
        #expect(transport.paths == [
            "/sys_metrics",
            "/metrics",
            "/collections/documents",
            "/collections/documents/memory",
        ])
        #expect(transport.keys == ["db-secret", "db-secret", "db-secret", "db-secret"])
        #expect(QdrantHealthError.http(404).errorDescription?.contains("db-secret") == false)
    }

    @Test func aFailedMemoryRequestKeepsTheUsageReading() async {
        let transport = ScriptedHealthTransport()
        transport.bodies["/sys_metrics"] = (200, Data("""
        container_memory_working_set_bytes 800
        kube_pod_container_resource_limits{resource="memory"} 1000
        """.utf8))
        transport.failures = ["/collections/documents", "/collections/documents/memory"]
        let report = await QdrantHealthClient(transport: transport).load(
            baseURL: "http://127.0.0.1:6334",
            apiKey: "db-secret",
            collection: "documents",
            lastSuccess: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(report.ramBytes == 800)
        #expect(report.warnings.contains { $0.contains("80%") })
        #expect(report.memoryNote == "Memory breakdown could not be loaded.")
    }

    @Test func memoryBreakdownGroupsHNSWAndQuantization() throws {
        let data = Data(Self.memoryJSON.utf8)
        let rows = CollectionMemory.components(from: data)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        #expect(byName["Vectors"]?.disk == 1000)
        #expect(byName["HNSW"]?.ram == 50)
        #expect(byName["Quantization"]?.ram == 80)
        #expect(byName["Payload"]?.disk == 40)
        #expect(byName["Payload indexes"]?.disk == 15)
        #expect(byName["ID tracker"]?.ram == 8)
    }

    @Test func lastSuccessIsStoredLocally() {
        let settings = IsolatedSettings.make()
        #expect(settings.qdrantLastSuccessAt == nil)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        settings.qdrantLastSuccessAt = date
        #expect(settings.qdrantLastSuccessAt == date)
        settings.qdrantLastSuccessAt = nil
        #expect(settings.qdrantLastSuccessAt == nil)
    }

    @MainActor
    @Test func rendersTheHealthPane() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var report = QdrantHealth.report(
            samples: PrometheusText.samples(in: """
            app_status_recovery_mode 1
            collections_total 2
            collections_vector_total 1000
            qdrant_collection_shard_segment_num_points 500
            node_rssanon_bytes 900
            kube_pod_container_resource_limits{resource="memory"} 1000
            kubelet_volume_stats_used_bytes 900
            kubelet_volume_stats_capacity_bytes 1000
            container_cpu_cfs_throttled_periods_total 3
            """),
            source: "Cloud metrics",
            lastSuccess: now.addingTimeInterval(-(6 * 24 * 60 * 60)),
            now: now,
            previousThrottle: 0
        )
        report.collection = CollectionHealth(
            name: "documents",
            status: "yellow",
            optimizer: "indexing",
            warnings: ["payload index is building"],
            points: 500,
            indexedVectors: 100,
            segments: 2,
            summary: "Cosine · 1024 dimensions · payload on disk · HNSW in memory · scalar quantization"
        )
        report.memory = CollectionMemory.components(from: Data(Self.memoryJSON.utf8))
        let data = try QdrantHealthRenderer.png(report: report)
        #expect(data.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-health-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("qdrant-health.png"))
    }

    private static let collectionJSON = """
    {"result":{"status":"yellow","optimizer_status":{"error":"indexing"},"warnings":["payload index is building",{"message":"segment is not indexed"}],"points_count":400,"indexed_vectors_count":100,"segments_count":2,"config":{"params":{"vectors":{"dense":{"size":1024,"distance":"Cosine"}},"on_disk_payload":true},"hnsw_config":{"m":16,"on_disk":false},"quantization_config":{"scalar":{"type":"int8"}}}}}
    """

    private static let memoryJSON = """
    {"result":{"vectors":{"dense":{"storage":{"disk_bytes":1000,"ram_bytes":10,"cached_bytes":20},"index":{"disk_bytes":200,"ram_bytes":50,"cached_bytes":0},"quantization":{"disk_bytes":80,"ram_bytes":80,"cached_bytes":0}}},"payload":{"disk_bytes":40,"ram_bytes":5,"cached_bytes":0},"payload_index":{"source":{"disk_bytes":15,"ram_bytes":15,"cached_bytes":0}},"id_tracker":{"disk_bytes":8,"ram_bytes":8,"cached_bytes":0}}}
    """
}

private final class ScriptedHealthTransport: QdrantHealthTransport, @unchecked Sendable {
    var bodies: [String: (Int, Data)] = [:]
    var paths: [String] = []
    var keys: [String] = []

    var failures: Set<String> = []

    func get(url: URL, apiKey: String) async throws -> (status: Int, body: Data) {
        paths.append(url.path)
        keys.append(apiKey)
        if failures.contains(url.path) {
            throw URLError(.timedOut)
        }
        return bodies[url.path] ?? (404, Data())
    }
}

@MainActor
private enum QdrantHealthRenderer {
    static func png(report: QdrantHealthReport) throws -> Data {
        let size = NSSize(width: 720, height: 640)
        let view = QdrantHealthScreen(report: report, status: "Updated documents.", onRefresh: {}, onClose: {})
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
