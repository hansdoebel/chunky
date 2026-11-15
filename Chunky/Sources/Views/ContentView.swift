import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processor = DocumentProcessor()

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            MainContentView(processor: processor)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            processor.appState = appState
            appState.reloadHistory()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        List {
            NavigationRow(
                icon: "tray.full", title: "Queue", isSelected: appState.viewMode == .queue
            )
            .onTapGesture { appState.viewMode = .queue }
            NavigationRow(
                icon: "square.stack.3d.up", title: "Collections",
                isSelected: appState.viewMode == .collections
            )
            .onTapGesture { appState.viewMode = .collections }
            NavigationRow(
                icon: "magnifyingglass", title: "Retrieval",
                isSelected: appState.viewMode == .retrieval
            )
            .onTapGesture { appState.viewMode = .retrieval }
            NavigationRow(
                icon: "checklist", title: "Eval",
                isSelected: appState.viewMode == .eval
            )
            .onTapGesture { appState.viewMode = .eval }
            NavigationRow(
                icon: "chart.bar", title: "Analytics",
                isSelected: appState.viewMode == .analytics
            )
            .onTapGesture { appState.viewMode = .analytics }
            NavigationRow(
                icon: "speedometer", title: "Benchmark",
                isSelected: appState.viewMode == .benchmark
            )
            .onTapGesture { appState.viewMode = .benchmark }
            NavigationRow(
                icon: "checkmark.seal", title: "Verification",
                isSelected: appState.viewMode == .verification
            )
            .onTapGesture { appState.viewMode = .verification }

            Section {
                HStack(spacing: 8) {
                    StatusDot(isActive: !appState.settings.ollamaURL.isEmpty, size: 8)
                    Text("Ollama")
                        .font(.system(size: 14))
                    Spacer()
                    Text(
                        appState.settings.embeddingModel.replacingOccurrences(
                            of: ":latest", with: "")
                    )
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .font(.system(size: 14))
                }

                HStack(spacing: 8) {
                    StatusDot(isActive: appState.settings.doclingModel != "standard", size: 8)
                    Text("VLM")
                        .font(.system(size: 14))
                    Spacer()
                    Text(vlmModelDisplayName)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .font(.system(size: 14))
                }

                HStack(spacing: 8) {
                    StatusDot(isActive: isQdrantConfigured, size: 8)
                    Text("Qdrant")
                        .font(.system(size: 14))
                    Spacer()
                    Text(appState.settings.defaultCollection)
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 14))
                }
            } header: {
                Text("Services")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                StatRow(label: "Total", value: appState.jobs.count)
                StatRow(label: "Completed", value: appState.completedJobs.count)
                StatRow(label: "Pending", value: appState.pendingJobs.count)
                if appState.failedJobs.count > 0 {
                    StatRow(label: "Failed", value: appState.failedJobs.count)
                }
            } header: {
                Text("Queue")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, maxWidth: 240)
    }

    private var isQdrantConfigured: Bool {
        !appState.settings.qdrantURL.isEmpty
    }

    private var vlmModelDisplayName: String {
        let model = appState.settings.doclingModel
        if model == "standard" {
            return "Off"
        }
        return model.replacingOccurrences(of: ":latest", with: "")
    }
}

struct NavigationRow: View {
    let icon: String
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.gray.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
}

struct StatRow: View {
    let label: String
    let value: Int
    var valueColor: Color = .secondary

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.system(size: 14, design: .rounded))
    }
}

struct MainContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var processor: DocumentProcessor
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.viewMode == .queue {
                if appState.jobs.isEmpty {
                    DropZoneEmptyView(isTargeted: $isTargeted)
                } else {
                    FileListView(processor: processor)
                }
            } else if appState.viewMode == .collections {
                CollectionBrowserView()
            } else if appState.viewMode == .retrieval {
                RetrievalScreen()
            } else if appState.viewMode == .eval {
                RetrievalEvalScreen()
            } else if appState.viewMode == .analytics {
                AnalyticsView(runs: appState.finishedRuns, warning: appState.historyWarning)
            } else if appState.viewMode == .verification {
                VerificationRoot(processor: processor)
            } else {
                BenchmarkScreen(processor: processor)
            }

            Divider()

            BottomBarView(processor: processor)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            appState.addFiles(urls)
        }
    }
}

