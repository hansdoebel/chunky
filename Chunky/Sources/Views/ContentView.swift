import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processor = DocumentProcessor()

    private static func pingDatabase(settings: AppSettings) async -> Bool {
        guard let url = try? QdrantKeepAlive.collectionsURL(baseURL: QdrantKeepAlive.databaseURL(settings: settings)) else { return false }
        var request = URLRequest(url: url)
        if !settings.qdrantAPIKey.isEmpty {
            request.setValue(settings.qdrantAPIKey, forHTTPHeaderField: "api-key")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status)
        } catch {
            return false
        }
    }

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
            appState.startWatchedFolders()
            runWatchedJobs()
        }
        .onChange(of: appState.watchedRunToken) { _, _ in
            runWatchedJobs()
        }
        .onChange(of: appState.isProcessing) { _, running in
            if !running && appState.watchedFollowUp {
                appState.watchedFollowUp = false
                runWatchedJobs()
            }
        }
        .task(id: appState.settings.qdrantKeepAlive) {
            guard appState.settings.qdrantKeepAlive else { return }
            while !Task.isCancelled {
                let now = Date()
                await QdrantKeepAliveLoop.tick(settings: appState.settings, now: now) {
                    await Self.pingDatabase(settings: appState.settings)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func runWatchedJobs() {
        let jobs = appState.pendingJobs.filter { $0.watchedCollection != nil }
        guard !jobs.isEmpty else { return }
        guard !appState.isProcessing else {
            appState.watchedFollowUp = true
            return
        }
        appState.isProcessing = true
        appState.resetCancellation()
        let settings = appState.settings
        let maxParallel = max(1, settings.maxParallelJobs)
        appState.processingTask = Task {
            if maxParallel <= 1 {
                for job in jobs {
                    if Task.isCancelled || appState.isCancellationRequested { break }
                    await processor.process(job: job, settings: settings, mode: .full)
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
                            await self.processor.process(job: job, settings: settings, mode: .full)
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

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SidebarContent(settings: appState.settings)
    }
}

private struct SidebarContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                InterfaceModePicker(settings: settings)
            }
            ForEach(settings.interfaceMode.visibleViews(selected: appState.viewMode), id: \.self) { mode in
                Button { appState.viewMode = mode } label: {
                    NavigationRow(icon: mode.icon, title: mode.rawValue, isSelected: appState.viewMode == mode)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(appState.viewMode == mode ? .isSelected : [])
            }
            if settings.interfaceMode == .simple && appState.viewMode.isAdvanced {
                Text("Advanced tool kept open")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    Text(EmbeddingBackendKind(rawValue: appState.settings.embeddingBackend)?.displayName ?? "Embedding")
                        .font(.title3)
                    Spacer()
                    Text(
                        appState.settings.embeddingModel.replacingOccurrences(
                            of: ":latest", with: "")
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .font(.title3)
                }

                HStack(spacing: 8) {
                    Image(systemName: "doc.text.viewfinder").foregroundStyle(.secondary)
                    Text("VLM")
                        .font(.title3)
                    Spacer()
                    Text(vlmModelDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .font(.title3)
                }

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text("Qdrant")
                        .font(.title3)
                    Spacer()
                    Text(appState.settings.defaultCollection)
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
            } header: {
                Text("Configuration")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
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
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(title)
                .font(.title3)
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
        .font(.system(.title3, design: .rounded))
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
    @State private var showImport = false

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
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                selectFiles()
            } label: {
                Text("Add Files...")
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.accentFallback)
            .controlSize(.large)

            Button("Import Library") {
                showImport = true
            }
            .buttonStyle(.bordered)
            .sheet(isPresented: $showImport) {
                BibliographyImportSheet()
                    .environmentObject(appState)
            }

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
    @State private var showImport = false

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

                Button("Import Library") {
                    showImport = true
                }
                .buttonStyle(.bordered)
            }
            .sheet(isPresented: $showImport) {
                BibliographyImportSheet()
                    .environmentObject(appState)
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

                if let notice = job.localFallbackNotice {
                    Text(notice)
                        .font(.body)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(jobTypeBadge)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.badgeBackground, in: Capsule())

                    if job.status == .pending {
                        Text("Ready")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Toggle("Reconvert", isOn: $job.forceReconvert)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    } else if job.status == .completed {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(job.chunksCount) chunks")
                                .font(.body)
                                .foregroundStyle(AppTheme.accentFallback)
                            if let timing = job.timingSummary {
                                Text(timing)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let cache = job.cacheStatus {
                                Text("cache \(cache)")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if job.status == .failed {
                        Text(job.error ?? "Failed")
                            .font(.body)
                            .foregroundStyle(AppTheme.statusRed)
                            .lineLimit(5)
                            .textSelection(.enabled)
                            .help(job.error ?? "Failed")
                    } else {
                        HStack(spacing: 8) {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                                .tint(AppTheme.accentFallback)
                                .frame(maxWidth: 120)
                            Text(job.statusMessage)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer()

            if job.chunksCount > 0 && job.status != .pending {
                Text("\(job.embeddedCount)/\(job.chunksCount)")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(job.fileName) from queue")
                .help("Remove from queue. The source file is kept.")
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
                            .font(.body)
                    }
                }

                Spacer()

                Button {
                    appState.requestCancellation()
                    processor.cancel()
                    appState.processingTask?.cancel()
                    appState.benchmarkTask?.cancel()
                } label: {
                    Text("Stop")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.statusRed)
                .disabled(appState.isCancellationRequested)
            } else {

                VStack(alignment: .leading, spacing: 6) {
                    statusBreadcrumbs
                    if appState.processingMode == .full {
                        EmbeddingJobSummary(settings: appState.settings, jobs: appState.pendingJobs)
                    }
                }

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
        if appState.processingMode == .full && appState.settings.embeddingConfigurationProblem(jobs: appState.pendingJobs) != nil {
            return false
        }

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
        let selectedMode = appState.processingMode
        let maxParallel = max(1, settings.maxParallelJobs)

        appState.processingTask = Task {
            if maxParallel <= 1 {
                for job in jobs {
                    if Task.isCancelled || appState.isCancellationRequested { break }
                    let mode: ProcessingMode = job.watchedCollection == nil ? selectedMode : .full
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
                        let mode: ProcessingMode = job.watchedCollection == nil ? selectedMode : .full

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
