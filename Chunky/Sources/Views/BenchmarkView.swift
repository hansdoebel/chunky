import SwiftUI

struct BenchmarkView: View {
    var hosts: [ProcessingHost]
    var runtimes: [BenchmarkRuntime]
    var samples: [BenchmarkSample]
    var selectedHosts: Set<String>
    var selectedRuntimes: Set<String>
    var productionCollection: String
    var collectionName: String
    var status: String
    var scrolls: Bool = true
    var onToggleHost: (ProcessingHost) -> Void = { _ in }
    var onToggleRuntime: (BenchmarkRuntime) -> Void = { _ in }
    var onRun: () -> Void = {}

    private var planned: [BenchmarkCell] {
        let chosenHosts = hosts.filter { selectedHosts.contains($0.rawValue) }
        let chosenRuntimes = runtimes.filter { selectedRuntimes.contains($0.id) }
        return BenchmarkPlanner.cells(hosts: chosenHosts, runtimes: chosenRuntimes, samples: samples)
    }

    private var timedCount: Int { planned.filter { $0.phase == .timed }.count }

    var body: some View {
        fitted {
            VStack(alignment: .leading, spacing: 16) {
                Text("Benchmark")
                    .font(.title2.weight(.semibold))
                Text("Warm-up, then a timed pass. Results go to Analytics. The run writes \(collectionName), not \(productionCollection).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(BenchmarkPlanner.accepts(collection: collectionName, production: productionCollection)
                     ? "Throwaway collection"
                     : "Refusing the production collection")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BenchmarkPlanner.accepts(collection: collectionName, production: productionCollection) ? Color.secondary : Color.red)

                Text("Hosts")
                    .font(.headline)
                ForEach(hosts) { host in
                    toggleRow(title: host.rawValue, on: selectedHosts.contains(host.rawValue)) {
                        onToggleHost(host)
                    }
                }

                Text("Runtimes")
                    .font(.headline)
                ForEach(runtimes) { runtime in
                    toggleRow(
                        title: "\(runtime.label) · \(runtime.embeddingModel)",
                        on: selectedRuntimes.contains(runtime.id)
                    ) {
                        onToggleRuntime(runtime)
                    }
                }

                Text("Samples")
                    .font(.headline)
                ForEach(samples) { sample in
                    Text("\(sample.kind) · \(sample.filename)")
                        .font(.callout)
                }

                Text("\(timedCount) timed runs, \(planned.count - timedCount) warm-ups")
                    .font(.callout.monospacedDigit())
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Run benchmark", action: onRun)
                    .disabled(timedCount == 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.surfaceGrouped)
    }

    private func toggleRow(title: String, on: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder
    private func fitted<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if scrolls {
            ScrollView { content() }
        } else {
            content()
        }
    }
}

struct BenchmarkScreen: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var processor: DocumentProcessor
    @State private var selectedHosts: Set<String> = Set(ProcessingHost.allCases.map(\.rawValue))
    @State private var selectedRuntimes: Set<String> = []
    @State private var preparedRuntimes = false
    @State private var collectionName = ""
    @State private var status = "Idle"

    var body: some View {
        let runtimes = BenchmarkPlanner.offeredRuntimes(settings: appState.settings)
        BenchmarkView(
            hosts: ProcessingHost.allCases,
            runtimes: runtimes,
            samples: BenchmarkPlanner.samples,
            selectedHosts: selectedHosts,
            selectedRuntimes: selectedRuntimes,
            productionCollection: appState.settings.defaultCollection,
            collectionName: collectionName.isEmpty ? "chunky-benchmark-…" : collectionName,
            status: status,
            onToggleHost: { host in
                if selectedHosts.contains(host.rawValue) {
                    selectedHosts.remove(host.rawValue)
                } else {
                    selectedHosts.insert(host.rawValue)
                }
            },
            onToggleRuntime: { runtime in
                if selectedRuntimes.contains(runtime.id) {
                    selectedRuntimes.remove(runtime.id)
                } else {
                    selectedRuntimes.insert(runtime.id)
                }
            },
            onRun: { start(runtimes: runtimes) }
        )
        .disabled(appState.isProcessing)
        .onAppear {
            guard !preparedRuntimes else { return }
            selectedRuntimes = Set(runtimes.map(\.id))
            preparedRuntimes = true
        }
    }

    @MainActor
    private func start(runtimes: [BenchmarkRuntime]) {
        guard !appState.isProcessing else {
            status = "Wait for the current run to finish."
            return
        }
        appState.isProcessing = true
        appState.resetCancellation()
        appState.benchmarkTask = Task {
            await run(runtimes: runtimes)
            appState.isProcessing = false
            appState.benchmarkTask = nil
        }
    }

    @MainActor
    private func run(runtimes: [BenchmarkRuntime]) async {
        let chosenRuntimes = runtimes.filter { selectedRuntimes.contains($0.id) }
        let chosenHosts = ProcessingHost.allCases.filter { selectedHosts.contains($0.rawValue) }
        let cells = BenchmarkPlanner.cells(hosts: chosenHosts, runtimes: chosenRuntimes, samples: BenchmarkPlanner.samples)
        let collection = BenchmarkPlanner.collectionName(production: appState.settings.defaultCollection)
        guard BenchmarkPlanner.accepts(collection: collection, production: appState.settings.defaultCollection) else {
            status = "Refusing the production collection"
            return
        }
        collectionName = collection
        var completed = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        for (index, cell) in cells.enumerated() {
            if Task.isCancelled || appState.isCancellationRequested {
                cancelled = true
                skipped += cells.count - index
                break
            }
            status = "\(index + 1)/\(cells.count) \(cell.host.rawValue) \(cell.runtime.label) \(cell.sample.kind) \(cell.phase.label)"
            guard let url = BenchmarkPlanner.url(for: cell.sample) else {
                skipped += 1
                continue
            }
            let settings = appState.settings.benchmarkCopy(collection: collection, host: cell.host, runtime: cell.runtime)
            guard settings.defaultCollection == collection, !settings.enableEmbeddingCache else {
                skipped += 1
                continue
            }
            let job = ProcessingJob(url: url)
            job.fileName = "\(cell.sample.kind) \(cell.runtime.label) \(cell.phase.label)"
            job.analyticsRuntime = cell.runtime.label
            await processor.process(job: job, settings: settings, mode: .full)
            switch job.status {
            case .completed: completed += 1
            case .failed: failed += 1
            default: skipped += 1
            }
        }
        status = BenchmarkPlanner.summary(completed: completed, failed: failed, skipped: skipped, cancelled: cancelled)
        appState.reloadHistory()
    }
}
