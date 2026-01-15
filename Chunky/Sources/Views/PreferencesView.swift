import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings: AppSettings = AppSettings()
    @State private var availableModels: [OllamaModel] = []
    @State private var availableVLMModels: [DoclingModel] = []
    @State private var isLoadingModels = false
    @State private var ollamaStatus: ConnectionStatus = .unknown
    @State private var qdrantStatus: ConnectionStatus = .unknown
    @State private var selectedTab = 0

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
        }
        .frame(width: 500, height: 420)
        .onAppear {
            settings = appState.settings
            Task { await loadModels() }
        }
        .onDisappear {
            saveSettings()
        }
    }

    private var embeddingTab: some View {
        Form {
            Section {
                HStack {
                    TextField(
                        "Server URL", text: $settings.ollamaURL,
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
                    Picker("Model", selection: $settings.embeddingModel) {
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

                    LabeledContent("Vector Dimensions") {
                        Text("\(settings.embeddingDimensions)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                Button("Refresh Models") {
                    Task { await loadModels() }
                }
                .disabled(isLoadingModels)
            } header: {
                Text("Embedding Model")
            }

            Section {
                StepperRow(label: "Batch Size", value: $settings.embeddingBatchSize, range: 1...50)
                StepperRow(
                    label: "Concurrency", value: $settings.embeddingConcurrency, range: 1...10)
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
                if availableVLMModels.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("No VLM models found. Pull a model like 'granite-docling' via Ollama.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Picker("VLM Model", selection: $settings.doclingModel) {
                        ForEach(availableVLMModels, id: \.rawValue) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model.rawValue)
                        }
                    }
                }
            } header: {
                Text("Document Model")
            }

            Section {
                StepperRow(label: "Workers", value: $settings.doclingWorkers, range: 1...8)

                Picker("Accelerator", selection: $settings.doclingAccelerator) {
                    ForEach(Accelerator.allCases, id: \.rawValue) { acc in
                        Text(acc.displayName).tag(acc.rawValue)
                    }
                }

                StepperRow(
                    label: "Timeout", value: $settings.doclingTimeout, range: 60...600, step: 30,
                    suffix: "s")

                LabeledContent("Max Pages") {
                    HStack(spacing: 8) {
                        Text(
                            settings.doclingMaxPages == 0
                                ? "Unlimited" : "\(settings.doclingMaxPages)"
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                        Stepper("", value: $settings.doclingMaxPages, in: 0...1000, step: 10)
                            .labelsHidden()
                    }
                }

                StepperRow(
                    label: "Max Tokens/Chunk", value: $settings.maxTokensPerChunk,
                    range: 128...2048, step: 128)
            } header: {
                Text("Processing")
            }

            Section {
                Toggle("Table Extraction", isOn: $settings.doTableExtraction)

                if settings.doTableExtraction {
                    Picker("Table Mode", selection: $settings.tableMode) {
                        ForEach(TableMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                }

                Toggle("OCR (for scanned documents)", isOn: $settings.doOCR)
            } header: {
                Text("Features")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var qdrantTab: some View {
        Form {
            Section {
                HStack {
                    TextField(
                        "Server URL", text: $settings.qdrantURL,
                        prompt: Text("https://xxx.cloud.qdrant.io:6334")
                    )
                    .textFieldStyle(.roundedBorder)

                    Button(action: { Task { await checkQdrant() } }) {
                        switch qdrantStatus {
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

                SecureField(
                    "API Key", text: $settings.qdrantAPIKey, prompt: Text("Your Qdrant API key")
                )
                .textFieldStyle(.roundedBorder)
            } header: {
                Text("Connection")
            }

            Section {
                StepperRow(
                    label: "Batch Size", value: $settings.qdrantBatchSize, range: 10...1000,
                    step: 10)
                StepperRow(
                    label: "Timeout", value: $settings.qdrantTimeout, range: 10...120, step: 10,
                    suffix: "s")
                StepperRow(label: "Connection Pool", value: $settings.qdrantPoolSize, range: 1...10)

                Picker("Compression", selection: $settings.qdrantCompression) {
                    ForEach(Compression.allCases, id: \.rawValue) { comp in
                        Text(comp.displayName).tag(comp.rawValue)
                    }
                }
            } header: {
                Text("Upload")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var exportTab: some View {
        Form {
            Section {
                Picker("Format", selection: $settings.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
            } header: {
                Text("Export Format")
            }

            if settings.exportFormat != "none" {
                Section {
                    HStack {
                        if settings.exportFolder.isEmpty {
                            Text("No folder selected")
                                .foregroundColor(.secondary)
                        } else {
                            Text(settings.exportFolder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button("Choose...") {
                            selectExportFolder()
                        }
                    }
                } header: {
                    Text("Output Folder")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var embeddingModels: [OllamaModel] {
        let embeddingKeywords = ["embed", "nomic", "minilm", "bge", "e5", "gte", "arctic"]
        return availableModels.filter { model in
            let name = model.name.lowercased()
            return embeddingKeywords.contains { name.contains($0) }
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        ollamaStatus = .checking
        do {
            let service = try OllamaService(baseURL: settings.ollamaURL)
            availableModels = try await service.fetchAvailableModels()
            ollamaStatus = .connected

            if !availableModels.isEmpty
                && !embeddingModels.contains(where: { $0.name == settings.embeddingModel })
            {
                if let firstEmbedding = embeddingModels.first {
                    settings.embeddingModel = firstEmbedding.name
                }
            }

            let modelNames = Set(
                availableModels.map {
                    $0.name.lowercased().replacingOccurrences(of: ":latest", with: "")
                })
            availableVLMModels = DoclingModel.allCases.filter { model in
                if model == .standard { return true }
                return modelNames.contains(model.rawValue)
            }

            if !availableVLMModels.contains(where: { $0.rawValue == settings.doclingModel }) {
                settings.doclingModel = DoclingModel.standard.rawValue
            }
        } catch {
            availableModels = []
            availableVLMModels = [.standard]
            ollamaStatus = .failed
        }
        isLoadingModels = false
    }

    private func checkOllama() async {
        ollamaStatus = .checking
        do {
            let service = try OllamaService(baseURL: settings.ollamaURL)
            _ = try await service.fetchAvailableModels()
            ollamaStatus = .connected
        } catch {
            ollamaStatus = .failed
        }
    }

    private func checkQdrant() async {
        qdrantStatus = .checking

        guard !settings.qdrantURL.isEmpty else {
            qdrantStatus = .failed
            return
        }

        guard let url = URL(string: settings.qdrantURL) else {
            qdrantStatus = .failed
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            if !settings.qdrantAPIKey.isEmpty {
                request.setValue(settings.qdrantAPIKey, forHTTPHeaderField: "api-key")
            }

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 401
            {
                qdrantStatus = .connected
            } else {
                qdrantStatus = .failed
            }
        } catch {
            qdrantStatus = .failed
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
            settings.exportFolder = url.path
        }
    }

    private func saveSettings() {
        settings.save()
        appState.settings = settings
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
