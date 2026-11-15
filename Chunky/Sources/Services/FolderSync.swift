import CryptoKit
import Foundation

nonisolated struct WatchedFolder: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var collection: String
    var paused: Bool
    var deleteRemoved: Bool

    init(id: UUID = UUID(), path: String, collection: String, paused: Bool = false, deleteRemoved: Bool = false) {
        self.id = id
        self.path = path
        self.collection = collection
        self.paused = paused
        self.deleteRemoved = deleteRemoved
    }
}

nonisolated struct WatchedFile: Equatable, Sendable {
    var path: String
    var contentHash: String
    var modified: Date
    var doi: String

    var docID: String { doi.isEmpty ? contentHash : doi }
}

nonisolated struct WatchedRecord: Codable, Equatable, Sendable {
    var path: String
    var contentHash: String
    var settingsHash: String
    var docID: String
    var pointIDs: [String]
    var modified: Date
}

nonisolated enum FolderSyncAction: Equatable, Sendable {
    case ingest(WatchedFile)
    case replace(WatchedFile, previousPointIDs: [String])
    case skip(WatchedFile)
    case delete(path: String, pointIDs: [String])
}

nonisolated enum FolderSync {
    static let documentExtensions: Set<String> = [
        "pdf", "docx", "pptx", "html", "htm", "md", "markdown", "txt", "json", "png", "jpg", "jpeg", "tif", "tiff",
    ]

    static func isDocument(_ path: String) -> Bool {
        documentExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func settingsFingerprint(
        collection: String,
        embeddingModel: String,
        embeddingBackend: String,
        chunkTokens: Int,
        overlap: Int,
        chunkTokenizer: String,
        doclingModel: String,
        doOCR: Bool,
        ocrLanguage: String,
        doTableExtraction: Bool,
        tableMode: String,
        doFormulaEnrichment: Bool
    ) -> String {
        let text = [
            collection,
            embeddingModel,
            embeddingBackend,
            String(chunkTokens),
            String(overlap),
            chunkTokenizer,
            doclingModel,
            doOCR ? "ocr" : "no-ocr",
            ocrLanguage,
            doTableExtraction ? "tables" : "no-tables",
            tableMode,
            doFormulaEnrichment ? "formula" : "no-formula",
        ].joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func plan(
        files: [WatchedFile],
        records: [WatchedRecord],
        settingsHash: String,
        deleteRemoved: Bool,
        inFlight: Set<String> = []
    ) -> (actions: [FolderSyncAction], records: [WatchedRecord]) {
        let documents = files.filter { isDocument($0.path) }
        let previous = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
        var actions: [FolderSyncAction] = []
        var next: [WatchedRecord] = []
        var seen = Set<String>()
        for file in documents {
            seen.insert(file.path)
            if inFlight.contains(file.path) {
                if let record = previous[file.path] {
                    next.append(record)
                }
                continue
            }
            if let record = previous[file.path], record.contentHash == file.contentHash, record.settingsHash == settingsHash {
                actions.append(.skip(file))
                next.append(WatchedRecord(
                    path: file.path,
                    contentHash: file.contentHash,
                    settingsHash: settingsHash,
                    docID: record.docID,
                    pointIDs: record.pointIDs,
                    modified: file.modified
                ))
            } else if let record = previous[file.path] {
                actions.append(.replace(file, previousPointIDs: record.pointIDs))
                next.append(record)
            } else {
                actions.append(.ingest(file))
            }
        }
        if deleteRemoved {
            for record in records where !seen.contains(record.path) {
                actions.append(.delete(path: record.path, pointIDs: record.pointIDs))
            }
        } else {
            next.append(contentsOf: records.filter { !seen.contains($0.path) })
        }
        return (actions, next)
    }
}

nonisolated enum FolderSyncApply {
    static func apply(
        _ actions: [FolderSyncAction],
        enqueue: (WatchedFile) -> Void,
        delete: ([String]) -> Void
    ) {
        for action in actions {
            switch action {
            case .skip:
                break
            case .ingest(let file):
                enqueue(file)
            case .replace(let file, let ids):
                if !ids.isEmpty { delete(ids) }
                enqueue(file)
            case .delete(_, let ids):
                if !ids.isEmpty { delete(ids) }
            }
        }
    }
}

nonisolated struct WatchedFolderIndex: Codable, Equatable, Sendable {
    var folders: [WatchedFolder]
    var records: [WatchedRecord]

    static func load(from url: URL) -> WatchedFolderIndex {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(WatchedFolderIndex.self, from: data) else {
            return WatchedFolderIndex(folders: [], records: [])
        }
        return index
    }

    func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

nonisolated protocol FolderWatching: AnyObject {
    func start(paths: [String], onChange: @escaping () -> Void)
    func stop()
}
