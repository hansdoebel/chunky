import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct CollectionPackingTests {
    @Test func updateBodySetsTiersAndRejectsPinnedVectors() async throws {
        let packing = CollectionPacking.freeTier
        let update = packing.updateBody()
        let vectors = update["vectors"] as? [String: Any]
        let unnamed = vectors?[""] as? [String: Any]
        #expect(unnamed?["memory"] as? String == "cold")
        let named = packing.updateBody(vectorName: "dense")["vectors"] as? [String: Any]
        let dense = named?["dense"] as? [String: Any]
        #expect(dense?["memory"] as? String == "cold")
        #expect((update["hnsw_config"] as? [String: Any])?["memory"] as? String == "cold")
        #expect((update["payload"] as? [String: Any])?["memory"] as? String == "cold")
        let scalar = ((update["quantization_config"] as? [String: Any])?["scalar"] as? [String: Any])
        #expect(scalar?["type"] as? String == "int8")
        #expect(scalar?["memory"] as? String == "pinned")
        var pinned = packing
        pinned.vectors = .pinned
        #expect(pinned.tierError?.contains("cannot be pinned") == true)
        let transport = ScriptedPackingTransport()
        let client = CollectionPackingClient(transport: transport)
        await #expect(throws: CollectionPackingError.invalid("Dense vectors and payload cannot be pinned. Use cached or cold.")) {
            try await client.update(baseURL: "http://127.0.0.1:6334", apiKey: "db-secret", collection: "documents", packing: pinned)
        }
        try await client.update(baseURL: "http://127.0.0.1:6334", apiKey: "db-secret", collection: "documents", packing: packing)
        #expect(transport.methods == ["GET", "PATCH"])
        #expect(transport.paths.first?.hasSuffix("/collections/documents") == true)
        #expect(transport.keys == ["db-secret", "db-secret"])
        let patched = try JSONSerialization.jsonObject(with: transport.bodies.last ?? Data()) as? [String: Any]
        let patchedVectors = patched?["vectors"] as? [String: Any]
        #expect((patchedVectors?["dense"] as? [String: Any])?["memory"] as? String == "cold")
        let created = packing.createBody(vectorSize: 1024, distance: "Cosine")
        #expect((created["vectors"] as? [String: Any])?["size"] as? Int == 1024)
        #expect((created["vectors"] as? [String: Any])?["memory"] as? String == "cold")
    }

    @Test func snapshotReminderAppearsWhenNoneIsRecent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = SnapshotRecord(name: "old.snapshot", creationTime: "2023-01-01T00:00:00Z", size: 1)
        #expect(SnapshotReminder.message(records: [], now: now).contains("7 days"))
        #expect(SnapshotReminder.message(records: [old], now: now).contains("7 days"))
        let fresh = SnapshotRecord(
            name: "fresh.snapshot",
            creationTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600)),
            size: 2
        )
        #expect(SnapshotReminder.message(records: [fresh], now: now).isEmpty)
    }

    @MainActor
    @Test func rendersThePackingPane() throws {
        let data = try CollectionPackingRenderer.png()
        #expect(data.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-health-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("collection-packing.png"))
    }
}

private final class ScriptedPackingTransport: CollectionPackingTransport, @unchecked Sendable {
    var methods: [String] = []
    var paths: [String] = []
    var keys: [String] = []
    var bodies: [Data] = []

    func send(method: String, url: URL, apiKey: String, body: Data) async throws -> (status: Int, body: Data) {
        methods.append(method)
        paths.append(url.path)
        keys.append(apiKey)
        bodies.append(body)
        if method == "GET" {
            let info = #"{"result":{"config":{"params":{"vectors":{"dense":{"size":8,"distance":"Cosine"}}}}}}"#
            return (200, Data(info.utf8))
        }
        return (200, Data("{\"result\":true}".utf8))
    }
}

@MainActor
private enum CollectionPackingRenderer {
    static func png() throws -> Data {
        let size = NSSize(width: 520, height: 520)
        let view = CollectionPackingScreen(
            collection: "documents",
            packing: .freeTier,
            status: "Choose tiers, then apply them to the current collection.",
            onVectors: { _ in },
            onHNSW: { _ in },
            onQuantizationTier: { _ in },
            onPayload: { _ in },
            onQuantization: { _ in },
            onApply: {},
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
