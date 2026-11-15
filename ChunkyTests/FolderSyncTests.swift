import AppKit
import SwiftUI
import Testing

@testable import Chunky

struct FolderSyncTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ path: String, hash: String, doi: String = "") -> WatchedFile {
        WatchedFile(path: path, contentHash: hash, modified: now, doi: doi)
    }

    private func committed(_ file: WatchedFile, settings: String, points: [String]) -> WatchedRecord {
        WatchedRecord(
            path: file.path,
            contentHash: file.contentHash,
            settingsHash: settings,
            docID: file.docID,
            pointIDs: points,
            modified: file.modified
        )
    }

    private func fingerprint(
        collection: String = "documents",
        embeddingModel: String = "qwen",
        doOCR: Bool = false,
        doclingModel: String = "standard"
    ) -> String {
        FolderSync.settingsFingerprint(
            collection: collection,
            embeddingModel: embeddingModel,
            embeddingBackend: "ollama",
            chunkTokens: 512,
            overlap: 50,
            chunkTokenizer: "docling",
            doclingModel: doclingModel,
            doOCR: doOCR,
            ocrLanguage: "eng",
            doTableExtraction: true,
            tableMode: "accurate",
            doFormulaEnrichment: false
        )
    }

    @Test func newFileIsIngestedAndIdenticalFileIsSkipped() {
        let paper = file("/papers/a.pdf", hash: "abc")
        let first = FolderSync.plan(files: [paper], records: [], settingsHash: "s", deleteRemoved: false)
        #expect(first.actions == [.ingest(paper)])
        #expect(first.records.isEmpty)
        let saved = committed(paper, settings: "s", points: ["p1"])
        let second = FolderSync.plan(files: [paper], records: [saved], settingsHash: "s", deleteRemoved: false)
        #expect(second.actions == [.skip(paper)])
        #expect(second.records == [saved])
        var queued: [WatchedFile] = []
        var deleted: [String] = []
        FolderSyncApply.apply(second.actions, enqueue: { queued.append($0) }, delete: { deleted.append(contentsOf: $0) })
        #expect(queued.isEmpty)
        #expect(deleted.isEmpty)
    }

    @Test func changedFileReplacesPreviousPoints() {
        let original = file("/papers/a.pdf", hash: "abc")
        let record = committed(original, settings: "s", points: ["p1", "p2"])
        let edited = file("/papers/a.pdf", hash: "def")
        let plan = FolderSync.plan(files: [edited], records: [record], settingsHash: "s", deleteRemoved: false)
        #expect(plan.actions == [.replace(edited, previousPointIDs: ["p1", "p2"])])
        #expect(plan.records == [record])
        var deleted: [[String]] = []
        var queued: [String] = []
        FolderSyncApply.apply(plan.actions, enqueue: { file in
            queued.append(file.docID)
            #expect(file.path == "/papers/a.pdf")
        }, delete: { deleted.append($0) })
        #expect(deleted == [["p1", "p2"]])
        #expect(queued == ["def"])
    }

    @Test func doiBecomesTheDocumentIdentity() {
        let paper = file("/papers/a.pdf", hash: "abc", doi: "10.1000/xyz")
        #expect(paper.docID == "10.1000/xyz")
        let plan = FolderSync.plan(files: [paper], records: [], settingsHash: "s", deleteRemoved: false)
        #expect(plan.actions == [.ingest(paper)])
    }

    @Test func settingsChangeReembedsWithoutDeletingWhenPointsAreKeptUntilReplace() {
        let paper = file("/papers/a.pdf", hash: "abc")
        let record = committed(paper, settings: "old", points: ["p1"])
        let plan = FolderSync.plan(files: [paper], records: [record], settingsHash: "new", deleteRemoved: false)
        #expect(plan.actions == [.replace(paper, previousPointIDs: ["p1"])])
        #expect(plan.records == [record])
    }

    @Test func deleteOnRemoveIsOffByDefaultAndOnWhenEnabled() {
        let paper = file("/papers/a.pdf", hash: "abc")
        let record = committed(paper, settings: "s", points: ["p1"])
        let kept = FolderSync.plan(files: [], records: [record], settingsHash: "s", deleteRemoved: false)
        #expect(kept.actions.isEmpty)
        #expect(kept.records == [record])
        let removed = FolderSync.plan(files: [], records: [record], settingsHash: "s", deleteRemoved: true)
        #expect(removed.actions == [.delete(path: "/papers/a.pdf", pointIDs: ["p1"])])
        #expect(removed.records.isEmpty)
    }

    @Test func inFlightFileIsLeftAloneUntilTheJobFinishes() {
        let paper = file("/papers/a.pdf", hash: "abc")
        let record = committed(paper, settings: "s", points: ["p1"])
        let plan = FolderSync.plan(files: [paper], records: [record], settingsHash: "s", deleteRemoved: false, inFlight: [paper.path])
        #expect(plan.actions.isEmpty)
        #expect(plan.records == [record])
    }

    @MainActor
    @Test func finishedUploadIsWhatTheNextScanSkips() {
        let state = AppState()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        state.watchedIndexLocationOverride = folder.appendingPathComponent("watched-folders.json")
        let job = ProcessingJob(url: URL(fileURLWithPath: "/papers/a.pdf"))
        job.status = .completed
        job.watchedPath = "/papers/a.pdf"
        job.watchedContentHash = "abc"
        job.watchedSettingsHash = "s"
        job.watchedDocID = "10.1000/xyz"
        job.watchedModified = now
        job.uploadedPointIDs = ["p1", "p2"]
        state.noteWatchedSuccess(job)
        #expect(state.watchedIndex.records.count == 1)
        #expect(state.watchedIndex.records[0].pointIDs == ["p1", "p2"])
        #expect(state.watchedIndex.records[0].docID == "10.1000/xyz")
        job.status = .failed
        job.uploadedPointIDs = ["gone"]
        state.noteWatchedSuccess(job)
        #expect(state.watchedIndex.records[0].pointIDs == ["p1", "p2"])
    }

    @Test func nonDocumentFilesAreIgnored() {
        let note = file("/papers/notes.txt", hash: "abc")
        let image = file("/papers/scan.png", hash: "def")
        let junk = file("/papers/draft.docx.tmp", hash: "ghi")
        #expect(FolderSync.isDocument(note.path))
        #expect(FolderSync.isDocument(image.path))
        #expect(!FolderSync.isDocument(junk.path))
        let plan = FolderSync.plan(files: [note, junk], records: [], settingsHash: "s", deleteRemoved: false)
        #expect(plan.actions.count == 1)
        if case .ingest(let file) = plan.actions[0] {
            #expect(file.path == note.path)
        } else {
            Issue.record("expected an ingest")
        }
    }

    @Test func fingerprintChangesWhenTheEmbedderOrOCRChanges() {
        let first = fingerprint()
        let second = fingerprint(embeddingModel: "other")
        let ocr = fingerprint(doOCR: true)
        let model = fingerprint(doclingModel: "granite")
        #expect(first != second)
        #expect(first != ocr)
        #expect(first != model)
        #expect(first.count == 64)
    }

    @MainActor
    @Test func rendersTheWatchedFolderSettings() throws {
        let folders = [
            WatchedFolder(path: "/Users/ada/Papers", collection: "documents", paused: false, deleteRemoved: false),
            WatchedFolder(path: "/Users/ada/Archive", collection: "archive", paused: true, deleteRemoved: true),
        ]
        let view = WatchedFoldersPane(
            folders: folders,
            status: "Ingest 1, replace 0, skip 2, delete 0.",
            onAdd: {},
            onScan: {},
            onTogglePause: { _ in },
            onToggleDelete: { _ in },
            onRemove: { _ in }
        )
        .frame(width: 640, height: 360, alignment: .top)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-watched-folder-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("watched-folders.png"))
    }
}
