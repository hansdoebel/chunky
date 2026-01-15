import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processor = DocumentProcessor()

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            MainContentView(processor: processor)
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("Chunky")
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        List {
            Section {
                Picker("", selection: $appState.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                HStack(spacing: 8) {
                    StatusDot(isActive: !appState.settings.ollamaURL.isEmpty)
                    Text("Ollama")
                        .font(.system(.body, design: .default))
                    Spacer()
                    Text(
                        appState.settings.embeddingModel.replacingOccurrences(
                            of: ":latest", with: "")
                    )
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .font(.caption)
                }

                HStack(spacing: 8) {
                    StatusDot(isActive: isQdrantConfigured)
                    Text("Qdrant")
                        .font(.system(.body, design: .default))
                    Spacer()
                    Text(appState.settings.defaultCollection)
                        .foregroundStyle(.tertiary)
                        .font(.caption)
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
        .frame(minWidth: 180)
    }

    private var isQdrantConfigured: Bool {
        !appState.settings.qdrantURL.isEmpty && !appState.settings.qdrantAPIKey.isEmpty
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
        .font(.system(.caption, design: .rounded))
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
            } else {
                CollectionBrowserView()
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

                Text("PDF, Word, PowerPoint, HTML, Images, Markdown, JSON")
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
                        onRemove: {
                            appState.removeJob(job)
                        })
                }
                .onMove(perform: moveJobs)
            }
            .listStyle(.plain)
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
        ]

        if panel.runModal() == .OK {
            appState.addFiles(panel.urls)
        }
    }
}

struct FileRowView: View {
    @ObservedObject var job: ProcessingJob
    @Environment(\.colorScheme) var colorScheme
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
                        Text("\(job.chunksCount) chunks")
                            .font(.caption)
                            .foregroundStyle(AppTheme.accentFallback)
                    } else if job.status == .failed {
                        Text(job.error ?? "Failed")
                            .font(.caption)
                            .foregroundStyle(AppTheme.statusRed)
                            .lineLimit(2)
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
    @State private var showNewCollectionField = false
    @State private var newCollectionName = ""
    @State private var selectedCollection: String = ""

    var body: some View {
        HStack(spacing: 16) {
            if appState.isProcessing {
                HStack(spacing: 12) {
                    ProgressView(value: appState.overallProgress)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accentFallback)
                        .frame(maxWidth: 200)

                    Text("\(Int(appState.overallProgress * 100))%")
                        .monospacedDigit()
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)

                    if appState.isCancellationRequested {
                        Text("Stopping...")
                            .foregroundStyle(AppTheme.statusOrange)
                            .font(.caption)
                    }
                }
            } else {
                // Mode selector with label
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mode")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Picker("", selection: $appState.processingMode) {
                        ForEach(ProcessingMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                Divider()
                    .frame(height: 32)
                    .opacity(0.5)

                // Collection selector with label
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collection")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if showNewCollectionField {
                        HStack(spacing: 4) {
                            TextField("Name", text: $newCollectionName)
                                .textFieldStyle(.plain)
                                .frame(width: 100)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            Button(action: addNewCollection) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.accentFallback)
                            }
                            .buttonStyle(.plain)
                            .disabled(newCollectionName.isEmpty)
                            Button(action: {
                                showNewCollectionField = false
                                newCollectionName = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Picker("", selection: $selectedCollection) {
                                Text("None").tag("")
                                ForEach(appState.availableCollections, id: \.self) { collection in
                                    Text(collection).tag(collection)
                                }
                                if !selectedCollection.isEmpty
                                    && !appState.availableCollections.contains(selectedCollection)
                                {
                                    Text(selectedCollection).tag(selectedCollection)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: selectedCollection) { _, newValue in
                                if appState.settings.defaultCollection != newValue {
                                    appState.settings.defaultCollection = newValue
                                    appState.settings.save()
                                }
                            }

                            Button(action: { showNewCollectionField = true }) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Create new collection")
                        }
                    }
                }

                Divider()
                    .frame(height: 32)
                    .opacity(0.5)

                // Export format selector
                VStack(alignment: .leading, spacing: 2) {
                    Text("Format")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.settings.exportFormat },
                            set: { newValue in
                                appState.settings.exportFormat = newValue
                                appState.settings.save()
                            }
                        )
                    ) {
                        ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                // Export folder with label
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button(action: selectExportFolder) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(exportFolderName)
                                .lineLimit(1)
                                .frame(maxWidth: 80, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(
                        appState.settings.exportFolder.isEmpty
                            ? "Select export folder" : appState.settings.exportFolder)
                }
            }

            Spacer()

            if appState.isProcessing {
                Button {
                    appState.requestCancellation()
                } label: {
                    Text("Stop")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.statusRed)
                .disabled(appState.isCancellationRequested)
            } else {
                Button {
                    startProcessing()
                } label: {
                    Text(startButtonTitle)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accentFallback)
                .controlSize(.large)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .onAppear {
            selectedCollection = appState.settings.defaultCollection
            Task { await appState.fetchCollections() }
        }
        .onChange(of: appState.settings.defaultCollection) { _, newValue in
            if selectedCollection != newValue {
                selectedCollection = newValue
            }
        }
    }

    private var exportFolderName: String {
        if appState.settings.exportFolder.isEmpty {
            return "Export..."
        }
        return URL(fileURLWithPath: appState.settings.exportFolder).lastPathComponent
    }

    private func selectExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder to save exported documents"

        if panel.runModal() == .OK, let url = panel.url {
            appState.settings.exportFolder = url.path
            appState.settings.save()
        }
    }

    private func addNewCollection() {
        guard !newCollectionName.isEmpty else { return }
        selectedCollection = newCollectionName
        appState.settings.defaultCollection = newCollectionName
        if !appState.availableCollections.contains(newCollectionName) {
            appState.availableCollections.insert(newCollectionName, at: 0)
        }
        appState.settings.save()
        showNewCollectionField = false
        newCollectionName = ""
    }

    private var startButtonTitle: String {
        switch appState.processingMode {
        case .chunkOnly: return "Chunk"
        case .ingestOnly: return "Ingest"
        case .full: return "Start"
        case .batch: return "Batch Ingest"
        }
    }

    private var canStart: Bool {
        guard !appState.pendingJobs.isEmpty else { return false }

        switch appState.processingMode {
        case .chunkOnly:
            return !appState.settings.exportFolder.isEmpty
        case .ingestOnly:
            return isQdrantConfigured
        case .full:
            return isQdrantConfigured
        case .batch:
            return isQdrantConfigured
        }
    }

    private var isQdrantConfigured: Bool {
        !appState.settings.qdrantURL.isEmpty && !appState.settings.qdrantAPIKey.isEmpty
    }

    private func startProcessing() {
        appState.isProcessing = true
        appState.resetCancellation()

        Task {
            if appState.processingMode == .batch {
                await processor.processBatch(
                    jobs: appState.pendingJobs,
                    settings: appState.settings,
                    cancellationCheck: { appState.isCancellationRequested }
                )
            } else {
                for job in appState.pendingJobs {
                    if appState.isCancellationRequested {
                        break
                    }
                    await processor.process(
                        job: job, settings: appState.settings, mode: appState.processingMode)
                }
            }
            appState.isProcessing = false
            appState.resetCancellation()
        }
    }
}
