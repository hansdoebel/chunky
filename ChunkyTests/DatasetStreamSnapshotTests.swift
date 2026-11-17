import CryptoKit
import Foundation
import Testing

@testable import Chunky

@MainActor
struct DatasetStreamSnapshotTests {
    @Test func validatesLargeRowsAcrossBlocksAndReadsInOrder() async throws {
        let (directory, rows) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try await DatasetStreamSnapshot.validate(from: directory)
        let collector = DatasetRowCollector()
        try await token.forEachRow { index, data in await collector.add(index, data) }
        #expect(await collector.rows == rows)
        #expect(token.byteCount == rows.reduce(0) { $0 + $1.count + 1 })
    }

    @Test func alteredLaterBlockIsRejectedBeforeItsRowIsEmitted() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try await DatasetStreamSnapshot.validate(from: directory)
        let file = try FileHandle(forWritingTo: directory.appendingPathComponent("rows.jsonl"))
        try file.seek(toOffset: 70_000)
        try file.write(contentsOf: Data("z".utf8))
        try file.close()
        let collector = DatasetRowCollector()
        do {
            try await token.forEachRow { index, data in await collector.add(index, data) }
            Issue.record("Changed block must fail before emitting the affected row")
        } catch DatasetError.invalidSnapshot { }
        #expect(await collector.rows.isEmpty)
    }

    @Test func hashCountAndMissingNewlineAreRejected() async throws {
        for mode in 0..<3 {
            let (directory, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("rows.jsonl")
            var data = try Data(contentsOf: url)
            if mode == 0 { data[10] = 122 }
            if mode == 1 { data.append(Data("{}\n".utf8)) }
            if mode == 2 { data.removeLast() }
            try data.write(to: url)
            do {
                _ = try await DatasetStreamSnapshot.validate(from: directory)
                Issue.record("Invalid snapshot must fail")
            } catch DatasetError.invalidSnapshot { }
        }
    }

    @Test func smallVersionTwoRemainsBenchmarkCompatible() throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try DatasetSnapshot.load(from: directory)
        #expect(snapshot.manifest.schemaVersion == 2)
        #expect(snapshot.manifest.rowCount == 2)
    }

    @Test func streamingReaderAcceptsLegacySnapshots() async throws {
        let (directory, rows) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try DatasetSnapshot.load(from: directory).manifest
        var legacy = original
        legacy.schemaVersion = 1
        legacy.requestedRows = 100
        legacy.totalRows = 205
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: directory.appendingPathComponent("manifest.json"))
        let token = try await DatasetStreamSnapshot.validate(from: directory)
        #expect(token.manifest.rowCount == rows.count)
    }

    private func fixture() throws -> (URL, [Data]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let rows = try [String(repeating: "x", count: 100_000), "second"].map { try JSONSerialization.data(withJSONObject: ["text": $0], options: [.sortedKeys]) }
        var bytes = Data()
        for row in rows { bytes.append(row); bytes.append(10) }
        let manifest = DatasetStreamManifest(schemaVersion: 2, datasetID: "fixture/corpus", revision: String(repeating: "a", count: 40), config: "default", split: "train", sourceURL: "https://huggingface.co/datasets/fixture/corpus", license: nil, downloadedAt: Date(), rowCount: 2, totalRows: 2, sha256: DatasetSnapshot.digest(bytes), requestedByteBudget: 10 * 1024 * 1024, maximumRows: 1_000_000, stopReason: .sourceExhausted)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try bytes.write(to: directory.appendingPathComponent("rows.jsonl"))
        return (directory, rows)
    }
}

private actor DatasetRowCollector {
    var rows: [Data] = []
    func add(_ index: Int, _ data: Data) { rows.append(data) }
}
