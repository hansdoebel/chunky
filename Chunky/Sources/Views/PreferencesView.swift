import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension String {
    fileprivate var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    var initialTab = 0
    var automaticallyCheckConnections = true

    var body: some View {
        PreferencesContent(
            settings: appState.settings,
            initialTab: initialTab,
            automaticallyCheckConnections: automaticallyCheckConnections
        )
    }
}

private struct PreferencesContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: AppSettings
    let automaticallyCheckConnections: Bool
    @State private var availableModels: [OllamaModel] = []
    @State private var isLoadingModels = false
    @State private var ollamaStatus: ConnectionStatus = .unknown
    @State private var qdrantStatus: ConnectionStatus = .unknown
    @State private var selectedTab: Int
    @State private var qdrantAPIKeyInput: String = ""
    @State private var workerTokenInput: String = ""
    @State private var workerEndpointURL = ""
    @State private var workerEndpoints: [WorkerEndpoint] = []
    @State private var selectedWorkerEndpointID: UUID?
    @State private var activeWorkerEndpointID: UUID?
    @State private var workerEndpointName = ""
    @State private var workerProbe: WorkerProbeReport?
    @State private var workerProbeGeneration = 0
    @State private var qdrantCloudURLInput: String = ""
    @State private var devboxStatusMessage: String = ""
    @State private var devboxStatus: ConnectionStatus = .unknown
    @State private var downloadingModels: Set<String> = []
    @State private var installedModels: [ManagedModel] = []
    @State private var modelStatusMessage = ""
    @State private var doclingVersion: String = "Unknown"
    @State private var latestDoclingVersion: String?
    @State private var isCheckingDocling = false
    @State private var isUpdatingDocling = false
    @State private var doclingUpdateStatus: String?
    @State private var showNewCollection = false
    @State private var piReport: PiInstallReport = .unknown
    @State private var piModels: [PiModel] = []
    @State private var piStatusMessage = ""
    @State private var chatAPIKeyInput = ""
    @ObservedObject private var cpuReadiness = CPUEmbeddingReadiness.shared

    init(settings: AppSettings, initialTab: Int, automaticallyCheckConnections: Bool) {
        self.settings = settings
        self.automaticallyCheckConnections = automaticallyCheckConnections
        _selectedTab = State(initialValue: initialTab)
    }

    private var advanced: Bool { settings.interfaceMode == .advanced }

    enum ConnectionStatus {
        case unknown, checking, connected, failed
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                InterfaceModePicker(settings: settings)
                Text(advanced
                    ? "All settings are visible. Switching to Simple keeps your configuration."
                    : "Everyday settings. Saved advanced settings still apply; switch to Advanced to edit them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            preferencesTabs
        }
        .frame(width: 540, height: 760)
        .onAppear {
            qdrantAPIKeyInput = appState.settings.qdrantAPIKey
            workerTokenInput = appState.settings.workerToken
            qdrantCloudURLInput = appState.settings.qdrantCloudURL
            chatAPIKeyInput = appState.settings.chatAPIKey
        }
        .onDisappear {
            appState.settings.save()
        }
        .sheet(isPresented: $showNewCollection) {
            NewCollectionSheet(
                vectorSize: appState.settings.embeddingDimensions,
                embeddingBackend: appState.settings.embeddingBackend,
                embeddingModel: appState.settings.embeddingModel
            )
            .environmentObject(appState)
        }
    }

    private var preferencesTabs: some View {
        TabView(selection: $selectedTab) {
            embeddingTab
                .tabItem {
                    Label("Embedding", systemImage: "cpu")
                }
                .tag(0)

            documentTab
                .tabItem {
                    Label("Documents", systemImage: "doc.text")
                }
                .tag(1)

            qdrantTab
                .tabItem {
                    Label("Qdrant", systemImage: "externaldrive.connected.to.line.below")
                }
                .tag(2)

            exportTab
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .tag(3)

            chatTab
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(4)

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(5)
        }
    }

    private var chatTab: some View {
        ChatSettingsPane(
            backend: $appState.settings.chatBackend,
            piPath: $appState.settings.piExecutablePath,
            chatAPIURL: $appState.settings.chatAPIURL,
            piModel: $appState.settings.piModel,
            chatModel: $appState.settings.chatModel,
            apiKey: $chatAPIKeyInput,
            report: piReport,
            models: piModels,
            statusMessage: piStatusMessage,
            onCheck: { Task { await refreshPi() } },
            onListModels: { Task { await listPiModels() } }
        )
        .padding()
        .onChange(of: chatAPIKeyInput) { _, newValue in
            appState.settings.chatAPIKey = newValue
        }
        .task {
            guard automaticallyCheckConnections else { return }
            await refreshPi()
        }
    }

    private func refreshPi() async {
        let override = appState.settings.piExecutablePath
        let report = await Task.detached(priority: .userInitiated) {
            PiLocator.live(overridePath: override)
        }.value
        piReport = report
        piStatusMessage = ""
    }

    private func listPiModels() async {
        piStatusMessage = ""
        appState.piSession.setOverridePath(appState.settings.piExecutablePath)
        do {
            piModels = try await appState.piSession.availableModels()
            if appState.settings.piModel.isEmpty, let first = piModels.first {
                appState.settings.piModel = first.modelIdentifier
            }
        } catch {
            piModels = []
            piStatusMessage = error.localizedDescription
        }
    }

    private var embeddingTab: some View {
        Form {
            Section("Embedding provider") {
                Picker("Provider", selection: Binding(
                    get: { appState.settings.embeddingBackend },
                    set: { appState.settings.selectEmbeddingBackend($0) }
                )) {
                    ForEach(EmbeddingBackendKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                LabeledContent("Processing host", value: appState.settings.processingHost.rawValue)
                LabeledContent("Embedding host", value: appState.settings.embeddingHostDescription)
                if appState.settings.embeddingBackend == EmbeddingBackendKind.openai.rawValue {
                    TextField("Embeddings URL", text: $appState.settings.embeddingAPIURL)
                    TextField("Model ID", text: $appState.settings.embeddingModel)
                    LabeledContent("Vector dimensions") {
                        TextField("Dimensions", value: $appState.settings.embeddingDimensions, format: .number.grouping(.never))
                            .frame(width: 80)
                    }
                    Text("OpenAI-compatible /v1/embeddings. Local Mac and Devbox jobs use the configured endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if appState.settings.embeddingBackend == EmbeddingBackendKind.fastembed.rawValue {
                CPUEmbeddingSettingsPane(
                    processingHost: appState.settings.processingHost,
                    readiness: cpuReadiness.message, busy: cpuReadiness.busy,
                    problem: appState.settings.embeddingConfigurationProblem,
                    onCheck: { Task { await checkCPUEmbedding(download: false) } },
                    onDownload: { Task { await checkCPUEmbedding(download: true) } }
                )
            }
            if appState.settings.embeddingBackend == EmbeddingBackendKind.ollama.rawValue {
                Section {
                    HStack {
                        TextField(
                            "Server URL", text: $appState.settings.ollamaURL,
                            prompt: Text("http://localhost:11434")
                        )
                        .textFieldStyle(.roundedBorder)

                        Button(action: { Task { await checkOllama() } }) {
                            switch ollamaStatus {
                            case .unknown:
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary)
                            case .checking:
                                ProgressView()
                                    .scaleEffect(0.7)
                            case .connected:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .failed:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Ollama Server")
                }

                Section {
                    if isLoadingModels {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading models...")
                                .foregroundColor(.secondary)
                        }
                    } else if availableModels.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No models found. Start Ollama and pull an embedding model.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Model", selection: $appState.settings.embeddingModel) {
                            ForEach(embeddingModels) { model in
                                HStack {
                                    Text(model.displayName)
                                    if !model.sizeFormatted.isEmpty {
                                        Text("(\(model.sizeFormatted))")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .tag(model.name)
                            }
                        }
                        .onChange(of: appState.settings.embeddingModel) { _, newModel in
                            Task { await applyProbedDimensions(for: newModel) }
                        }
                    }

                    LabeledContent("Vector Dimensions") {
                        TextField(
                            "",
                            value: $appState.settings.embeddingDimensions,
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                    }
                } header: {
                    Text("Embedding Model")
                }

            }
            if appState.settings.embeddingBackend != EmbeddingBackendKind.fastembed.rawValue,
               let problem = appState.settings.embeddingConfigurationProblem {
                Section("Collection compatibility") {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if advanced {
                Section {
                    StepperRow(
                        label: "Batch Size", value: $appState.settings.embeddingBatchSize, range: 1...32
                    )
                    StepperRow(
                        label: "Concurrency", value: $appState.settings.embeddingConcurrency,
                        range: 1...4)
                    EmbeddingCacheSettingsPane(
                        streaming: $appState.settings.streamingPipeline,
                        reuseEmbeddings: $appState.settings.enableEmbeddingCache,
                        host: appState.settings.processingHost
                    )
                } header: {
                    Text("Performance")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task(id: appState.settings.embeddingBackend) {
            guard automaticallyCheckConnections else { return }
            if appState.settings.embeddingBackend == "fastembed" {
                await checkCPUEmbedding(download: false)
            } else {
                await loadModels()
            }
        }
    }

    private func checkCPUEmbedding(download: Bool) async {
        await cpuReadiness.check(download: download)
    }

    private func refreshInstalledModels() async {
        if appState.settings.processingHost == .devbox {
            do {
                installedModels = try await DevboxWorkerService().fetchInstalledModels(
                    baseURL: appState.settings.devboxWorkerURL,
                    token: appState.settings.workerToken
                )
            } catch {
                modelStatusMessage = error.localizedDescription
            }
            return
        }
        do {
            let service = try OllamaService(baseURL: appState.settings.ollamaURL)
            let data = try await service.tagsData()
            installedModels = try ModelCatalog.ollamaModels(from: data)
        } catch {
            installedModels = []
        }
    }

    private func downloadModel(_ repoID: String) async {
        downloadingModels.insert(repoID)
        let kind = repoID.contains("/") ? "huggingface" : "ollama"
        do {
            let id = try await DevboxWorkerService().startModelDownload(
                baseURL: appState.settings.devboxWorkerURL,
                token: appState.settings.workerToken,
                repoID: repoID,
                kind: kind
            )
            let status = try await DevboxWorkerService().waitForModelDownload(
                baseURL: appState.settings.devboxWorkerURL,
                token: appState.settings.workerToken,
                jobID: id
            )
            downloadingModels.remove(repoID)
            modelStatusMessage = "Download \(status) for \(repoID)."
            await refreshInstalledModels()
        } catch {
            downloadingModels.remove(repoID)
            modelStatusMessage = error.localizedDescription
        }
    }

    private var documentTab: some View {
        Form {
            Section {
                Picker("Processing host", selection: $appState.settings.processingHost) {
                    ForEach(ProcessingHost.allCases) { host in
                        Text(host.rawValue).tag(host)
                    }
                }
                .onChange(of: appState.settings.processingHost) { _, host in
                    let current = DoclingModel(rawValue: appState.settings.doclingModel) ?? .standard
                    if host == .devbox && current.isMLX {
                        appState.settings.doclingModel = current.devboxModel.rawValue
                    }
                    appState.settings.doclingAccelerator = host.defaultAccelerator.rawValue
                }
                if appState.settings.processingHost == .devbox {
                    LocalFallbackSettingsPane(enabled: $appState.settings.allowLocalFallback)
                    WorkerEndpointsPane(
                        endpoints: workerEndpoints,
                        selectedID: selectedWorkerEndpointID,
                        activeID: activeWorkerEndpointID,
                        name: workerEndpointName,
                        url: workerEndpointURL,
                        token: workerTokenInput,
                        report: workerProbe,
                        onSelect: { selectWorkerEndpoint($0) },
                        onName: { workerEndpointName = $0 },
                        onURL: { editWorkerEndpointURL($0) },
                        onToken: { editWorkerEndpointToken($0) },
                        onSave: { saveWorkerEndpoint() },
                        onUse: { useSelectedWorkerEndpoint() },
                        onCheck: { Task { await testDevboxConnection() } }
                    )
                    .onAppear { loadWorkerEndpoints() }
                    Text("Plain HTTP to a private LAN address is allowed by NSAllowsLocalNetworking. MagicDNS HTTP uses the ts.net exception. The token is stored in the Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if advanced {
                    RecommendedModelsSection(
                        host: appState.settings.processingHost,
                        installed: installedModels,
                        downloading: downloadingModels,
                        statusMessage: modelStatusMessage,
                        onDownload: { repo in Task { await downloadModel(repo) } }
                    )
                }

                Picker("VLM Model", selection: $appState.settings.doclingModel) {
                    ForEach(DoclingModel.models(for: appState.settings.processingHost), id: \.rawValue) { model in
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                        }
                        .tag(model.rawValue)
                    }
                }

                if let selected = DoclingModel(rawValue: appState.settings.doclingModel),
                   selected != .standard {
                    Text(selected.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if advanced && appState.settings.doclingModel == DoclingModel.standard.rawValue {
                    Picker("Layout Model", selection: $appState.settings.layoutModel) {
                        ForEach(LayoutModel.allCases, id: \.rawValue) { model in
                            Text(model.displayName).tag(model.rawValue)
                        }
                    }

                    if let selected = LayoutModel(rawValue: appState.settings.layoutModel),
                       selected != .standard {
                        Text(selected.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Document Model")
            }

            if advanced {
                Section {
                    Toggle("Daemon Mode", isOn: $appState.settings.useDaemonMode)
                    StepperRow(label: "Parallel Jobs", value: $appState.settings.maxParallelJobs, range: 1...4)
                    StepperRow(label: "Workers", value: $appState.settings.doclingWorkers, range: 1...16)
                    if appState.settings.processingHost == .localMac {
                        Text("TableFormer stays on the CPU. Keep table batches small on this machine.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    StepperRow(label: "OCR batch", value: $appState.settings.ocrBatchSize, range: 0...64)
                    StepperRow(label: "Layout batch", value: $appState.settings.layoutBatchSize, range: 0...64)
                    StepperRow(label: "Table batch", value: $appState.settings.tableBatchSize, range: 0...16)
                    Text("Zero uses the host default. A worker host uses 64 without a vision model, and 8 to 16 when one shares the GPU.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Accelerator", selection: $appState.settings.doclingAccelerator) {
                        ForEach(Accelerator.allCases, id: \.rawValue) { accel in
                            Text(accel.displayName).tag(accel.rawValue)
                        }
                    }

                    StepperRow(
                        label: "Timeout", value: $appState.settings.doclingTimeout, range: 60...600,
                        step: 30,
                        suffix: "s")

                    LabeledContent("Max Pages") {
                        HStack(spacing: 8) {
                            Text(
                                appState.settings.doclingMaxPages == 0
                                    ? "Unlimited" : "\(appState.settings.doclingMaxPages)"
                            )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                            Stepper(
                                "", value: $appState.settings.doclingMaxPages, in: 0...500, step: 10
                            )
                            .labelsHidden()
                        }
                    }

                    StepperRow(
                        label: "Max Tokens/Chunk", value: $appState.settings.maxTokensPerChunk,
                        range: 128...2048, step: 128)

                    StepperRow(
                        label: "Chunk Overlap", value: $appState.settings.chunkOverlap,
                        range: 0...512, step: 16)

                    Toggle("Merge Peers", isOn: $appState.settings.chunkMergePeers)

                    HStack {
                        Text("Tokenizer")
                        Spacer()
                        TextField(text: $appState.settings.chunkTokenizer, prompt: Text("auto")) {}
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Processing")
                }
            }

            Section {
                Toggle("Table Extraction", isOn: $appState.settings.doTableExtraction)

                if appState.settings.doTableExtraction {
                    Picker("Table Mode", selection: $appState.settings.tableMode) {
                        ForEach(TableMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                }

                Toggle("OCR (for scanned documents)", isOn: $appState.settings.doOCR)

                if appState.settings.doOCR {
                    Picker("OCR Language", selection: $appState.settings.ocrLanguage) {
                        ForEach(OCRLanguage.allCases, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                }

                if advanced {
                    Toggle("Formula Enrichment", isOn: $appState.settings.doFormulaEnrichment)
                    Toggle("Code Enrichment", isOn: $appState.settings.doCodeEnrichment)
                    Toggle("Chart Extraction", isOn: $appState.settings.doChartExtraction)
                    Toggle("Picture Description", isOn: $appState.settings.doPictureDescription)
                    if appState.settings.doPictureDescription {
                        Picker("Description model", selection: $appState.settings.pictureDescriptionPreset) {
                            Text("Host default").tag("")
                            ForEach(PictureDescriptionPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset.rawValue)
                            }
                        }
                        TextField(
                            "VLM server URL",
                            text: $appState.settings.vlmServerURL,
                            prompt: Text("http://127.0.0.1:8001")
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("Used by the API preset. This is not the embedding Ollama URL.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Toggle("Picture Classification", isOn: $appState.settings.doPictureClassification)
                    Toggle("Text Cleanup", isOn: $appState.settings.doTextCleanup)
                }
            } header: {
                Text("Features")
            } footer: {
                Text("These settings apply to PDF processing only.")
                    .foregroundStyle(.secondary)
            }

            if advanced {
                Section {
                    Toggle("Structured Extraction", isOn: $appState.settings.doStructuredExtraction)

                    if appState.settings.doStructuredExtraction {
                        HStack {
                            Text(extractionSchemaDisplayName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Select Schema...") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [UTType.json]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    appState.settings.extractionSchemaPath = url.path
                                }
                            }
                        }
                    }
                } header: {
                    Text("Structured Extraction (Beta)")
                } footer: {
                    Text("Extract structured data using a JSON template schema.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Image Export Mode", selection: $appState.settings.imageExportMode) {
                        ForEach(ImageExportMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .help(ImageExportMode(rawValue: appState.settings.imageExportMode)?.description ?? "")
                } header: {
                    Text("Image Export")
                }

                Section {
                    Toggle("Filename", isOn: $appState.settings.metadataIncludeFilename)
                    Toggle("Page Number", isOn: $appState.settings.metadataIncludePageNumber)
                    Toggle("Headings", isOn: $appState.settings.metadataIncludeHeadings)
                    Toggle("Timestamp", isOn: $appState.settings.metadataIncludeTimestamp)
                    Toggle("Document Title", isOn: $appState.settings.metadataIncludeDocTitle)
                    Toggle("Authors", isOn: $appState.settings.metadataIncludeAuthors)
                    Toggle("Chunk Index", isOn: $appState.settings.metadataIncludeChunkIndex)
                    Toggle("Content Type", isOn: $appState.settings.metadataIncludeContentType)
                    Toggle("Section", isOn: $appState.settings.metadataIncludeSection)
                    Toggle("DOI", isOn: $appState.settings.metadataIncludeDOI)
                    Toggle("Document ID", isOn: $appState.settings.metadataIncludeDocumentId)
                    Toggle("URL", isOn: $appState.settings.metadataIncludeURL)
                    Toggle("Year", isOn: $appState.settings.metadataIncludeYear)
                    Toggle("Language", isOn: $appState.settings.metadataIncludeLanguage)
                } header: {
                    Text("Metadata to Include")
                }
            }
        }
        .task(id: appState.settings.processingHost) {
            guard automaticallyCheckConnections else { return }
            await refreshInstalledModels()
        }
        .formStyle(.grouped)
        .padding()
    }

    private var extractionSchemaDisplayName: String {
        let path = appState.settings.extractionSchemaPath
        if path.isEmpty { return "No schema selected" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var exportTab: some View {
        Form {
            Section {
                Picker("Processing Mode", selection: $appState.processingMode) {
                    ForEach(ProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .onChange(of: appState.processingMode) { _, newMode in
                    if newMode == .full {
                        appState.settings.exportFormat = ExportFormat.none.rawValue
                    } else if appState.settings.exportFormat == ExportFormat.none.rawValue {
                        appState.settings.exportFormat = ExportFormat.json.rawValue
                    }
                }
            } header: {
                Text("Mode")
            }

            if appState.processingMode == .chunkOnly {
                Section {
                    Picker("Format", selection: $appState.settings.exportFormat) {
                        ForEach(exportFormatOptions, id: \.rawValue) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }

                    HStack {
                        Text("Export Folder")
                        Spacer()
                        Button(action: selectExportFolder) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(exportFolderDisplayName)
                                    .lineLimit(1)
                                    .frame(maxWidth: 200, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Export Settings")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var exportFolderDisplayName: String {
        if appState.settings.exportFolder.isEmpty {
            return "Select folder..."
        }
        return URL(fileURLWithPath: appState.settings.exportFolder).lastPathComponent
    }

    private var exportFormatOptions: [ExportFormat] {
        if appState.processingMode == .full {
            return ExportFormat.allCases
        } else {
            return ExportFormat.allCases.filter { $0 != .none }
        }
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
            appState.objectWillChange.send()
        }
    }

    private var qdrantTab: some View {
        Form {
            Section { LocalQdrantPane(automaticallyRefresh: automaticallyCheckConnections) }
            if advanced || settings.processingHost == .devbox {
                Section {
                    Picker("Profile", selection: $appState.settings.qdrantProfile) {
                        ForEach(QdrantProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .onChange(of: appState.settings.qdrantProfile) { _, profile in
                        if profile == .quality {
                            appState.settings.doPictureDescription = true
                            appState.settings.doPictureClassification = true
                        }
                    }
                    Text("Quality turns on picture description and classification.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Worker ingest", selection: $appState.settings.devboxIngestTarget) {
                        ForEach(DevboxIngestTarget.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    TextField(
                        "Qdrant Cloud URL",
                        text: $qdrantCloudURLInput,
                        prompt: Text("https://example.cloud.qdrant.io")
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: qdrantCloudURLInput) { _, newValue in
                        appState.settings.qdrantCloudURL = newValue
                    }
                    Text("Used when Processing host is Devbox and ingest is Qdrant Cloud. The API key below is sent with the job and is not stored on the worker. Local Mac keeps using Server URL.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Worker ingest target")
                }
            }

            Section {
                LabeledContent("Server URL") {
                    HStack {
                        TextField(
                            "", text: $appState.settings.qdrantURL,
                            prompt: Text("https://xxx.cloud.qdrant.io")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onSubmit {
                            Task { await testQdrantConnection() }
                        }

                        connectionIndicator
                    }
                }

                LabeledContent("API Key") {
                    HStack {
                        SecureField("", text: $qdrantAPIKeyInput, prompt: Text("Optional"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onChange(of: qdrantAPIKeyInput) { _, newValue in
                                appState.settings.qdrantAPIKey = newValue
                            }
                            .onSubmit {
                                Task { await testQdrantConnection() }
                            }

                        if !qdrantAPIKeyInput.isEmpty {
                            Image(systemName: "key.fill")
                                .foregroundColor(.green)
                                .help("Stored in Keychain")
                        } else {
                            Image(systemName: "key")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button("New collection") { showNewCollection = true }
                Picker("Collection", selection: $appState.settings.defaultCollection) {
                    ForEach(appState.availableCollections, id: \.self) { collection in
                        Text(collection).tag(collection)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                if let error = appState.qdrantConnectionError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            if advanced {
                Section {
                    StepperRow(
                        label: "Batch Size", value: $appState.settings.qdrantBatchSize, range: 10...500,
                        step: 10)
                    StepperRow(
                        label: "Timeout", value: $appState.settings.qdrantTimeout, range: 10...120,
                        step: 10,
                        suffix: "s")
                    Picker("Distance Metric", selection: $appState.settings.qdrantDistanceMetric) {
                        ForEach(DistanceMetric.allCases, id: \.rawValue) { metric in
                            Text(metric.displayName).tag(metric.rawValue)
                        }
                    }

                    Picker("Quantization", selection: $appState.settings.qdrantCompression) {
                        ForEach(Compression.allCases, id: \.rawValue) { compression in
                            Text(compression.displayName).tag(compression.rawValue)
                        }
                    }
                    .help(Compression(rawValue: appState.settings.qdrantCompression)?.description ?? "")

                    Toggle("Hybrid Search (Dense + Sparse)", isOn: $appState.settings.hybridSearch)
                } header: {
                    Text("Upload")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            guard automaticallyCheckConnections else { return }
            if !appState.settings.qdrantURL.isEmpty && qdrantStatus == .unknown {
                await testQdrantConnection()
            }
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch qdrantStatus {
        case .unknown:
            Image(systemName: "circle.fill")
                .foregroundColor(.gray)
                .help("Not tested")
        case .checking:
            Image(systemName: "circle.fill")
                .foregroundColor(.orange)
                .help("Testing connection...")
        case .connected:
            Image(systemName: "circle.fill")
                .foregroundColor(.green)
                .help("Connected")
        case .failed:
            Image(systemName: "circle.fill")
                .foregroundColor(.red)
                .help("Connection failed")
        }
    }

    private var embeddingModels: [OllamaModel] {
        let embeddingKeywords = [
            "embed", "nomic", "minilm", "bge", "e5", "gte", "arctic", "snowflake",
        ]
        return availableModels.filter { model in
            let name = model.name.lowercased()
            return embeddingKeywords.contains { name.contains($0) }
        }
    }

    private func loadModels() async {
        guard appState.settings.embeddingBackend == EmbeddingBackendKind.ollama.rawValue else { return }
        isLoadingModels = true
        ollamaStatus = .checking
        do {
            let service = try OllamaService(baseURL: appState.settings.ollamaURL)
            let models = try await service.listModels()
            guard appState.settings.embeddingBackend == EmbeddingBackendKind.ollama.rawValue else {
                isLoadingModels = false
                return
            }
            availableModels = models
            ollamaStatus = .connected

            await applyProbedDimensions(for: appState.settings.embeddingModel)

        } catch {
            availableModels = []
            ollamaStatus = .failed
        }
        isLoadingModels = false
    }

    private func applyProbedDimensions(for model: String) async {
        guard appState.settings.embeddingBackend == EmbeddingBackendKind.ollama.rawValue else { return }
        do {
            let service = try OllamaService(baseURL: appState.settings.ollamaURL)
            let dimensions = try await service.probeDimension(model: model)
            guard appState.settings.embeddingBackend == EmbeddingBackendKind.ollama.rawValue,
                  appState.settings.embeddingModel == model else { return }
            appState.settings.embeddingDimensions = dimensions
        } catch {
            return
        }
    }

    private func loadWorkerEndpoints() {
        workerEndpoints = appState.settings.workerEndpoints()
        activeWorkerEndpointID = appState.settings.activeWorkerEndpointID()
        let shown = activeWorkerEndpointID ?? workerEndpoints.first?.id
        if let shown {
            selectWorkerEndpoint(shown)
        }
    }

    private func selectWorkerEndpoint(_ id: UUID) {
        selectedWorkerEndpointID = id
        guard let endpoint = workerEndpoints.first(where: { $0.id == id }) else { return }
        workerEndpointName = endpoint.name
        workerEndpointURL = endpoint.url
        workerTokenInput = appState.settings.workerEndpointToken(id: id)
        invalidateWorkerProbe()
    }

    private func editWorkerEndpointURL(_ value: String) {
        guard value != workerEndpointURL else { return }
        workerEndpointURL = value
        invalidateWorkerProbe()
    }

    private func editWorkerEndpointToken(_ value: String) {
        guard value != workerTokenInput else { return }
        workerTokenInput = value
        invalidateWorkerProbe()
    }

    private func invalidateWorkerProbe() {
        workerProbeGeneration += 1
        workerProbe = nil
        devboxStatus = .unknown
        devboxStatusMessage = ""
    }

    private func saveWorkerEndpoint() {
        var endpoints = workerEndpoints
        if let id = selectedWorkerEndpointID, let index = endpoints.firstIndex(where: { $0.id == id }) {
            endpoints[index].name = workerEndpointName.isEmpty ? endpoints[index].name : workerEndpointName
            endpoints[index].url = workerEndpointURL
            appState.settings.setWorkerEndpointToken(id: id, workerTokenInput)
        } else {
            let created = WorkerEndpoint(id: UUID(), name: workerEndpointName.isEmpty ? "Worker" : workerEndpointName, url: workerEndpointURL)
            endpoints.append(created)
            selectedWorkerEndpointID = created.id
            appState.settings.setWorkerEndpointToken(id: created.id, workerTokenInput)
        }
        appState.settings.replaceWorkerEndpoints(endpoints)
        workerEndpoints = endpoints
    }

    private func useSelectedWorkerEndpoint() {
        saveWorkerEndpoint()
        guard let id = selectedWorkerEndpointID, let endpoint = workerEndpoints.first(where: { $0.id == id }) else { return }
        appState.settings.useWorkerEndpoint(endpoint)
        activeWorkerEndpointID = endpoint.id
        workerTokenInput = appState.settings.workerEndpointToken(id: endpoint.id)
    }

    private func testDevboxConnection() async {
        let url = workerEndpointURL
        let token = workerTokenInput
        workerProbeGeneration += 1
        let started = workerProbeGeneration
        devboxStatus = .checking
        workerProbe = nil
        let report = await DevboxWorkerService().probe(baseURL: url, token: token)
        guard WorkerProbe.isCurrent(
            started: started,
            url: url,
            token: token,
            generation: workerProbeGeneration,
            currentURL: workerEndpointURL,
            currentToken: workerTokenInput
        ) else { return }
        workerProbe = report
        devboxStatusMessage = report.message
        devboxStatus = report.kind == .connected ? .connected : .failed
    }

    private func checkOllama() async {
        ollamaStatus = .checking
        do {
            let service = try OllamaService(baseURL: appState.settings.ollamaURL)
            _ = try await service.listModels()
            ollamaStatus = .connected
        } catch {
            ollamaStatus = .failed
        }
    }

    private func testQdrantConnection() async {
        guard !appState.settings.qdrantURL.isEmpty else {
            qdrantStatus = .unknown
            appState.qdrantConnectionError = nil
            return
        }

        qdrantStatus = .checking
        appState.qdrantConnectionError = nil

        appState.qdrantService = nil

        do {
            try await appState.ensureQdrantConnection()
            await appState.fetchCollections()
            qdrantStatus = .connected
        } catch is CancellationError {

            print("Qdrant connection cancelled")
        } catch {
            qdrantStatus = .failed
            appState.qdrantConnectionError = error.localizedDescription
            print("Qdrant connection failed: \(error)")
        }
    }

    private var aboutTab: some View {
        Form {
            Section {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chunky")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Version \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Document chunking and vector embedding tool")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            Section {
                LabeledContent("Docling") {
                    HStack(spacing: 12) {
                        if isCheckingDocling {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Checking...")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(doclingVersion)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)

                            if let latest = latestDoclingVersion, latest != doclingVersion {
                                Text("\(latest) available")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if isUpdatingDocling {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(doclingUpdateStatus ?? "Updating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Button("Check for Updates") {
                            Task { await checkDoclingVersion() }
                        }
                        .disabled(isCheckingDocling)

                        if let latest = latestDoclingVersion, latest != doclingVersion {
                            Button("Update Docling") {
                                Task { await updateDocling() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if let status = doclingUpdateStatus, !isUpdatingDocling {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("success") ? .green : .secondary)
                }
            } header: {
                Text("Dependencies")
            }

            Section {
                WatchedFoldersPane(
                    folders: appState.watchedIndex.folders,
                    status: appState.watchedStatus,
                    onAdd: addWatchedFolder,
                    onScan: { appState.scanWatchedFolders() },
                    onTogglePause: toggleWatchedPause,
                    onToggleDelete: toggleWatchedDelete,
                    onRemove: removeWatchedFolder
                )
                .onAppear {
                    if automaticallyCheckConnections { appState.startWatchedFolders() }
                }
            } header: {
                Text("Watched folders")
            }

            Section {
                ChunkCacheSettingsPane(
                    limitMB: $appState.settings.chunkCacheLimitMB,
                    onClear: clearChunkCache
                )
            } header: {
                Text("Chunk cache")
            }

            Section {
                ProjectLinksPane()
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            guard automaticallyCheckConnections else { return }
            await checkDoclingVersion()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.loadWatchedFolders()
        var index = appState.watchedIndex
        index.folders.append(WatchedFolder(path: url.path, collection: appState.settings.defaultCollection))
        appState.watchedIndex = index
        appState.saveWatchedFolders()
        appState.scanWatchedFolders()
    }

    private func toggleWatchedPause(_ id: UUID) {
        guard let offset = appState.watchedIndex.folders.firstIndex(where: { $0.id == id }) else { return }
        var index = appState.watchedIndex
        index.folders[offset].paused.toggle()
        appState.watchedIndex = index
        appState.saveWatchedFolders()
        appState.startWatchingFolders()
    }

    private func toggleWatchedDelete(_ id: UUID) {
        guard let offset = appState.watchedIndex.folders.firstIndex(where: { $0.id == id }) else { return }
        var index = appState.watchedIndex
        index.folders[offset].deleteRemoved.toggle()
        appState.watchedIndex = index
        appState.saveWatchedFolders()
    }

    private func removeWatchedFolder(_ id: UUID) {
        var index = appState.watchedIndex
        index.folders.removeAll { $0.id == id }
        appState.watchedIndex = index
        appState.saveWatchedFolders()
        appState.startWatchingFolders()
    }

    private func clearChunkCache() {
        try? ChunkCacheStore(
            directory: ChunkCacheLocation.macDirectory(),
            limitBytes: appState.settings.chunkCacheLimitBytes
        ).clear()
    }

    private func checkDoclingVersion() async {
        isCheckingDocling = true
        doclingUpdateStatus = nil

        let pipPath = "~/.chunky-venv/bin/pip".expandingTildeInPath

        if !FileManager.default.fileExists(atPath: pipPath) {
            doclingVersion = "venv not found"
            isCheckingDocling = false
            await checkLatestDoclingVersion()
            return
        }

        do {
            let version = try await getDoclingVersionViaPip(pipPath: pipPath)
            doclingVersion = version
            if version.range(of: #"^\d"#, options: .regularExpression) != nil {
                appState.settings.recordedDoclingVersion = version
            }
        } catch {
            doclingVersion = "Not installed"
        }

        await checkLatestDoclingVersion()

        isCheckingDocling = false
    }

    private func getDoclingVersionViaPip(pipPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pipPath)
            process.arguments = ["show", "docling"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0,
                    let versionLine = output.components(separatedBy: "\n").first(where: {
                        $0.hasPrefix("Version:")
                    })
                {
                    let version = versionLine.replacingOccurrences(of: "Version:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    continuation.resume(returning: version)
                } else {
                    continuation.resume(throwing: NSError(domain: "DoclingCheck", code: 1))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func getDoclingVersionDirect(pythonPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-c", "import docling; print(docling.__version__)"]

            var env = ProcessInfo.processInfo.environment
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output =
                    String(data: data, encoding: .utf8)?.trimmingCharacters(
                        in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 && !output.isEmpty {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(domain: "DoclingCheck", code: 1))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func checkLatestDoclingVersion() async {
        guard let url = URL(string: "https://pypi.org/pypi/docling/json") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let info = json["info"] as? [String: Any],
                let version = info["version"] as? String
            {
                latestDoclingVersion = version
            }
        } catch {
            print("Failed to check latest docling version: \(error)")
        }
    }

    private func updateDocling() async {
        isUpdatingDocling = true
        doclingUpdateStatus = "Updating docling..."

        let pipPath = "~/.chunky-venv/bin/pip".expandingTildeInPath

        do {
            let result = try await runPipUpgrade(pipPath: pipPath)

            if result.success {

                try? await Task.sleep(nanoseconds: 1_000_000_000)

                if let newVersion = try? await getDoclingVersionViaPip(pipPath: pipPath) {
                    doclingVersion = newVersion
                    latestDoclingVersion = newVersion
                    doclingUpdateStatus = "Updated to \(newVersion)!"
                } else {
                    doclingUpdateStatus = "Update successful! Restart to see version."
                }
            } else {
                doclingUpdateStatus = "Update failed: \(result.output.prefix(100))"
            }
        } catch {
            doclingUpdateStatus = "Update failed: \(error.localizedDescription)"
        }

        isUpdatingDocling = false
    }

    private func runPipUpgrade(pipPath: String) async throws -> (success: Bool, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pipPath)
            process.arguments = ["install", "--upgrade", "docling"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus == 0, output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func refreshDoclingVersion(pythonPath: String) async {
        do {
            let version = try await getDoclingVersionDirect(pythonPath: pythonPath)
            doclingVersion = version
            latestDoclingVersion = version
        } catch {

        }
    }

}

struct StepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text("\(value)\(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 50, alignment: .trailing)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}