struct DropZoneEmptyView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @Binding var isTargeted: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(isTargeted ? AppTheme.badgeBackgroundActive : AppTheme.badgeBackground)
                    .frame(width: 100, height: 100)
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(isTargeted ? AppTheme.accentFallback : .secondary)
            }

            VStack(spacing: 8) {
                Text("Drop Files Here")
                    .font(.title2)
                    .fontWeight(.medium)

                Text("PDF, Word, PowerPoint, Excel, HTML, Images, Markdown, AsciiDoc, CSV, XML, JSON")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                selectFiles()
            } label: {
                Text("Add Files...")
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.accentFallback)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(
                    isTargeted ? AppTheme.accentFallback.opacity(0.5) : AppTheme.borderSubtle
                )
                .padding()
        )
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType.pdf,
            UTType(filenameExtension: "docx")!,
            UTType(filenameExtension: "pptx")!,
            UTType(filenameExtension: "xlsx")!,
            UTType.html,
            UTType.png, UTType.jpeg, UTType.tiff, UTType.bmp, UTType.webP,
            UTType.json,
            UTType(filenameExtension: "md")!,
            UTType.commaSeparatedText,
            UTType(filenameExtension: "adoc")!,
            UTType(filenameExtension: "asciidoc")!,
            UTType.xml,
            UTType(filenameExtension: "xbrl")!,
        ]

        if panel.runModal() == .OK {
            appState.addFiles(panel.urls)
        }
    }
}

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var processor: DocumentProcessor
    @State private var isTargeted = false
    @State private var selectedJobID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(appState.jobs.count) file(s)")
                    .font(.headline)

                Spacer()

                Button {
                    selectFiles()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                if !appState.completedJobs.isEmpty {
                    Button("Clear Completed") {
                        appState.clearCompleted()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Clear All") {
                    appState.clearAll()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            List {
                ForEach(appState.jobs) { job in
                    FileRowView(
                        job: job,
                        isSelected: selectedJobID == job.id,
                        onRemove: {
                            appState.removeJob(job)
                        })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedJobID = selectedJobID == job.id ? nil : job.id
                    }
                }
                .onMove(perform: moveJobs)
            }
            .listStyle(.plain)

            if let job = appState.jobs.first(where: { $0.id == selectedJobID }),
               job.status == .completed || job.status == .failed {
                Divider()
                PostJobPanel(run: RunDraft.make(job: job, settings: appState.settings, contentHash: ""))
                    .padding(12)
            }
        }
        .background(isTargeted ? AppTheme.badgeBackgroundActive : Color.clear)
    }

    private func moveJobs(from source: IndexSet, to destination: Int) {
        appState.jobs.move(fromOffsets: source, toOffset: destination)
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType.pdf,
            UTType(filenameExtension: "docx")!,
            UTType(filenameExtension: "pptx")!,
            UTType(filenameExtension: "xlsx")!,
            UTType.html,
            UTType.png, UTType.jpeg, UTType.tiff, UTType.bmp, UTType.webP,
            UTType.json,
            UTType(filenameExtension: "md")!,
            UTType.commaSeparatedText,
            UTType(filenameExtension: "adoc")!,
            UTType(filenameExtension: "asciidoc")!,
            UTType.xml,
            UTType(filenameExtension: "xbrl")!,
        ]

        if panel.runModal() == .OK {
            appState.addFiles(panel.urls)
        }
    }
}

