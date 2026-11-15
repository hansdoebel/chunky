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
    @State private var availableModels: [OllamaModel] = []
    @State private var isLoadingModels = false
    @State private var ollamaStatus: ConnectionStatus = .unknown
    @State private var qdrantStatus: ConnectionStatus = .unknown
    @State private var selectedTab = 0
    @State private var qdrantAPIKeyInput: String = ""
    @State private var workerTokenInput: String = ""
    @State private var qdrantCloudURLInput: String = ""
    @State private var devboxStatusMessage: String = ""
    @State private var devboxStatus: ConnectionStatus = .unknown
    @State private var doclingVersion: String = "Unknown"
    @State private var latestDoclingVersion: String?
    @State private var isCheckingDocling = false
    @State private var isUpdatingDocling = false
    @State private var doclingUpdateStatus: String?
    @State private var showNewCollection = false

    enum ConnectionStatus {
        case unknown, checking, connected, failed
    }

    var body: some View {
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

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(4)
        }
        .frame(width: 500, height: 700)
        .onAppear {
            qdrantAPIKeyInput = appState.settings.qdrantAPIKey
            workerTokenInput = appState.settings.workerToken
            qdrantCloudURLInput = appState.settings.qdrantCloudURL
            Task { await loadModels() }
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

    private var embeddingTab: some View {
        Form {
            Section {
                if appState.settings.processingHost == .devbox {
                    Picker("Backend", selection: $appState.settings.embeddingBackend) {
                        ForEach(EmbeddingBackendKind.allCases) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    if appState.settings.embeddingBackend == EmbeddingBackendKind.openai.rawValue {
                        TextField(
                            "Embeddings URL",
                            text: $appState.settings.embeddingAPIURL,
                            prompt: Text("http://127.0.0.1:8002")
                        )
                        .textFieldStyle(.roundedBorder)
                        TextField(
                            "Model ID",
                            text: $appState.settings.embeddingModel,
                            prompt: Text("Qwen/Qwen3-Embedding-0.6B")
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("OpenAI-compatible /v1/embeddings. This is not the Ollama URL. Local Mac jobs still embed with Ollama.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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

            Section {
                StepperRow(
                    label: "Batch Size", value: $appState.settings.embeddingBatchSize, range: 1...32
                )
                StepperRow(
                    label: "Concurrency", value: $appState.settings.embeddingConcurrency,
                    range: 1...4)
                Toggle("Streaming Pipeline", isOn: $appState.settings.streamingPipeline)
                Toggle("Embedding Cache", isOn: $appState.settings.enableEmbeddingCache)
            } header: {
                Text("Performance")
            }
        }
        .formStyle(.grouped)
        .padding()
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
                    TextField(
                        "Worker URL",
                        text: $appState.settings.devboxWorkerURL,
                        prompt: Text("http://<10GbE-ip>:8080")
                    )
                    .textFieldStyle(.roundedBorder)
                    SecureField("Worker token", text: $workerTokenInput, prompt: Text("Bearer token"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: workerTokenInput) { _, newValue in
                            appState.settings.workerToken = newValue
                        }
                    HStack {
                        Button("Test connection") { Task { await testDevboxConnection() } }
                            .disabled(devboxStatus == .checking)
                        if devboxStatus == .connected {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        } else if devboxStatus == .failed {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        }
                    }
                    if !devboxStatusMessage.isEmpty {
                        Text(devboxStatusMessage)
                            .font(.caption)
                            .foregroundColor(devboxStatus == .failed ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                    Text("Plain HTTP to a private 10GbE address is allowed by NSAllowsLocalNetworking. The token is stored in the Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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

                if appState.settings.doclingModel == DoclingModel.standard.rawValue {
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

            Section {
                Toggle("Daemon Mode", isOn: $appState.settings.useDaemonMode)
                StepperRow(label: "Parallel Jobs", value: $appState.settings.maxParallelJobs, range: 1...4)
                StepperRow(label: "Workers", value: $appState.settings.doclingWorkers, range: 1...16)
                if appState.settings.processingHost == .localMac {
                    Text("TableFormer stays on the CPU. Keep table batches small on this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                StepperRow(label: "OCR batch", value: $appState.settings.ocrBatchSize, range: 0...64)
                StepperRow(label: "Layout batch", value: $appState.settings.layoutBatchSize, range: 0...64)
                StepperRow(label: "Table batch", value: $appState.settings.tableBatchSize, range: 0...16)
                Text("Zero uses the host default. The devbox uses 64 without a vision model, and 8 to 16 when one shares the GPU.")
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
            } header: {
                Text("Features")
            } footer: {
                Text("These settings apply to PDF processing only.")
                    .foregroundStyle(.secondary)
            }

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
                Picker("Devbox ingest", selection: $appState.settings.devboxIngestTarget) {
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
                Text("Devbox ingest target")
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
        .formStyle(.grouped)
        .padding()
        .task {
            // Auto-test on tab appear if URL is set
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

    /// Display fallback used only when Ollama cannot be probed. Ingest does not use this guess.
    private func dimensionsForModel(_ modelName: String) -> Int {
        let name = modelName.lowercased()

        if name.contains("qwen3") {
            if name.contains("8b") { return 4096 }
            if name.contains("4b") { return 2560 }
            return 1024
        }

        if name.contains("snowflake") || name.contains("arctic") || name.contains("mxbai")
            || name.contains("large") || name.contains("e5-large") || name.contains("gte-large")
            || name.contains("bge-large") || name.contains("bge-m3")
        {
            return 1024
        }

        // 384-dimensional models
        if name.contains("minilm") || name.contains("small") || name.contains("e5-small")
            || name.contains("bge-small")
        {
            return 384
        }

        // 768-dimensional models (default for most)
        // nomic-embed-text, bge-base, e5-base, gte-base, etc.
        return 768
    }

    private func loadModels() async {
        isLoadingModels = true
        ollamaStatus = .checking
        do {
            let service = try OllamaService(baseURL: appState.settings.ollamaURL)
            availableModels = try await service.listModels()
            ollamaStatus = .connected

            if appState.settings.embeddingBackend != EmbeddingBackendKind.openai.rawValue
                && !availableModels.isEmpty
                && !embeddingModels.contains(where: { $0.name == appState.settings.embeddingModel })
            {
                if let firstEmbedding = embeddingModels.first {
                    appState.settings.embeddingModel = firstEmbedding.name
                }
            }
            await applyProbedDimensions(for: appState.settings.embeddingModel)

        } catch {
            availableModels = []
            ollamaStatus = .failed
        }
        isLoadingModels = false
    }

    private func applyProbedDimensions(for model: String) async {
        do {
            let service = try OllamaService(baseURL: appState.settings.ollamaURL)
            appState.settings.embeddingDimensions = try await service.probeDimension(model: model)
        } catch {
            appState.settings.embeddingDimensions = dimensionsForModel(model)
        }
    }

    private func testDevboxConnection() async {
        devboxStatus = .checking
        devboxStatusMessage = "Contacting \(appState.settings.devboxWorkerURL)..."
        let message = await DevboxWorkerService().testConnection(
            baseURL: appState.settings.devboxWorkerURL,
            token: appState.settings.workerToken
        )
        devboxStatusMessage = message
        devboxStatus = message.hasPrefix("Connected") ? .connected : .failed
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

        // Reset existing connection to force reconnect with new settings
        appState.qdrantService = nil

        do {
            try await appState.ensureQdrantConnection()
            await appState.fetchCollections()
            qdrantStatus = .connected
        } catch is CancellationError {
            // Ignore cancellation - don't update status
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
                Link(
                    "GitHub Repository",
                    destination: URL(string: "https://github.com/hansdoebel/psd")!)
                Link(
                    "Docling Documentation",
                    destination: URL(string: "https://docling-project.github.io/docling/")!)
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await checkDoclingVersion()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func checkDoclingVersion() async {
        isCheckingDocling = true
        doclingUpdateStatus = nil

        let pipPath = "~/.chunky-venv/bin/pip".expandingTildeInPath

        // Check if venv exists
        if !FileManager.default.fileExists(atPath: pipPath) {
            doclingVersion = "venv not found"
            isCheckingDocling = false
            await checkLatestDoclingVersion()
            return
        }

        // Get installed version using pip show (more reliable than importing)
        do {
            let version = try await getDoclingVersionViaPip(pipPath: pipPath)
            doclingVersion = version
        } catch {
            doclingVersion = "Not installed"
        }

        // Check PyPI for latest version
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

                // Parse "Version: x.x.x" from pip show output
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

            // Set clean environment
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
                // Refresh version after a short delay to let pip finish cleanup
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                // Try to get the new version using pip show
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
            latestDoclingVersion = version  // They're now the same after update
        } catch {
            // Keep current version display
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
