import AppKit
import SwiftUI

struct CollectionSnapshotsPane: View {
    var collection: String
    var server: String
    var snapshots: [SnapshotRecord]
    var status: String
    var reminder: String = ""
    var scrolls: Bool = true
    var onCreate: () -> Void
    var onDownload: (String) -> Void
    var onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snapshots")
                .font(.headline)
            Text(collection.isEmpty ? "Choose a collection" : collection)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(server.isEmpty ? "Server URL is not set" : server)
                .font(.caption.weight(.semibold))
            snapshotRows
            HStack {
                Button("Create snapshot", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .disabled(collection.isEmpty)
                Button("Restore snapshot", action: onRestore)
                    .disabled(collection.isEmpty)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !reminder.isEmpty {
                Text(reminder)
                    .font(.callout)
                    .foregroundStyle(AppTheme.statusOrange)
            }
            Text("Qdrant Cloud may refuse a snapshot download. Local Docker supports create, download, and restore. Restore asks before it overwrites the collection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var snapshotRows: some View {
        if scrolls {
            ScrollView { rowStack }
        } else {
            rowStack
        }
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshots.isEmpty {
                Text("No snapshots yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name)
                                .font(.body)
                            Text(snapshot.creationTime.isEmpty ? "\(snapshot.size) bytes" : snapshot.creationTime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") { onDownload(snapshot.name) }
                    }
                }
            }
        }
    }
}

struct CollectionSnapshotsScreen: View {
    @EnvironmentObject private var appState: AppState
    var onRestored: () -> Void = {}
    @State private var snapshots: [SnapshotRecord] = []
    @State private var status = "Create a snapshot, download it, or restore one into this collection."
    @State private var restoreFile: URL?
    @State private var showConfirm = false
    private let client = CollectionSnapshotClient(transport: LiveSnapshotTransport())

    var body: some View {
        CollectionSnapshotsPane(
            collection: appState.settings.defaultCollection,
            server: CollectionSnapshots.endpoint(settings: appState.settings).url,
            snapshots: snapshots,
            status: status,
            reminder: SnapshotReminder.message(records: snapshots, now: Date()),
            onCreate: { Task { await create() } },
            onDownload: { name in download(name) },
            onRestore: { chooseRestore() }
        )
        .frame(width: 520, height: 360)
        .task { await reload() }
        .alert("Restore snapshot?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) { restoreFile = nil }
            Button("Replace collection", role: .destructive) { Task { await restore() } }
        } message: {
            Text(CollectionSnapshots.confirmOverwrite(collection: appState.settings.defaultCollection, server: CollectionSnapshots.endpoint(settings: appState.settings).url))
        }
    }

    private func reload() async {
        let endpoint = CollectionSnapshots.endpoint(settings: appState.settings)
        let collection = appState.settings.defaultCollection
        guard !collection.isEmpty else { return }
        do {
            snapshots = try await client.list(baseURL: endpoint.url, apiKey: endpoint.apiKey, collection: collection)
            appState.settings.noteQdrantSuccess()
        } catch {
            status = error.localizedDescription
        }
    }

    private func create() async {
        let endpoint = CollectionSnapshots.endpoint(settings: appState.settings)
        let collection = appState.settings.defaultCollection
        do {
            let created = try await client.create(baseURL: endpoint.url, apiKey: endpoint.apiKey, collection: collection)
            status = "Created \(created.name)"
            await reload()
        } catch {
            status = error.localizedDescription
        }
    }

    private func download(_ name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let endpoint = CollectionSnapshots.endpoint(settings: appState.settings)
        let collection = appState.settings.defaultCollection
        Task {
            do {
                try await client.download(baseURL: endpoint.url, apiKey: endpoint.apiKey, collection: collection, snapshot: name, to: destination)
                status = "Saved \(name)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        restoreFile = file
        showConfirm = true
    }

    private func restore() async {
        guard let file = restoreFile else { return }
        let endpoint = CollectionSnapshots.endpoint(settings: appState.settings)
        let collection = appState.settings.defaultCollection
        do {
            try await client.restore(baseURL: endpoint.url, apiKey: endpoint.apiKey, collection: collection, file: file)
            status = "Restored \(file.lastPathComponent) into \(collection) on \(endpoint.url)"
            onRestored()
            await appState.fetchCollections()
            await appState.loadBrowserPoints()
        } catch {
            status = error.localizedDescription
        }
        restoreFile = nil
    }
}
