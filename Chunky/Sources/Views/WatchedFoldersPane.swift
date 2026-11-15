import AppKit
import SwiftUI

struct WatchedFoldersPane: View {
    var folders: [WatchedFolder]
    var status: String
    var onAdd: () -> Void
    var onScan: () -> Void
    var onTogglePause: (UUID) -> Void
    var onToggleDelete: (UUID) -> Void
    var onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New and changed documents are ingested. An unchanged file is skipped. Removing a file deletes its points only when that folder allows it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if folders.isEmpty {
                Text("No watched folders")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders) { folder in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text((folder.path as NSString).lastPathComponent)
                            .font(.body.weight(.semibold))
                        Spacer()
                        Text(folder.paused ? "Paused" : "Watching")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(folder.paused ? .secondary : .green)
                    }
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(folder.collection)
                        .font(.caption)
                    HStack {
                        Button(folder.paused ? "Resume" : "Pause") { onTogglePause(folder.id) }
                        Toggle("Delete removed files", isOn: Binding(
                            get: { folder.deleteRemoved },
                            set: { _ in onToggleDelete(folder.id) }
                        ))
                        .toggleStyle(.checkbox)
                        Spacer()
                        Button("Remove") { onRemove(folder.id) }
                    }
                    .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Add folder", action: onAdd)
                Button("Scan now", action: onScan)
                    .disabled(folders.allSatisfy(\.paused))
            }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

nonisolated enum WatchedFolderFiles {
    static func list(directory: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return names.filter { FolderSync.isDocument($0.path) }
    }

    static func file(at url: URL, doi: String = "") -> WatchedFile? {
        guard FolderSync.isDocument(url.path), FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return WatchedFile(
            path: url.path,
            contentHash: RunHistory.contentHash(ofFile: url),
            modified: values?.contentModificationDate ?? Date(),
            doi: doi
        )
    }
}
