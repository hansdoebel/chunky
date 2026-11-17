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

    @Test func streamBudgetStopsAtWholeRowAndKeepsLegacyCompatibility() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        http.payloadSize = 1_000
        let service = HuggingFaceDatasetService(http: http, availableCapacity: { _ in Int64.max })
        let saved = try await service.downloadStream(dataset: Self.dataset, split: Self.split, byteBudget: 2_500, folder: root)
        #expect(saved.manifest.rowCount == 2)
        #expect(saved.manifest.stopReason == .byteBudget)
        #expect(saved.byteCount <= 2_500)
        #expect(saved.benchmarkCompatible)
        #expect(try DatasetSnapshot.load(from: saved.directory).manifest.rowCount == 2)
        #expect(try await DatasetStreamSnapshot.validate(from: saved.directory).manifest.sha256 == saved.manifest.sha256)
    }

    @Test func streamSourceExhaustionAndAdaptivePagesPreserveAllRows() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = DatasetFixtureHTTP()
        http.totalRows = 31
        http.maximumPageRows = 25
        let service = HuggingFaceDatasetService(http: http, availableCapacity: { _ in Int64.max })
        let saved = try await service.downloadStream(dataset: Self.dataset, split: Self.split, byteBudget: 1_000_000, folder: root)
        #expect(http.requestedLengths.prefix(3) == [100, 50, 25])
        #expect(saved.manifest.rowCount == 31)
        #expect(saved.manifest.stopReason == .sourceExhausted)
        #expect(try await DatasetStreamSnapshot.validate(from: saved.directory).manifest.rowCount == 31)
    }

    @Test func streamDiskPreflightAndOversizedFirstRowLeaveNoPartialFiles() async throws {
        for noSpace in [false, true] {
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let http = DatasetFixtureHTTP()
            let service = HuggingFaceDatasetService(http: http, availableCapacity: { _ in noSpace ? 0 : Int64.max })
            do {
                _ = try await service.downloadStream(dataset: Self.dataset, split: Self.split, byteBudget: 1, folder: root)
                Issue.record("Unsafe download must fail")
            } catch DatasetError.insufficientSpace { #expect(noSpace) }
              catch DatasetError.limitExceeded { #expect(!noSpace) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            if noSpace { #expect(http.offsets.isEmpty) }
        }
    }

    @Test func streamCancellationAfterPageCleansStaging() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = HuggingFaceDatasetService(http: DatasetFixtureHTTP(), availableCapacity: { _ in Int64.max })
        let box = DatasetStreamTaskBox()
        let task = Task {
            try await service.downloadStream(dataset: Self.dataset, split: Self.split, byteBudget: 1_000_000, folder: root) { _, _ in box.task?.cancel() }
        }
        box.task = task
        do { _ = try await task.value; Issue.record("Cancellation must stop stream") }
        catch is CancellationError { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func sourceSizesAndPreviewAreRevisionCheckedAndTyped() async throws {
        let http = DatasetFixtureHTTP()
        let service = HuggingFaceDatasetService(http: http)
        #expect(try await service.size(for: Self.dataset, split: Self.split) == DatasetSizeInfo(sourceRows: 205, parquetBytes: 500))
        let estimate = try await service.estimate(for: Self.dataset, split: Self.split)
        #expect(estimate.previewRows == 20)
        #expect(estimate.bytes(for: 40) == estimate.previewBytes * 2)
        for mode in ["partial", "boolean", "negative", "wrongSplit", "revision"] {
            http.sizeFailure = mode
            do { _ = try await service.size(for: Self.dataset, split: Self.split); Issue.record("Invalid size must fail") }
            catch DatasetError.invalidResponse { #expect(mode != "revision") }
            catch DatasetError.revisionChanged { #expect(mode == "revision") }
        }
    }

    @Test func presetsAndRecommendationsDoNotConflateLanguagesOrBudgets() {
        #expect(DatasetSampleSize.small.byteBudget == 10 * 1024 * 1024)
        #expect(DatasetSampleSize.medium.byteBudget == 100 * 1024 * 1024)
        #expect(DatasetSampleSize.large.byteBudget == DatasetStreamSnapshot.maximumBytes)
        #expect(DatasetSampleSize.legacy.byteBudget == nil)
        #expect(DatasetRecommendation.wikipedia.map(\.config) == ["text-corpus", "20231101.simple", "20231101.en", "20231101.de"])
        #expect(Set(DatasetRecommendation.wikipedia.map(\.id)).count == 4)
    }

    @Test func datasetLibraryScreenshotsContainVisibleContent() throws {
        for scheme in [ColorScheme.light, .dark] {
            let state = DatasetLibraryState()
            state.results = [Self.dataset]
            state.selected = Self.dataset
            state.splits = [Self.split]
            state.splitID = Self.split.id
            state.status = "Fixture metadata. No benchmark has been measured. Cloud storage is checked separately during import."
            state.sizeInfo = DatasetSizeInfo(sourceRows: 205, parquetBytes: 12_345_678)
            state.sizeStatus = "Fixture sizes, not live dataset measurements."
            let view = DatasetLibraryPane(state: state).frame(width: 920, height: 1100).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 920, height: 1100)
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
    var maximumPageRows: Int?
    var requestedLengths: [Int] = []
    var sizeFailure = ""

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
        if url.path == "/size" {
            var item: [String: Any] = ["dataset": "fixture/corpus", "config": "corpus", "split": "train", "num_rows": 205, "num_bytes_parquet_files": 500]
            if sizeFailure == "boolean" { item["num_rows"] = true }
            if sizeFailure == "negative" { item["num_bytes_parquet_files"] = -1 }
            if sizeFailure == "wrongSplit" { item["split"] = "other" }
            return DatasetHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["size": ["splits": [item]], "partial": sizeFailure == "partial"]), revision: sizeFailure == "revision" ? nil : revision)
        }
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let offset = Int(query["offset"]!)!
        let length = Int(query["length"]!)!
        requestedLengths.append(length)
        if let maximumPageRows, length > maximumPageRows { throw DatasetError.limitExceeded }
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

@MainActor
private final class DatasetStreamTaskBox {
    var task: Task<DatasetStreamDownload, Error>?
}