struct FileRowView: View {
    @ObservedObject var job: ProcessingJob
    @Environment(\.colorScheme) var colorScheme
    var isSelected: Bool = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconBackgroundColor)
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(jobTypeBadge)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.badgeBackground, in: Capsule())

                    if job.status == .pending {
                        Text("Ready")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if job.status == .completed {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(job.chunksCount) chunks")
                                .font(.caption)
                                .foregroundStyle(AppTheme.accentFallback)
                            if let timing = job.timingSummary {
                                Text(timing)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else if job.status == .failed {
                        Text(job.error ?? "Failed")
                            .font(.caption)
                            .foregroundStyle(AppTheme.statusRed)
                            .lineLimit(5)
                            .help(job.error ?? "Failed")
                    } else {
                        HStack(spacing: 8) {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                                .tint(AppTheme.accentFallback)
                                .frame(maxWidth: 120)
                            Text(job.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            if job.chunksCount > 0 && job.status != .pending {
                Text("\(job.embeddedCount)/\(job.chunksCount)")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var canRemove: Bool {
        job.status == .pending || job.status == .completed || job.status == .failed
    }

    private var jobTypeBadge: String {
        switch job.jobType {
        case .pdf:
            let ext = job.sourceURL.pathExtension.uppercased()
            return ext.isEmpty ? "DOC" : ext
        case .chunkedJSON: return "Chunks"
        case .embeddedJSON: return "Embedded"
        case .markdown: return "MD"
        }
    }

    private var iconName: String {
        switch job.status {
        case .pending: return "doc.fill"
        case .chunking: return "doc.text.magnifyingglass"
        case .embedding: return "brain"
        case .uploading: return "arrow.up.circle"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .pending: return .secondary
        case .chunking, .embedding, .uploading: return AppTheme.accentFallback
        case .completed: return AppTheme.statusGreen
        case .failed: return AppTheme.statusRed
        }
    }

    private var iconBackgroundColor: Color {
        switch job.status {
        case .pending: return AppTheme.badgeBackground
        case .chunking, .embedding, .uploading: return AppTheme.badgeBackgroundActive
        case .completed: return AppTheme.statusGreen.opacity(0.15)
        case .failed: return AppTheme.statusRed.opacity(0.15)
        }
    }
}

struct BottomBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var processor: DocumentProcessor
    @Environment(\.colorScheme) var colorScheme
    @State private var refreshTrigger = false
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            if appState.isProcessing {

                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Processing...")
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(.secondary)

                    if appState.isCancellationRequested {
                        Text("Stopping...")
                            .foregroundStyle(AppTheme.statusOrange)
                            .font(.caption)
                    }
                }

                Spacer()

                Button {
                    appState.requestCancellation()
                    processor.cancel()
                    processingTask?.cancel()
                    appState.benchmarkTask?.cancel()
                } label: {
                    Text("Stop")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.statusRed)
                .disabled(appState.isCancellationRequested)
            } else {

                statusBreadcrumbs

                Spacer()

                Button {
                    startProcessing()
                } label: {
                    Text(startButtonTitle)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .onAppear {
            Task { await appState.fetchCollections() }
        }
        .onReceive(appState.settings.objectWillChange) { _ in
            refreshTrigger.toggle()
        }
        .id(refreshTrigger)
    }

    @ViewBuilder
    private var statusBreadcrumbs: some View {
        HStack(spacing: 6) {
            BreadcrumbItem(
                icon: appState.processingMode == .full ? "arrow.triangle.2.circlepath" : "doc.text",
                text: appState.processingMode.rawValue
            )

            if appState.processingMode == .full {
                BreadcrumbSeparator()

                BreadcrumbItem(
                    icon: "network",
                    text: protocolType
                )

                BreadcrumbSeparator()

                BreadcrumbItem(
                    icon: "square.stack.3d.up",
                    text: appState.settings.defaultCollection
                )
            } else {
                BreadcrumbSeparator()

                BreadcrumbItem(
                    icon: "square.and.arrow.up",
                    text: exportFormatDisplayName
                )

                BreadcrumbSeparator()

                BreadcrumbItem(
                    icon: "folder",
                    text: outputFolderName
                )
            }
        }
    }

    private var exportFormatDisplayName: String {
        guard let format = ExportFormat(rawValue: appState.settings.exportFormat) else {
            return "None"
        }
        return format.displayName
    }

    private var outputFolderName: String {
        let path = appState.settings.exportFolder
        if path.isEmpty {
            return "Not set"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var protocolType: String {
        let url = appState.settings.qdrantURL
        if let urlComponents = URLComponents(string: url) {
            let port = urlComponents.port ?? 6334
            return port == 6334 ? "gRPC" : "REST"
        }
        return "gRPC"
    }

    private var startButtonTitle: String {
        "Start"
    }

    private var canStart: Bool {
        guard !appState.pendingJobs.isEmpty else { return false }

        if appState.settings.processingHost == .devbox {
            guard !appState.settings.devboxWorkerURL.isEmpty, !appState.settings.workerToken.isEmpty else {
                return false
            }
            if appState.processingMode == .full && appState.settings.devboxIngestTarget == .qdrantCloud {
                return !appState.settings.qdrantCloudURL.isEmpty && !appState.settings.qdrantAPIKey.isEmpty
            }
            if appState.processingMode == .full {
                return isQdrantConfigured
            }
            return true
        }
        switch appState.processingMode {
        case .chunkOnly:
            return !appState.settings.exportFolder.isEmpty
        case .full:
            return isQdrantConfigured
        }
    }

    private var isQdrantConfigured: Bool {
        !appState.settings.qdrantURL.isEmpty
    }

    private func startProcessing() {
        appState.isProcessing = true
        appState.resetCancellation()

        let jobs = appState.pendingJobs
        let settings = appState.settings
        let mode = appState.processingMode
        let maxParallel = max(1, settings.maxParallelJobs)

        processingTask = Task {
            if maxParallel <= 1 {
                for job in jobs {
                    if Task.isCancelled || appState.isCancellationRequested { break }
                    await processor.process(job: job, settings: settings, mode: mode)
                }
            } else {
                await withTaskGroup(of: Void.self) { group in
                    var launched = 0
                    var jobIndex = 0

                    while jobIndex < jobs.count {
                        if Task.isCancelled || appState.isCancellationRequested {
                            group.cancelAll()
                            break
                        }

                        if launched >= maxParallel {
                            await group.next()
                            launched -= 1
                        }

                        let job = jobs[jobIndex]
                        jobIndex += 1
                        launched += 1

                        group.addTask {
                            await self.processor.process(job: job, settings: settings, mode: mode)
                        }
                    }

                    await group.waitForAll()
                }
            }
            appState.isProcessing = false
            appState.resetCancellation()
        }
    }
}

struct BreadcrumbItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

struct BreadcrumbSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.quaternary)
    }
}
