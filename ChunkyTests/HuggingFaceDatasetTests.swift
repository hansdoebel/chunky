import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct HuggingFaceDatasetTests {
    static let revision = String(repeating: "a", count: 40)
    static var dataset: HuggingFaceDataset { HuggingFaceDataset(id: "fixture/corpus", revision: revision, downloads: 10, license: "cc-by-4.0", restricted: false) }
    static let split = DatasetSplit(config: "corpus", split: "train")

    @Test func snapshotPagesMatchRevisionAndPreserveJSONRows() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        let service = HuggingFaceDatasetService(http: http)
        let snapshot = try await service.download(dataset: Self.dataset, split: Self.split, rows: 101, folder: root)
        #expect(http.offsets == [0, 100])
        #expect(snapshot.manifest.rowCount == 101)
        #expect(snapshot.manifest.requestedRows == 101)
        #expect(snapshot.manifest.totalRows == 205)
        #expect(snapshot.manifest.revision == Self.revision)
        #expect(snapshot.manifest.license == "cc-by-4.0")
        let loaded = try DatasetSnapshot.load(from: snapshot.directory)
        #expect(loaded.manifest.sha256 == snapshot.manifest.sha256)
        let second = try await service.download(dataset: Self.dataset, split: Self.split, rows: 1, folder: root)
        #expect(second.directory != snapshot.directory)
        #expect(try DatasetSnapshot.load(from: snapshot.directory).manifest.rowCount == 101)
        try Data("{}\n".utf8).write(to: snapshot.rowsURL)
        #expect(throws: DatasetError.self) { try DatasetSnapshot.load(from: snapshot.directory) }
    }

    @Test func revisionMismatchAndMissingRevisionDoNotSavePartialSnapshot() async throws {
        for missing in [false, true] {
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let http = DatasetFixtureHTTP()
            http.badRevisionOffset = 100
            http.missingRevision = missing
            do {
                _ = try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: 101, folder: root)
                Issue.record("Mismatched revision should fail")
            } catch DatasetError.revisionChanged { }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func truncatedCellsAndIncompletePagesAreRejected() async throws {
        for incomplete in [false, true] {
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let http = DatasetFixtureHTTP()
            http.incomplete = incomplete
            http.truncated = !incomplete
            do {
                _ = try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: 2, folder: root)
                Issue.record("Incomplete response should fail")
            } catch DatasetError.invalidResponse { }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func missingOrMalformedTruncationMetadataFailsClosed() async throws {
        for malformed in [false, true] {
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let http = DatasetFixtureHTTP()
            http.missingTruncation = !malformed
            http.malformedTruncation = malformed
            do {
                _ = try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: 1, folder: root)
                Issue.record("Unverifiable row completeness should fail")
            } catch DatasetError.invalidResponse { }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func oversizedOrDuplicateSearchResultsAreRejected() async throws {
        for duplicate in [false, true] {
            let http = DatasetFixtureHTTP()
            http.invalidSearchCount = duplicate ? 2 : 31
            do {
                _ = try await HuggingFaceDatasetService(http: http).search("fixture")
                Issue.record("Invalid search list should fail")
            } catch DatasetError.invalidResponse { }
        }
    }

    @Test func rowBoundsAndOversizedResponsesFailBeforeSaving() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        for rows in [0, 10_001] {
            do {
                _ = try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: rows, folder: root)
                Issue.record("Invalid bound should fail")
            } catch DatasetError.limitExceeded { }
        }
        #expect(http.offsets.isEmpty)
        http.oversized = true
        do {
            _ = try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: 1, folder: root)
            Issue.record("Oversized response should fail")
        } catch DatasetError.invalidResponse { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let file = root.appendingPathComponent("bounded")
        try Data(repeating: 1, count: 1025).write(to: file)
        #expect(throws: DatasetError.self) { try DatasetSnapshot.readBounded(file, limit: 1024) }
    }

    @Test func cancellationStopsBeforeNetworkAndLeavesNoFiles() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        let task = Task { try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: 100, folder: root) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled task should fail")
        } catch is CancellationError { }
        #expect(http.offsets.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cancellationAfterFirstPageLeavesNoSnapshotOrStagingFolder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        let box = DatasetTaskBox()
        let service = HuggingFaceDatasetService(http: http)
        let task = Task {
            try await service.download(dataset: Self.dataset, split: Self.split, rows: 101, folder: root) { count in
                if count == 100 { box.task?.cancel() }
            }
        }
        box.task = task
        do {
            _ = try await task.value
            Issue.record("Mid-download cancellation should fail")
        } catch is CancellationError { }
        #expect(http.offsets == [0])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func aggregateByteLimitRejectsIndividuallyValidPagesWithoutFiles() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        http.totalRows = 2_000
        http.payloadSize = 50_000
        do {
            _ = try await HuggingFaceDatasetService(http: http).download(dataset: Self.dataset, split: Self.split, rows: 1_200, folder: root)
            Issue.record("Aggregate limit should fail")
        } catch DatasetError.limitExceeded { }
        #expect(http.offsets.count > 1)
        #expect(http.responseSizes.allSatisfy { $0 <= HuggingFaceDatasetService.pageBytes })
        #expect(http.responseSizes.reduce(0, +) > DatasetSnapshot.maximumBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func searchAndSplitMetadataAreValidated() async throws {
        let http = DatasetFixtureHTTP()
        let service = HuggingFaceDatasetService(http: http)
        let results = try await service.search("fixture/corpus")
        #expect(results.count == 2)
        #expect(results[0] == Self.dataset)
        #expect(results[1].restricted)
        let details = try await service.details("fixture/corpus")
        #expect(try await service.splits(for: details) == [Self.split])
        #expect(!DatasetSnapshot.validDatasetID("../escape"))
        #expect(!DatasetSnapshot.validDatasetID("owner/repo?token=x"))
        #expect(!DatasetSnapshot.validRevision("main"))
    }

    @Test func cancelledSearchIgnoresLateResponse() async throws {
        let http = DeferredDatasetHTTP()
        let state = DatasetLibraryState(service: HuggingFaceDatasetService(http: http))
        state.search()
        for _ in 0..<100 {
            if http.continuation != nil { break }
            await Task.yield()
        }
        let continuation = try #require(http.continuation)
        state.cancel()
        continuation.resume(returning: DatasetHTTPResponse(data: Data("[]".utf8), revision: nil))
        for _ in 0..<10 { await Task.yield() }
        #expect(state.results.isEmpty)
        #expect(!state.busy)
        #expect(state.status.hasPrefix("Cancelled"))
    }

    @Test func customFolderPersistsAndResetDoesNotDeleteFiles() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "chunky-dataset-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DatasetFolderStore(defaults: defaults)
        try store.setFolder(root)
        #expect(try DatasetFolderStore(defaults: defaults).folder().resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        let file = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        store.reset()
        #expect(try store.folder() == store.defaultFolder)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func datasetLibraryScreenshotsContainVisibleContent() throws {
        for scheme in [ColorScheme.light, .dark] {
            let state = DatasetLibraryState()
            state.results = [Self.dataset]
            state.selected = Self.dataset
            state.splits = [Self.split]
            state.splitID = Self.split.id
            state.status = "Fixture metadata. Choose a split and row limit; no benchmark has been measured."
            let view = DatasetLibraryPane(state: state).frame(width: 920, height: 820).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 920, height: 820)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            window.orderFrontRegardless()
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            window.displayIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)
            var colors = Set<String>()
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                    }
                }
            }
            #expect(colors.count > 20)
            try png.write(to: URL(fileURLWithPath: "/tmp/chunky-datasets-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dataset-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

@MainActor
private final class DatasetFixtureHTTP: DatasetHTTP {
    var offsets: [Int] = []
    var totalRows = 205
    var payloadSize = 0
    var responseSizes: [Int] = []
    var badRevisionOffset: Int?
    var missingRevision = false
    var truncated = false
    var incomplete = false
    var oversized = false
    var missingTruncation = false
    var malformedTruncation = false
    var invalidSearchCount: Int?

    @MainActor func get(_ url: URL, maximumBytes: Int) async throws -> DatasetHTTPResponse {
        let revision = HuggingFaceDatasetTests.revision
        if url.path == "/api/datasets" || url.path.hasPrefix("/api/datasets/") {
            let item: [String: Any] = ["id": "fixture/corpus", "sha": revision, "downloads": 10, "tags": ["license:cc-by-4.0"], "gated": false]
            if let count = invalidSearchCount {
                return DatasetHTTPResponse(data: try JSONSerialization.data(withJSONObject: Array(repeating: item, count: count)), revision: nil)
            }
            let object: Any = url.path == "/api/datasets" ? [item, item.merging(["id": "fixture/private", "gated": "auto"]) { _, rhs in rhs }] : item
            return DatasetHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), revision: nil)
        }
        if url.path == "/splits" {
            return DatasetHTTPResponse(data: Data("{\"splits\":[{\"config\":\"corpus\",\"split\":\"train\"}]}".utf8), revision: revision)
        }
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let offset = Int(query["offset"]!)!
        let length = Int(query["length"]!)!
        offsets.append(offset)
        if oversized { return DatasetHTTPResponse(data: Data(repeating: 32, count: maximumBytes + 1), revision: revision) }
        let count = incomplete ? 0 : min(length, totalRows - offset)
        let rows: [[String: Any]] = (0..<count).map { index in
            var row: [String: Any] = ["row_idx": offset + index, "row": ["_id": String(offset + index), "text": payloadSize > 0 ? String(repeating: "x", count: payloadSize) : "Fixture row \(offset + index)", "optional": NSNull()]]
            if !missingTruncation { row["truncated_cells"] = malformedTruncation ? "invalid" : (truncated ? ["text"] : []) }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["rows": rows, "num_rows_total": totalRows])
        responseSizes.append(data.count)
        return DatasetHTTPResponse(data: data, revision: badRevisionOffset == offset ? (missingRevision ? nil : String(repeating: "b", count: 40)) : revision)
    }
}

@MainActor
private final class DeferredDatasetHTTP: DatasetHTTP {
    var continuation: CheckedContinuation<DatasetHTTPResponse, Error>?
    @MainActor func get(_ url: URL, maximumBytes: Int) async throws -> DatasetHTTPResponse {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class DatasetTaskBox {
    var task: Task<DatasetSnapshot, Error>?
}
