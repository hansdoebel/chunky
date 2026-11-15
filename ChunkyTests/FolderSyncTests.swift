import AppKit
import SwiftUI
import Testing

@testable import Chunky

struct FolderSyncTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ path: String, hash: String, doi: String = "") -> WatchedFile {
        WatchedFile(path: path, contentHash: hash, modified: now, doi: doi)
    }

    @Test func newFileIsIngestedAndIdenticalFileIsSkipped() {
        let paper = file("/papers/a.pdf", hash: "abc")
        let first = FolderSync.plan(files: [paper], records: [], settingsHash: "s", deleteRemoved: false)
        #expect(first.actions == [.ingest(paper)])
        let second = FolderSync.plan(files: [paper], records: first.records, settingsHash: "s", deleteRemoved: false)
        #expect(second.actions == [.skip(paper)])
        var queued: [String] = []
        var deleted: [String] = []
        FolderSyncApply.apply(second.actions, enqueue: { url, _ in queued.append(url.path) }, delete: { deleted.append(contentsOf: $0) })
        #expect(queued.isEmpty)
        #expect(deleted.isEmpty)
    }

    @Test func changedFileReplacesPreviousPoints() {
        let original = file("/papers/a.pdf", hash: "abc")
        var record = FolderSync.plan(files: [original], records: [], settingsHash: "s", deleteRemoved: false).records[0]
        record.pointIDs = ["p1", "p2"]
        let edited = file("/papers/a.pdf", hash: "def")
        let plan = FolderSync.plan(files: [edited], records: [record], settingsHash: "s", deleteRemoved: false)
        #expect(plan.actions == [.replace(edited, previousPointIDs: ["p1", "p2"])])
        #expect(plan.records[0].pointIDs.isEmpty)
        #expect(plan.records[0].docID == "def")
        var deleted: [[String]] = []
        var queued: [String] = []
        FolderSyncApply.apply(plan.actions, enqueue: { url, docID in
            queued.append(docID)
            #expect(url.path == "/papers/a.pdf")
        }, delete: { deleted.append($0) })
        #expect(deleted == [["p1", "p2"]])
        #expect(queued == ["def"])
    }

    @Test func doiBecomesTheDocumentIdentity() {
        let paper = file("/papers/a.pdf", hash: "abc", doi: "10.1000/xyz")
        let plan = FolderSync.plan(files: [paper], records: [], settingsHash: "s", deleteRemoved: false)
        #expect(plan.records[0].docID == "10.1000/xyz")
    }

    @Test func settingsChangeReembedsWithoutDeletingWhenPointsAreKeptUntilReplace() {
        let paper = file("/papers/a.pdf", hash: "abc")
        var record = FolderSync.plan(files: [paper], records: [], settingsHash: "old", deleteRemoved: false).records[0]
        record.pointIDs = ["p1"]
        let plan = FolderSync.plan(files: [paper], records: [record], settingsHash: "new", deleteRemoved: false)
        #expect(plan.actions == [.replace(paper, previousPointIDs: ["p1"])])
    }

    @Test func deleteOnRemoveIsOffByDefaultAndOnWhenEnabled() {
        let paper = file("/papers/a.pdf", hash: "abc")
        let record = FolderSync.plan(files: [paper], records: [], settingsHash: "s", deleteRemoved: false).records[0]
        let kept = FolderSync.plan(files: [], records: [record], settingsHash: "s", deleteRemoved: false)
        #expect(kept.actions.isEmpty)
        #expect(kept.records == [record])
        let removed = FolderSync.plan(files: [], records: [record], settingsHash: "s", deleteRemoved: true)
        #expect(removed.actions == [.delete(path: "/papers/a.pdf", pointIDs: [])])
        #expect(removed.records.isEmpty)
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

    @Test func fingerprintChangesWhenTheEmbedderChanges() {
        let first = FolderSync.settingsFingerprint(collection: "documents", embeddingModel: "qwen", chunkTokens: 512, overlap: 50)
        let second = FolderSync.settingsFingerprint(collection: "documents", embeddingModel: "other", chunkTokens: 512, overlap: 50)
        #expect(first != second)
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
