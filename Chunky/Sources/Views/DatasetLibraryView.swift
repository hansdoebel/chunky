import AppKit
import Combine
import SwiftUI

@MainActor
final class DatasetLibraryState: ObservableObject {
    @Published var query = "BeIR/scifact"
    @Published var results: [HuggingFaceDataset] = []
    @Published var selected: HuggingFaceDataset?
    @Published var splits: [DatasetSplit] = []
    @Published var splitID = ""
    @Published var rowLimit = "100"
    @Published var folder: URL
    @Published var status = "Search public Hugging Face datasets to download a reproducible local sample."
    @Published var busy = false
    @Published var snapshot: DatasetSnapshot?
    @Published var folderAvailable = true
    private var operation: Task<Void, Never>?
    private var requestID = UUID()
    private let service: HuggingFaceDatasetService
    private let folders: DatasetFolderStore

    init(service: HuggingFaceDatasetService = HuggingFaceDatasetService(), folders: DatasetFolderStore = DatasetFolderStore()) {
        self.service = service
        self.folders = folders
        self.folder = folders.defaultFolder
        do { folder = try folders.folder() }
        catch {
            folderAvailable = false
            status = "The saved folder is unavailable. Choose a folder or use the default before downloading."
        }
    }

    var selectedSplit: DatasetSplit? { splits.first { $0.id == splitID } }
    var requestedRows: Int? {
        guard let count = Int(rowLimit), (1...DatasetSnapshot.maximumRows).contains(count) else { return nil }
        return count
    }

    func search() {
        selected = nil
        splits = []
        splitID = ""
        snapshot = nil
        results = []
        let query = query
        perform {
            let results = try await self.service.search(query)
            return {
                self.results = results
                self.status = results.isEmpty ? "No public datasets found. Try a repository name or topic." : "Choose a dataset to inspect its available configurations and splits."
            }
        }
    }

    func select(_ dataset: HuggingFaceDataset) {
        selected = nil
        splits = []
        splitID = ""
        snapshot = nil
        perform {
            let details = try await self.service.details(dataset.id)
            let splits = try await self.service.splits(for: details)
            return {
                self.selected = details
                self.splits = splits
                self.splitID = splits.first?.id ?? ""
                self.status = splits.isEmpty ? "No Dataset Viewer splits are available for this dataset." : "Choose a split and row limit. Review the dataset license before use."
            }
        }
    }

    func download() {
        guard let selected, let split = selectedSplit, let count = requestedRows, folderAvailable else { return }
        let destination = folder
        snapshot = nil
        perform {
            let snapshot = try await self.service.download(dataset: selected, split: split, rows: count, folder: destination)
            return {
                self.snapshot = snapshot
                self.status = "Saved \(snapshot.manifest.rowCount) of \(snapshot.manifest.totalRows) rows. This sample is not a measured benchmark or a relevance-labeled evaluation set."
            }
        }
    }

    func cancel() {
        requestID = UUID()
        operation?.cancel()
        operation = nil
        busy = false
        status = "Cancelled. Incomplete downloads are not saved."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use dataset folder"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            try folders.setFolder(selected)
            folder = selected
            folderAvailable = true
            status = "Default dataset folder updated. Existing snapshots stay where they are."
        } catch { status = error.localizedDescription }
    }

    func resetFolder() {
        folders.reset()
        folder = folders.defaultFolder
        folderAvailable = true
        status = "Using Downloads/Chunky Datasets for future snapshots."
    }

    private func perform(_ action: @escaping @MainActor () async throws -> (@MainActor () -> Void)) {
        operation?.cancel()
        let token = UUID()
        requestID = token
        busy = true
        status = "Loading…"
        operation = Task {
            defer { if token == self.requestID { self.busy = false; self.operation = nil } }
            do {
                let apply = try await action()
                try Task.checkCancellation()
                guard token == self.requestID else { return }
                apply()
            } catch {
                guard token == self.requestID else { return }
                self.status = error is CancellationError ? "Cancelled." : error.localizedDescription
            }
        }
    }
}

struct DatasetLibraryView: View {
    @StateObject private var state = DatasetLibraryState()

    var body: some View {
        DatasetLibraryPane(state: state)
            .onDisappear { state.cancel() }
    }
}

struct DatasetLibraryPane: View {
    @ObservedObject var state: DatasetLibraryState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Hugging Face datasets", systemImage: "externaldrive.badge.plus")
                    .font(.title2.weight(.semibold))
                Text("Find public datasets and save a bounded, revision-checked JSONL sample for benchmarking or test collections.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Dataset name or topic", text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !state.busy { state.search() } }
                    Button("Search", action: state.search).disabled(state.busy || state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(state.busy)
                if !state.results.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search results · up to 30").font(.headline)
                        ForEach(state.results) { dataset in
                            HStack {
                                Button(dataset.id) { state.select(dataset) }
                                    .disabled(state.busy || dataset.restricted)
                                Spacer()
                                Text(dataset.restricted ? "Private or gated" : "\(dataset.downloads) downloads").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let selected = state.selected {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(selected.id).font(.headline)
                                Spacer()
                                Link("Dataset card", destination: selected.cardURL)
                            }
                            Text("License: \(selected.license ?? "Not reported — review the dataset card")")
                            Text("Revision: \(selected.revision)").font(.caption.monospaced()).textSelection(.enabled)
                            Picker("Configuration / split", selection: $state.splitID) {
                                ForEach(state.splits) { split in Text(split.id).tag(split.id) }
                            }
                            .disabled(state.busy)
                            HStack {
                                TextField("Maximum rows", text: $state.rowLimit).frame(width: 180)
                                    .disabled(state.busy)
                                Text("1–10,000 rows · first rows only · 50 MiB maximum").font(.caption).foregroundStyle(.secondary)
                            }
                            if state.requestedRows == nil { Text("Enter a whole number from 1 to 10,000.").foregroundStyle(.red) }
                        }
                        .padding(8)
                    }
                }
                GroupBox("Save snapshots") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.folder.path).font(.callout).textSelection(.enabled)
                        HStack {
                            Button("Choose folder…", action: state.chooseFolder)
                            Button("Use default folder", action: state.resetFolder)
                        }
                        .disabled(state.busy)
                        Text("The chosen folder is remembered. Each download creates a new snapshot folder; existing files are never replaced.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                HStack {
                    Button("Download sample", action: state.download)
                        .disabled(state.busy || state.selectedSplit == nil || state.requestedRows == nil || !state.folderAvailable)
                    if state.busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: state.cancel)
                    }
                    if let snapshot = state.snapshot {
                        Button("Show saved snapshot") { NSWorkspace.shared.activateFileViewerSelecting([snapshot.directory]) }
                    }
                }
                Text(state.status).font(.callout).accessibilityIdentifier("dataset-status")
                Text("Public Dataset Viewer support is required. Downloads do not execute dataset scripts, fetch linked media, or write to Qdrant. First-row samples are not representative benchmark scores; keep source licenses and relevance labels when preparing an evaluation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 700, minHeight: 600)
        .background(AppTheme.surfaceGrouped)
    }
}
