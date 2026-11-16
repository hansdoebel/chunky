import SwiftUI

struct CPUEmbeddingSettingsPane: View {
    var processingHost: ProcessingHost
    var readiness: String
    var busy: Bool
    var problem: String?
    var onCheck: () -> Void
    var onDownload: () -> Void

    var body: some View {
        Section("Local CPU model") {
            LabeledContent("Model", value: EmbeddingPreferences.cpuModel)
                .textSelection(.enabled)
            LabeledContent("Vector dimensions", value: "\(EmbeddingPreferences.cpuDimensions)")
            LabeledContent("Processing host", value: processingHost.rawValue)
            LabeledContent("Embedding host", value: "Local Mac")
            LabeledContent("Runtime", value: "FastEmbed · NumPy CPU")
            Label(readiness, systemImage: busy ? "hourglass" : "internaldrive")
                .font(.caption)
                .accessibilityIdentifier("cpu-embedding-readiness")
            HStack {
                Button("Check readiness", action: onCheck)
                Button("Download model", action: onDownload)
            }
            .disabled(busy)
            Text("Download once while online. Cached models work offline. Checking readiness does not download a model. Document and query vectors must use the same model; existing collections are never converted automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }
}

struct EmbeddingJobSummary: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var readiness: CPUEmbeddingReadiness = .shared
    var jobs: [ProcessingJob] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Processing: \(settings.processingHost.rawValue) · Embedding: \(settings.embeddingHostDescription)")
            Text("\(EmbeddingBackendKind(rawValue: settings.embeddingBackend)?.displayName ?? settings.embeddingBackend) · \(settings.embeddingModel) · \(settings.embeddingDimensions) dimensions")
                .textSelection(.enabled)
            if settings.embeddingBackend == "fastembed" {
                Text("NumPy CPU · \(readiness.message)")
            }
            if let problem = jobs.isEmpty ? settings.embeddingConfigurationProblem : settings.embeddingConfigurationProblem(jobs: jobs) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: settings.embeddingBackend + settings.embeddingModel) {
            guard settings.embeddingBackend == "fastembed" else { return }
            await readiness.checkIfNeeded(model: settings.embeddingModel)
        }
    }
}
