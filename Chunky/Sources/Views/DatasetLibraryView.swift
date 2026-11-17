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
    @Published var sampleSize = DatasetSampleSize.small
    @Published var streamSnapshot: DatasetStreamDownload?
    @Published var sizeInfo: DatasetSizeInfo?
    @Published var sampleEstimate: DatasetSampleEstimate?
    @Published var sizeStatus = "Size information has not been loaded."
    private var sizeOperation: Task<Void, Never>?
    private var sizeRequestID = UUID()
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
        clearSizes()
        selected = nil
        splits = []
        splitID = ""
        snapshot = nil
        streamSnapshot = nil
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

    func select(_ dataset: HuggingFaceDataset) { select(id: dataset.id) }

    func recommend(_ recommendation: DatasetRecommendation) {
        query = recommendation.datasetID
        results = []
        select(id: recommendation.datasetID, preferred: recommendation.split)
    }

    private func select(id: String, preferred: DatasetSplit? = nil) {
        clearSizes()
        selected = nil
        splits = []
        splitID = ""
        snapshot = nil
        streamSnapshot = nil
        perform {
            let details = try await self.service.details(id)
            let splits = try await self.service.splits(for: details)
            return {
                self.selected = details
                self.splits = splits
                self.splitID = preferred.map { wanted in splits.first { $0 == wanted }?.id ?? "" } ?? splits.first?.id ?? ""
                self.status = self.splitID.isEmpty ? "The requested configuration/split is unavailable. Choose an available split explicitly." : "Choose a split and row limit. Review the dataset license before use."
                self.refreshSizes()
            }
        }
    }

    var estimatedBytes: Int? { requestedRows.flatMap { sampleEstimate?.bytes(for: $0) } }

    static func byteLabel(_ count: Int) -> String {
        for (divisor, unit) in [(1_073_741_824, "GiB"), (1_048_576, "MiB"), (1_024, "KiB")] {
            if count >= divisor {
                return (Double(count) / Double(divisor)).formatted(.number.precision(.fractionLength(0...1))) + " " + unit
            }
        }
        return "\(count) bytes"
    }

    private func clearSizes() {
        sizeOperation?.cancel()
        sizeOperation = nil
        sizeRequestID = UUID()
        sizeInfo = nil
        sampleEstimate = nil
        sizeStatus = "Size information has not been loaded."
    }

    func refreshSizes() {
        clearSizes()
        guard let selected, let split = selectedSplit else { return }
        let token = sizeRequestID
        sizeStatus = "Loading source size and a preview of up to 20 rows…"
        sizeOperation = Task {
            let source: DatasetSizeInfo?
            let estimate: DatasetSampleEstimate?
            do { source = try await service.size(for: selected, split: split) }
            catch { source = nil }
            guard !Task.isCancelled, token == sizeRequestID else { return }
            do { estimate = try await service.estimate(for: selected, split: split) }
            catch { estimate = nil }
            guard !Task.isCancelled, token == sizeRequestID else { return }
            sizeInfo = source
            sampleEstimate = estimate
            sizeStatus = source == nil || estimate == nil ? "Some size metadata is unavailable or could not be verified. Downloads still enforce all limits." : "Sizes verified against the selected dataset revision."
            sizeOperation = nil
        }
    }

    func download() {
        guard let selected, let split = selectedSplit, folderAvailable else { return }
        let destination = folder
        snapshot = nil
        streamSnapshot = nil
        if let budget = sampleSize.byteBudget {
            perform {
                let token = self.requestID
                let snapshot = try await self.service.downloadStream(dataset: selected, split: split, byteBudget: budget, folder: destination) { rows, bytes in
                    guard token == self.requestID else { return }
                    self.status = "Downloading \(rows.formatted()) rows · \(Self.byteLabel(bytes)) / \(Self.byteLabel(budget)) JSONL…"
                }
                return {
                    self.streamSnapshot = snapshot
                    let route = snapshot.benchmarkCompatible ? "Within snapshot size limits; Benchmark also validates selected text rows." : "Use Cloud ingest; this exceeds the legacy benchmark's 50 MiB / 10,000-row limit."
                    self.status = "Saved \(snapshot.manifest.rowCount.formatted()) rows · \(Self.byteLabel(snapshot.byteCount)). Stop: \(snapshot.manifest.stopReason.rawValue). \(route)"
                }
            }
        } else if let count = requestedRows {
            perform {
                let snapshot = try await self.service.download(dataset: selected, split: split, rows: count, folder: destination)
                return {
                    self.snapshot = snapshot
                    self.status = "Saved \(snapshot.manifest.rowCount) of \(snapshot.manifest.totalRows) rows. This sample is not a measured benchmark or a relevance-labeled evaluation set."
                }
            }
        }
    }

    func cancel() {
        clearSizes()
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended dataset samples").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading) {
                        ForEach(DatasetRecommendation.wikipedia) { recommendation in
                            Button(recommendation.title) { state.recommend(recommendation) }
                        }
                    }
                    .disabled(state.busy)
                    Text("Wikipedia text or pre-embedded DBpedia · review each source’s license and attribution on its dataset card.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                            if selected.id == "Qdrant/dbpedia-entities-openai3-text-embedding-3-small-1536-100K" {
                                Text("Pre-embedded source: query with OpenAI text-embedding-3-small at 1536 dimensions through a compatible gateway. Cloud ingest verifies the pinned source and exact vector field; equal dimensions alone are insufficient. License is not declared in the source card.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Revision: \(selected.revision)").font(.caption.monospaced()).textSelection(.enabled)
                            Picker("Configuration / split", selection: Binding(get: { state.splitID }, set: { state.splitID = $0; state.refreshSizes() })) {
                                ForEach(state.splits) { split in Text(split.id).tag(split.id) }
                            }
                            .disabled(state.busy)
                            Picker("Sample size", selection: $state.sampleSize) {
                                ForEach(DatasetSampleSize.allCases) { size in Text(size.title).tag(size) }
                            }
                            .disabled(state.busy)
                            if state.sampleSize == .legacy {
                              HStack {
                                TextField("Maximum rows", text: $state.rowLimit).frame(width: 180)
                                    .disabled(state.busy)
                                Text("1–10,000 rows · first rows only · 50 MiB maximum").font(.caption).foregroundStyle(.secondary)
                            }
                              if state.requestedRows == nil { Text("Enter a whole number from 1 to 10,000.").foregroundStyle(.red) }
                            } else {
                                Text("Whole-row JSONL sample · up to 1,000,000 rows · stops before the selected byte budget. Full source is not downloaded.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let size = state.sizeInfo {
                                Text("Full split: \(size.sourceRows.formatted()) rows · \(DatasetLibraryState.byteLabel(size.parquetBytes)) compressed Parquet (not downloaded)")
                            } else { Text("Full split compressed size: unavailable") }
                            if state.sampleSize == .legacy, let bytes = state.estimatedBytes, let estimate = state.sampleEstimate {
                                Text("Sample JSONL estimate: ~\(DatasetLibraryState.byteLabel(bytes)) · based on first \(estimate.previewRows) rows")
                                if bytes > DatasetSnapshot.maximumBytes {
                                    Text("Estimate exceeds the 50 MiB snapshot limit. Choose fewer rows; an oversized download will fail without saving.").foregroundStyle(.orange)
                                }
                            } else if let budget = state.sampleSize.byteBudget {
                                Text("Download budget: up to \(DatasetLibraryState.byteLabel(budget)) JSONL. Actual size may be smaller; requires budget + 64 MiB free disk space.")
                                Text("Benchmark snapshot limits: 50 MiB / 10,000 rows. Selected text: up to 1,000 rows, 32 KiB each and 8 MiB total. Larger text uses Cloud ingest.").font(.caption).foregroundStyle(.secondary)
                            } else { Text("Sample JSONL size: unknown until downloaded") }
                            Text("Approximate disk size only; article lengths vary and network traffic includes metadata and response overhead. Cloud storage is checked separately during import; vectors and indexes need additional space.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(state.sizeStatus).font(.caption).foregroundStyle(.secondary)
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
                        .disabled(state.busy || state.selectedSplit == nil || (state.sampleSize == .legacy && state.requestedRows == nil) || !state.folderAvailable)
                    if state.busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: state.cancel)
                    }
                    if let directory = state.streamSnapshot?.directory ?? state.snapshot?.directory {
                        Button("Show saved snapshot") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
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
