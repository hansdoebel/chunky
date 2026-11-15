import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct CollectionSnapshotTests {
    @Test func createListAndRestoreUseTheSnapshotPaths() async throws {
        let transport = RecordingSnapshotTransport()
        transport.responses = [
            Data("{\"result\":{\"name\":\"documents-2026.snapshot\",\"creation_time\":\"2026-11-15T00:00:00Z\",\"size\":12}}".utf8),
            Data("{\"result\":[{\"name\":\"documents-2026.snapshot\",\"creation_time\":\"2026-11-15T00:00:00Z\",\"size\":12}]}".utf8),
            Data("{\"result\":true}".utf8),
        ]
        let client = CollectionSnapshotClient(transport: transport)
        let created = try await client.create(baseURL: "http://127.0.0.1:6334", apiKey: "secret", collection: "documents")
        #expect(created.name == "documents-2026.snapshot")
        let listed = try await client.list(baseURL: "http://127.0.0.1:6334", apiKey: "secret", collection: "documents")
        #expect(listed.map(\.name) == ["documents-2026.snapshot"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("restore.snapshot")
        try Data("snapshot".utf8).write(to: file)
        try await client.download(baseURL: "http://127.0.0.1:6334", apiKey: "secret", collection: "documents", snapshot: created.name, to: file)
        try await client.restore(baseURL: "https://example.cloud.qdrant.io", apiKey: "secret", collection: "documents", file: file)
        #expect(transport.calls.map(\.method) == ["POST", "GET", "GET", "POST"])
        #expect(transport.calls[0].path.hasSuffix("/collections/documents/snapshots"))
        #expect(transport.calls[0].query == "wait=true")
        #expect(transport.calls[1].path.hasSuffix("/collections/documents/snapshots"))
        #expect(transport.calls[2].path.hasSuffix("/collections/documents/snapshots/documents-2026.snapshot"))
        #expect(transport.calls[3].path.hasSuffix("/collections/documents/snapshots/upload"))
        #expect(transport.calls[3].query == "priority=snapshot")
        #expect(transport.apiKeys == ["secret", "secret", "secret", "secret"])
        #expect(CollectionSnapshots.confirmOverwrite(collection: "documents").contains("documents"))
        let cloud = IsolatedSettings.make()
        cloud.processingHost = .devbox
        cloud.devboxIngestTarget = .qdrantCloud
        cloud.qdrantCloudURL = "https://example.cloud.qdrant.io:6333"
        cloud.qdrantAPIKey = "secret"
        #expect(CollectionSnapshots.endpoint(settings: cloud).url == "https://example.cloud.qdrant.io:6333")
    }

    @Test @MainActor func snapshotPaneRenders() throws {
        let view = CollectionSnapshotsPane(
            collection: "documents",
            snapshots: [SnapshotRecord(name: "documents-2026.snapshot", creationTime: "2026-11-15T00:00:00Z", size: 12)],
            status: "Ready",
            onCreate: {},
            onDownload: { _ in },
            onRestore: {}
        )
        .frame(width: 520, height: 280)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-snapshots.png"))
        #expect(png.count > 500)
    }
}

private final class RecordingSnapshotTransport: SnapshotTransport, @unchecked Sendable {
    var calls: [SnapshotCall] = []
    var apiKeys: [String] = []
    var responses: [Data] = []
    var files: [URL] = []

    func send(method: String, url: URL, apiKey: String, body: Data?) async throws -> (status: Int, body: Data) {
        record(method: method, url: url, apiKey: apiKey)
        let body = responses.isEmpty ? Data("{}".utf8) : responses.removeFirst()
        return (200, body)
    }

    func download(url: URL, apiKey: String, to destination: URL) async throws {
        record(method: "GET", url: url, apiKey: apiKey)
        files.append(destination)
    }

    func upload(url: URL, apiKey: String, file: URL) async throws -> (status: Int, body: Data) {
        record(method: "POST", url: url, apiKey: apiKey)
        files.append(file)
        let body = responses.isEmpty ? Data("{}".utf8) : responses.removeFirst()
        return (200, body)
    }

    private func record(method: String, url: URL, apiKey: String) {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        calls.append(SnapshotCall(method: method, path: parts?.path ?? url.path, query: parts?.percentEncodedQuery ?? ""))
        apiKeys.append(apiKey)
    }
}
