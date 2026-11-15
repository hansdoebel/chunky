import Charts
import SwiftUI

struct RetrievalEvalView: View {
    var setName: String
    var queries: [RetrievalEvalQuery]
    var config: RetrievalEvalConfig
    var runs: [RetrievalEvalDraft]
    var status: String
    var warning: String?
    var scrolls: Bool
    @State private var metric: RetrievalEvalChartMetric

    init(
        setName: String,
        queries: [RetrievalEvalQuery],
        config: RetrievalEvalConfig,
        runs: [RetrievalEvalDraft],
        status: String = "",
        warning: String? = nil,
        metric: RetrievalEvalChartMetric = .recall,
        scrolls: Bool = true
    ) {
        self.setName = setName
        self.queries = queries
        self.config = config
        self.runs = runs
        self.status = status
        self.warning = warning
        self.scrolls = scrolls
        _metric = State(initialValue: metric)
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 16) {
            header
            queryList
            configLine
            comparison
            history
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Retrieval eval")
                .font(.title2.weight(.semibold))
            Text(setName)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var queryList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(queries.count) questions")
                .font(.headline)
            ForEach(queries.prefix(6)) { query in
                VStack(alignment: .leading, spacing: 2) {
                    Text(query.question)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    Text(expectation(query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var configLine: some View {
        Text(config.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.25), in: Capsule())
    }

    private var comparison: some View {
        let buckets = RetrievalEvalHistory.compare(runs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compare")
                    .font(.headline)
                ForEach(RetrievalEvalChartMetric.allCases) { item in
                    Text(item.rawValue)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(metric == item ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12), in: Capsule())
                        .onTapGesture { metric = item }
                }
            }
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Setup", bucket.label),
                    y: .value(metric.rawValue, metric.value(bucket))
                )
                .foregroundStyle(by: .value("Setup", bucket.label))
            }
            .chartLegend(.hidden)
            .chartYAxisLabel(metric.rawValue)
            .frame(height: 220)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History")
                .font(.headline)
            ForEach(runs.prefix(8)) { run in
                HStack {
                    Text(run.label)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "R %.2f  MRR %.2f  nDCG %.2f  hit %.2f  %.0f ms",
                                run.score.recallAtK, run.score.mrr, run.score.ndcgAtK, run.score.hitRate, run.score.latencyMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func expectation(_ query: RetrievalEvalQuery) -> String {
        if let source = query.sourceChunkID, !source.isEmpty {
            return "source \(source)"
        }
        if query.relevantIDs.isEmpty {
            return "unlabelled · judged at run time"
        }
        return query.relevantIDs.joined(separator: ", ")
    }
}

struct RetrievalEvalScreen: View {
    @EnvironmentObject private var appState: AppState
    @State private var setName = "manual"
    @State private var question = ""
    @State private var expected = ""
    @State private var synthetic = ""
    @State private var queries: [RetrievalEvalQuery] = []
    @State private var collection = "documents"
    @State private var hybrid = false
    @State private var reranker = false
    @State private var rerankURL = ""
    @State private var rerankModel = ""
    @State private var rerankAPIKey = ""
    @State private var k = 10
    @State private var status = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editor
            RetrievalEvalView(
                setName: setName,
                queries: queries,
                config: currentConfig,
                runs: appState.evalRuns,
                status: status,
                warning: appState.historyWarning
            )
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Set name", text: $setName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                TextField("Collection", text: $collection)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Stepper("k \(k)", value: $k, in: 1...RetrievalLimits.maximum)
                Toggle("Hybrid", isOn: $hybrid)
                    .toggleStyle(.switch)
                Toggle("Rerank", isOn: $reranker)
                    .toggleStyle(.switch)
                Button(running ? "Running" : "Run") {
                    Task { await run() }
                }
                .disabled(running || queries.isEmpty || collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                TextField("Question", text: $question)
                    .textFieldStyle(.roundedBorder)
                TextField("Expected point or document ids", text: $expected)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addQuestion() }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if reranker {
                HStack {
                    TextField("Rerank URL", text: $rerankURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Rerank model", text: $rerankModel)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Rerank API key", text: $rerankAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            TextField("Synthetic chunks, one per line: id<tab>text", text: $synthetic)
                .textFieldStyle(.roundedBorder)
            Button("Build synthetic set") { buildSynthetic() }
                .disabled(synthetic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding([.horizontal, .top], 20)
    }

    private var currentConfig: RetrievalEvalConfig {
        RetrievalEvalConfig(
            collection: collection.trimmingCharacters(in: .whitespacesAndNewlines),
            embeddingBackend: appState.settings.embeddingBackend,
            embeddingModel: appState.settings.embeddingModel,
            chunking: RetrievalEvalConfig.chunkingLabel(
                tokens: appState.settings.maxTokensPerChunk,
                overlap: appState.settings.chunkOverlap
            ),
            hybrid: hybrid,
            reranker: reranker,
            k: k,
            rrfWeights: nil,
            rerank: reranker ? RerankConfig(url: rerankURL, model: rerankModel, apiKey: rerankAPIKey) : nil
        )
    }

    private func addQuestion() {
        let ids = expected
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        queries.append(RetrievalEvalQuery(question: question.trimmingCharacters(in: .whitespacesAndNewlines), relevantIDs: ids))
        question = ""
        expected = ""
    }

    private func buildSynthetic() {
        let chunks: [(id: String, text: String)] = synthetic.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let text = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !text.isEmpty else { return nil }
            return (id, String(text))
        }
        guard !chunks.isEmpty else {
            status = "Synthetic lines need an id, a tab, and the chunk text."
            return
        }
        let built = RetrievalEvalSets.synthetic(name: setName, chunks: chunks)
        queries = built.queries
        status = "Built \(queries.count) questions from source chunk ids."
    }

    private func run() async {
        running = true
        defer { running = false }
        let config = currentConfig
        let set = RetrievalEvalSet(name: setName, queries: queries)
        let usesWorker = appState.settings.processingHost == .devbox && appState.settings.devboxIngestTarget == .qdrantCloud
        let index: (any RetrievalIndex)?
        do {
            if usesWorker {
                index = nil
            } else {
                try await appState.ensureQdrantConnection()
                guard let qdrant = appState.qdrantService else {
                    throw RetrievalError.notConnected
                }
                index = QdrantRetrievalIndex(service: qdrant)
            }
            let draft = try await RetrievalEvalRunner(service: RetrievalService()).run(
                set: set,
                config: config,
                settings: appState.settings,
                index: index
            )
            appState.storeEvalRun(draft)
            status = String(
                format: "Recall@%d %.3f · MRR %.3f · nDCG %.3f · hit %.3f · %.0f ms",
                draft.score.k, draft.score.recallAtK, draft.score.mrr, draft.score.ndcgAtK, draft.score.hitRate, draft.score.latencyMs
            )
        } catch {
            status = error.localizedDescription
        }
    }
}
