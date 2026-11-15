import SwiftUI

struct NewCollectionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var preset: CollectionPreset = .recommended
    @State private var plan: CollectionPlan
    @State private var vectorVerified = false
    @State private var probeMessage = "Vector size is unverified until a probe succeeds."

    init(vectorSize: Int, embeddingBackend: String, embeddingModel: String) {
        _plan = State(initialValue: CollectionPlan.preset(
            .recommended,
            name: "",
            vectorSize: vectorSize,
            embeddingBackend: embeddingBackend,
            embeddingModel: embeddingModel
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New collection")
                .font(.title2)
            Picker("Preset", selection: $preset) {
                ForEach(CollectionPreset.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .onChange(of: preset) { _, newValue in
                let name = plan.name
                plan = CollectionPlan.preset(
                    newValue,
                    name: name,
                    vectorSize: plan.vectorSize,
                    embeddingBackend: plan.embeddingBackend,
                    embeddingModel: plan.embeddingModel
                )
            }
            TextField("Name", text: $plan.name)
            Picker("Target", selection: $plan.target) {
                ForEach(CollectionTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            LabeledContent("Embedding", value: "\(plan.embeddingBackend) · \(plan.embeddingModel)")
            LabeledContent("Vector size", value: vectorVerified ? "\(plan.vectorSize)" : "unverified")
            Text(probeMessage)
                .font(.caption)
                .foregroundStyle(vectorVerified ? Color.secondary : Color.orange)
            Text(plan.vectorSizeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Distance", selection: $plan.distance) {
                ForEach(CollectionDistance.allCases) { distance in
                    Text(distance.displayName).tag(distance)
                }
            }
            Text(plan.distance.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Hybrid dense + sparse", isOn: $plan.hybrid)
            Text(plan.hybridHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Quantization", selection: $plan.quantization) {
                ForEach(CollectionQuantization.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            Text(plan.quantization.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning = plan.binaryWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("On-disk vectors and payload", isOn: $plan.onDisk)
            Text(plan.storageHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("Expected chunks: \(plan.expectedChunks)", value: $plan.expectedChunks, in: 0...10_000_000, step: 1000)
            let estimate = plan.estimate()
            Text("Estimate: \(format(estimate.ramBytes)) RAM, \(format(estimate.diskBytes)) disk. This is an estimate.")
                .font(.caption)
            if let nameError = CollectionPlan.nameError(plan.name) {
                Text(nameError).font(.caption).foregroundStyle(.red)
            }
            if let exists = plan.existsWarning(existingNames: appState.availableCollections) {
                Text(exists).font(.caption).foregroundStyle(.orange)
            }
            if let connectionProblem {
                Text(connectionProblem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await probe() }
    }

    private var connectionProblem: String? {
        plan.connectionProblem(
            localURL: appState.settings.qdrantURL,
            cloudURL: appState.settings.qdrantCloudURL,
            cloudAPIKey: appState.settings.qdrantAPIKey
        )
    }

    private var canSave: Bool {
        CollectionPlan.canSave(
            name: plan.name,
            vectorVerified: vectorVerified,
            connectionProblem: connectionProblem
        )
    }

    private func probe() async {
        probeMessage = "Probing \(plan.embeddingModel)..."
        do {
            let size = try await EmbeddingDimensionProbe.probe(
                backend: plan.embeddingBackend,
                model: plan.embeddingModel,
                ollamaURL: appState.settings.ollamaURL,
                apiURL: appState.settings.embeddingAPIURL
            )
            plan.vectorSize = size
            vectorVerified = true
            probeMessage = "Probed vector size \(size). \(plan.vectorSizeHint)"
        } catch {
            vectorVerified = false
            probeMessage = "Vector size is unverified. The probe failed, so Save stays off."
        }
    }

    private func save() {
        guard canSave else { return }
        CollectionPlanStore.save(plan)
        appState.settings.devboxIngestTarget = plan.target == .qdrantCloud ? .qdrantCloud : .localDocker
        appState.settings.hybridSearch = plan.hybrid
        appState.settings.qdrantDistanceMetric = plan.distance.settingsValue
        appState.settings.qdrantCompression = plan.quantization.settingsValue
        appState.settings.embeddingDimensions = plan.vectorSize
        if !appState.availableCollections.contains(plan.name) {
            appState.availableCollections.append(plan.name)
        }
        appState.settings.defaultCollection = plan.name
        dismiss()
    }

    private func format(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        return String(format: "%.0f KB", bytes / 1000)
    }
}
