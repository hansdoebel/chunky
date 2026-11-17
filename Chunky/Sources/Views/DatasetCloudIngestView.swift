import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatasetCloudIngestPanel: View {
    var dataset: String
    var rows: Int
    var snapshotBytes: Int
    var target: String
    var provider: String
    var model: String
    @Binding var field: String
    @Binding var preembedded: Bool
    @Binding var chunkBytes: Int
    @Binding var tier: DatasetCloudTier
    @Binding var ramGB: String
    @Binding var diskGB: String
    var running: Bool
    var estimate: DatasetCloudEstimate?
    var status: String
    var available: DatasetCloudBudget? = nil
    var onChoose: () -> Void = {}
    var onPrepare: () -> Void = {}
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onSave: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dataset → Qdrant Cloud").font(.title2.bold())
            Text("Stream a verified downloaded text dataset into a new, isolated Cloud collection using your configured embedding model.").foregroundStyle(.secondary)
            Button("Choose downloaded dataset…", action: onChoose).disabled(running)
            if !dataset.isEmpty {
                Text(dataset).font(.headline)
                Text("\(rows) source rows · \(bytes(Double(snapshotBytes))) local JSONL")
            }
            Toggle("Use curated pre-embedded vectors", isOn: $preembedded).disabled(running)
            if preembedded {
                Text("Requires the pinned Qdrant DBpedia profile: text-embedding-3-small / 1536 dimensions, exact vector column and a compatible query gateway that confirms its model. Original rows are not rechunked or re-embedded.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Profile text field", value: "combined_text")
                Text("Vector field: text-embedding-3-small-1536-embedding").font(.caption.monospaced())
            } else {
                TextField("Text field", text: $field).disabled(running)
                Picker("Chunk size", selection: $chunkBytes) {
                    Text("512 UTF-8 bytes").tag(512)
                    Text("2,048 UTF-8 bytes").tag(2048)
                    Text("8,192 UTF-8 bytes").tag(8192)
                }.disabled(running)
                Text("Long text is split at UTF-8 boundaries without overlap or truncation. Every chunk records its original row and byte offset. Missing or blank text stops the import.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Embedding provider / model", value: "\(provider) / \(model)")
            LabeledContent("Cloud endpoint", value: target)
            Picker("Cloud plan (choose explicitly)", selection: $tier) {
                ForEach(DatasetCloudTier.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(running)
            TextField("Available RAM on least-free node (GB)", text: $ramGB).disabled(running)
            TextField("Available disk on least-free node (GB)", text: $diskGB).disabled(running)
            Text("Use current available capacity from the Cloud Console, not total cluster size. GB = 1,000,000,000 bytes. Free: at most 1 GB RAM / 4 GB disk. Paid capacity depends on your provisioned resources.").font(.caption).foregroundStyle(.secondary)
            Button("Prepare import plan", action: onPrepare).disabled(running || dataset.isEmpty || (!preembedded && field.isEmpty))
            if let estimate {
                Divider()
                Text("Review before creating a collection").font(.headline)
                Text("\(estimate.points) chunks · \(estimate.dimensions) dimensions")
                LabeledContent("Estimated incremental RAM", value: bytes(estimate.ram))
                LabeledContent("Estimated persistent disk", value: bytes(estimate.persistentDisk))
                LabeledContent("Disk budget including temporary reserve", value: bytes(estimate.disk))
                if let available {
                    LabeledContent("Available RAM after headroom", value: bytes(available.ram))
                    LabeledContent("Available disk after headroom", value: bytes(available.disk))
                }
                Text("Conservative estimates include float32 originals, JSON payload, graph and ID overhead. Disk reserve doubles estimated storage plus 64 MiB; RAM includes cache and 64 MiB reserve. Live per-node metrics also retain 20% capacity headroom. This is not a guarantee of fit.").font(.caption).foregroundStyle(.secondary)
                Button("Create new collection and ingest", action: onStart).disabled(running)
            }
            if running { Button("Cancel", action: onCancel) }
            Text(status).textSelection(.enabled)
            if let onSave { Button("Save import report…", action: onSave) }
            Text("Existing collections, providers and worker settings stay unchanged. Cancellation, quota errors or failed requests may leave partial data; no automatic deletion or retry. Server byte safeguards are approximate, not hard disk-volume limits.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceGrouped)
    }

    private func bytes(_ value: Double) -> String {
        if value >= 1024 * 1024 * 1024 { return String(format: "%.2f GiB", value / (1024 * 1024 * 1024)) }
        if value >= 1024 * 1024 { return String(format: "%.2f MiB", value / (1024 * 1024)) }
        return String(format: "%.2f KiB", value / 1024)
    }
}

struct DatasetCloudIngestView: View {
    @EnvironmentObject var appState: AppState
    @State private var snapshot: DatasetValidatedSnapshot?
    @State private var field = "text"
    @State private var preembedded = false
    @State private var chunkBytes = 2048
    @State private var tier = DatasetCloudTier.free
    @State private var ramGB = ""
    @State private var diskGB = ""
    @State private var importing = false
    @State private var status = "Download a dataset in the Datasets window, then select its folder."
    @State private var plan: DatasetCloudPlan?
    @State private var preparedSettings: [String] = []
    @State private var result: DatasetCloudResult?
    @State private var task: Task<Void, Never>?
    @State private var accessURL: URL?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            panel
        }
        .frame(minWidth: 740, minHeight: 760)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { selection in
            do { load(try selection.get()) } catch { status = error.localizedDescription }
        }
        .onChange(of: planInputs) { _, _ in plan = nil }
        .onDisappear { task?.cancel(); accessURL?.stopAccessingSecurityScopedResource(); accessURL = nil }
    }

    private var panel: DatasetCloudIngestPanel {
        DatasetCloudIngestPanel(
            dataset: snapshot?.manifest.datasetID ?? "", rows: snapshot?.manifest.rowCount ?? 0,
            snapshotBytes: snapshot?.byteCount ?? 0,
            target: URL(string: appState.settings.qdrantCloudURL)?.host ?? "Configure Cloud in Preferences",
            provider: appState.settings.embeddingBackend, model: appState.settings.embeddingModel,
            field: $field, preembedded: $preembedded, chunkBytes: $chunkBytes, tier: $tier,
            ramGB: $ramGB, diskGB: $diskGB, running: task != nil, estimate: plan?.estimate,
            status: status, available: plan?.available, onChoose: { importing = true },
            onPrepare: { prepare() }, onStart: { start() }, onCancel: { task?.cancel() }, onSave: saveAction
        )
    }

    private var saveAction: (() -> Void)? {
        guard result != nil else { return nil }
        return { save() }
    }

    private var planInputs: [String] {
        [field, String(preembedded), String(chunkBytes), tier.rawValue, ramGB, diskGB] + settingsIdentity
    }

    private func load(_ url: URL) {
        guard task == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        plan = nil
        result = nil
        status = "Verifying complete snapshot hash and bounded rows…"
        task = Task { @MainActor in
            var transferred = false
            defer { if scoped && !transferred { url.stopAccessingSecurityScopedResource() }; task = nil }
            do {
                let value = try await DatasetStreamSnapshot.validate(from: url)
                try Task.checkCancellation()
                accessURL?.stopAccessingSecurityScopedResource()
                accessURL = scoped ? url : nil
                transferred = true
                snapshot = value
                status = "Snapshot verified. Select the text field and enter current available Cloud capacity."
            } catch { status = error is CancellationError ? "Cancelled." : error.localizedDescription }
        }
    }

    private var settingsIdentity: [String] {
        let settings = appState.settings
        return [settings.embeddingBackend, settings.embeddingModel, settings.ollamaURL, settings.embeddingAPIURL, settings.qdrantCloudURL, settings.qdrantAPIKey]
    }

    private func operations(settings: [String], tier: DatasetCloudTier, profile: DatasetCloudEmbeddingProfile? = nil) -> DatasetCloudOperations {
        let provider = LocalEmbeddingService(backend: settings[0], ollamaURL: settings[2], apiURL: settings[3])
        let cloud = DatasetCloudQdrant(baseURL: settings[4], apiKey: settings[5], tier: tier)
        return DatasetCloudOperations(embed: { texts, query in
            if settings[0] == "ollama" { return try await OllamaService(baseURL: settings[2]).embedBatch(texts: texts, model: settings[1], truncate: false) }
            if settings[0] == "fastembed" { return try await FastEmbedService.shared.embed(texts: texts, model: settings[1], query: query, rejectTruncation: true) }
            if query { return [try await LiveRetrievalEmbedding().embed(text: texts[0], backend: settings[0], model: settings[1], ollamaURL: settings[2], apiURL: settings[3])] }
            return try await provider.embedBatch(texts: texts, model: settings[1])
        }, capacity: { try await cloud.capacity() }, create: { name, estimate in
            guard settings == settingsIdentity else { throw DatasetBenchmarkError.invalid("Connection or embedding settings changed. Prepare a new import plan.") }
            try await cloud.create(name: name, estimate: estimate)
        }, verify: { name, estimate in
            try await cloud.verify(name: name, estimate: estimate)
            if let profile { try DatasetCloudCollectionIdentity.register(collection: name, profile: profile, defaults: appState.settings.defaults) }
            try DatasetCloudRunner.recordVerifiedCollection(name: name, estimate: estimate, backend: settings[0], model: settings[1], defaults: appState.settings.defaults)
        }, write: { name, points in try await cloud.write(name: name, points: points) }, preembeddedQuery: { profile, text in
            try await DatasetCloudPreembeddedQuery.embed(profile: profile, endpoint: settings[3], text: text)
        })
    }

    private func prepare() {
        guard task == nil, !appState.isProcessing, let snapshot else { status = "Select a dataset and wait for current processing to finish."; return }
        let settings = settingsIdentity
        let budget = DatasetCloudBudget(tier: tier, ram: (Double(ramGB) ?? 0) * 1e9, disk: (Double(diskGB) ?? 0) * 1e9)
        let selectedField = field
        let selectedChunkBytes = chunkBytes
        let selectedPreembedded = preembedded
        let operations = operations(settings: settings, tier: tier)
        plan = nil
        result = nil
        status = "Planning every source row and chunk, then checking encoders and Cloud capacity…"
        begin()
        task = Task { @MainActor in
            defer { finish() }
            do {
                let prepared = try await DatasetCloudRunner.prepare(source: DatasetCloudSource(snapshot: snapshot), field: selectedField, chunkBytes: selectedChunkBytes, backend: settings[0], model: settings[1], budget: budget, preembedded: selectedPreembedded, operations: operations)
                try Task.checkCancellation()
                plan = prepared
                preparedSettings = settings
                status = "Plan fits the entered budget and current per-node metrics. Review estimates before starting. No collection has been created."
            } catch { status = error is CancellationError ? "Cancelled planning." : RunHistory.redact(error.localizedDescription, secrets: settings) }
        }
        appState.benchmarkTask = task
    }

    private func start() {
        guard task == nil, !appState.isProcessing, let plan else { return }
        guard preparedSettings == settingsIdentity else { self.plan = nil; status = "Connection or model settings changed. Prepare a new plan."; return }
        let settings = preparedSettings
        let operations = operations(settings: settings, tier: plan.budget.tier, profile: plan.profile)
        begin()
        task = Task { @MainActor in
            defer { finish() }
            var output = await DatasetCloudRunner.run(plan: plan, operations: operations) { count in status = "Cloud acknowledged \(count) of \(plan.estimate.points) chunks…" }
            output.message = RunHistory.redact(output.message, secrets: settings)
            result = output
            status = "\(output.message)\n\(output.acknowledgedPoints) / \(output.plannedPoints) acknowledged. " + (output.creationAttempted ? "Inspect \(output.collection); failed requests may have written additional points." : "No collection creation was attempted.")
            self.plan = nil
        }
        appState.benchmarkTask = task
    }

    private func begin() { appState.isProcessing = true; appState.resetCancellation() }
    private func finish() { appState.isProcessing = false; appState.resetCancellation(); appState.benchmarkTask = nil; task = nil }

    private func save() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dataset-cloud-import.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(result).write(to: url, options: .atomic) } catch { status = error.localizedDescription }
    }
}
