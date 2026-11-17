import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatasetBenchmarkPanel: View {
    var dataset: String
    var revision: String
    var availableRows: Int
    var fields: [String]
    @Binding var field: String
    @Binding var rowLimit: Int
    @Binding var seed: Bool
    var provider: String
    var model: String
    var target: String
    var running: Bool
    var status: String
    var report: DatasetBenchmarkReport?
    var onChoose: () -> Void = {}
    var onRun: () -> Void = {}
    var onCancel: () -> Void = {}
    var onSave: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dataset benchmark").font(.title2.weight(.semibold))
            Text("Use a downloaded Hugging Face snapshot to measure embedding throughput or fill a separate Qdrant test collection with real embeddings.")
                .foregroundStyle(.secondary)
            Button("Choose downloaded dataset…", action: onChoose).disabled(running)
            Text(dataset.isEmpty ? "Download a snapshot in the Datasets window, then choose its folder." : dataset).font(.headline)
            if !revision.isEmpty {
                Text("Revision: \(revision)").font(.caption.monospaced()).textSelection(.enabled)
                Text("\(availableRows) rows in snapshot").font(.caption)
            }
            Picker("Text field", selection: $field) {
                Text("Choose a field").tag("")
                ForEach(fields, id: \.self) { Text($0).tag($0) }
            }.disabled(running || fields.isEmpty)
            Stepper("First \(rowLimit) rows", value: $rowLimit, in: 1...1000).disabled(running)
            Text("At most 1,000 rows, 32 KiB per row and 8 MiB selected text. Rows are embedded as stored; no PDF conversion or text truncation.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            LabeledContent("Configured provider", value: provider)
            LabeledContent("Configured model", value: model)
            Text("Uses the current embedding settings from this Mac. One document/query warm-up precedes the measured document pass. Server-side caches may still be warm.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Also fill a new Qdrant test collection", isOn: $seed).disabled(running)
            if seed {
                Text("Target: \(target)").font(.callout)
                Text("Creates a unique chunky-dataset-test collection. Existing collections and settings stay unchanged. Cancelled or failed runs may leave a partial test collection for inspection; nothing is automatically deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(seed ? "Benchmark and fill test collection" : "Run embedding benchmark", action: onRun)
                    .disabled(running || dataset.isEmpty || field.isEmpty)
                if running { Button("Cancel", action: onCancel) }
            }
            Text(status).font(.callout).textSelection(.enabled)
            if let report {
                Divider()
                Text("Measured result").font(.headline)
                Text("\(report.rows) rows · \(report.dimensions) dimensions")
                Text(String(format: "Warm-up %.3f s · Embedding %.3f s · %.2f rows/s", report.warmupSeconds, report.embeddingSeconds, report.rowsPerSecond))
                if let seconds = report.indexingSeconds { Text(String(format: "Collection creation and indexing %.3f s", seconds)) }
                if let collection = report.collection { Text(collection).font(.caption.monospaced()).textSelection(.enabled) }
                Text("Throughput measurement only. No relevance labels or retrieval-quality scores are inferred.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save measured report…", action: onSave)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceGrouped)
    }
}

struct DatasetBenchmarkScreen: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: DatasetSnapshot?
    @State private var fields: [String] = []
    @State private var field = ""
    @State private var rowLimit = 100
    @State private var seed = false
    @State private var importing = false
    @State private var status = "Ready"
    @State private var report: DatasetBenchmarkReport?
    @State private var task: Task<Void, Never>?
    @State private var accessURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                DatasetBenchmarkPanel(dataset: snapshot?.manifest.datasetID ?? "", revision: snapshot?.manifest.revision ?? "", availableRows: snapshot?.manifest.rowCount ?? 0, fields: fields, field: $field, rowLimit: $rowLimit, seed: $seed, provider: appState.settings.embeddingBackend, model: appState.settings.embeddingModel, target: targetDescription, running: task != nil, status: status, report: report, onChoose: { importing = true }, onRun: run, onCancel: { task?.cancel() }, onSave: save)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.disabled(task != nil) }.padding()
        }
        .frame(width: 720, height: 760)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            do { importSnapshot(try result.get()) }
            catch { status = error.localizedDescription }
        }
        .interactiveDismissDisabled(task != nil)
        .onDisappear {
            task?.cancel()
            accessURL?.stopAccessingSecurityScopedResource()
            accessURL = nil
        }
    }

    private func importSnapshot(_ url: URL) {
        guard task == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        status = "Checking snapshot and text fields…"
        task = Task { @MainActor in
            var transferredAccess = false
            defer {
                if scoped && !transferredAccess { url.stopAccessingSecurityScopedResource() }
                task = nil
            }
            do {
                let (loaded, choices) = try await DatasetBenchmarkLoader.inspect(url)
                try Task.checkCancellation()
                accessURL?.stopAccessingSecurityScopedResource()
                accessURL = scoped ? url : nil
                transferredAccess = true
                snapshot = loaded
                fields = choices
                field = ""
                rowLimit = min(100, loaded.manifest.rowCount)
                report = nil
                status = "Choose a text field. Dataset hash and revision metadata were validated."
            } catch {
                status = error is CancellationError ? "Cancelled snapshot loading." : error.localizedDescription
            }
        }
    }

    private var targetDescription: String {
        guard let url = URL(string: appState.settings.qdrantURL), let host = url.host else { return "Configure Qdrant in Preferences" }
        return host + ":" + String(url.port ?? 6334)
    }

    private func run() {
        guard task == nil, !appState.isProcessing, let snapshot else {
            status = "Wait for the current run to finish and select a dataset."
            return
        }
        let selectedField = field
        let selectedLimit = rowLimit
        let settings = appState.settings
        let backend = settings.embeddingBackend
        let model = settings.embeddingModel
        let ollamaURL = settings.ollamaURL
        let apiURL = settings.embeddingAPIURL
        let qdrantURL = settings.qdrantURL
        let key = settings.qdrantAPIKey
        let timeout = settings.qdrantTimeout
        let production = settings.defaultCollection
        let defaults = settings.defaults
        let collection = seed ? DatasetBenchmarkSafety.collectionName() : nil
        let provider = LocalEmbeddingService(backend: backend, ollamaURL: ollamaURL, apiURL: apiURL)
        let database = QdrantService()
        let operations = DatasetBenchmarkOperations(embed: { texts, query in
            if query {
                return [try await LiveRetrievalEmbedding().embed(text: texts[0], backend: backend, model: model, ollamaURL: ollamaURL, apiURL: apiURL)]
            }
            return try await provider.embedBatch(texts: texts, model: model)
        }, create: { name, dimensions in
            try await database.configure(url: qdrantURL, apiKey: key.isEmpty ? nil : key)
            try await database.connect(timeout: timeout)
            try await database.createDatasetTestCollection(name: name, vectorSize: dimensions, productionCollection: production)
        }, verify: { name, dimensions in
            let info = try await database.getCollectionInfo(name)
            guard info.vectorSize == dimensions, info.vectorName == nil else {
                throw DatasetBenchmarkError.invalid("The new collection has incompatible vector dimensions or names. Refusing to upload.")
            }
            let plan = CollectionPlan.preset(.smallFastLocal, name: name, vectorSize: dimensions, embeddingBackend: backend, embeddingModel: model)
            CollectionPlanStore.save(plan, defaults: defaults)
        }, write: { name, points in
            try await database.upsertPoints(collectionName: name, points: points, batchSize: 32)
        })
        appState.isProcessing = true
        appState.resetCancellation()
        report = nil
        task = Task { @MainActor in
            do {
                status = "Checking selected dataset rows…"
                let corpus = try await DatasetBenchmarkLoader.corpus(snapshot: snapshot, field: selectedField, limit: selectedLimit)
                try Task.checkCancellation()
                report = try await DatasetBenchmarkRunner.run(corpus: corpus, backend: backend, model: model, collection: collection, production: production, operations: operations) { status = $0 }
                status = "Completed. Original collection and model settings are unchanged."
            } catch {
                let reason = error is CancellationError ? "Cancelled." : RunHistory.redact(error.localizedDescription, secrets: [key, qdrantURL, apiURL, ollamaURL])
                status = reason + (collection.map { " Inspect \($0) if it was created; partial test data is preserved." } ?? " No Qdrant collection was requested.")
            }
            await database.disconnect()
            appState.isProcessing = false
            appState.resetCancellation()
            appState.benchmarkTask = nil
            task = nil
        }
        appState.benchmarkTask = task
    }

    private func save() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dataset-benchmark.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: .atomic)
            status = "Saved measured report."
        } catch { status = error.localizedDescription }
    }
}
