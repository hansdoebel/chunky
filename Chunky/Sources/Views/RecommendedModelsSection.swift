import SwiftUI

struct RecommendedModelsSection: View {
    var host: ProcessingHost
    var installed: [ManagedModel]
    var downloading: Set<String>
    var statusMessage: String
    var onDownload: (String) -> Void

    private var models: [ManagedModel] {
        let listed = ModelCatalog.visible(ModelCatalog.recommended(host: host), host: host)
        return ModelCatalog.marking(listed, inventory: installed, downloading: downloading)
    }

    var body: some View {
        Section {
            ForEach(models) { model in
                HStack {
                    Text(model.name)
                    Spacer()
                    Text(model.state.rawValue)
                        .foregroundStyle(.secondary)
                    if !model.sizeLabel.isEmpty {
                        Text(model.sizeLabel)
                            .foregroundStyle(.secondary)
                    }
                    if model.state == .missing && host == .devbox {
                        Button("Download") { onDownload(model.name) }
                    }
                }
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recommended models")
        } footer: {
            Text(host == .devbox
                 ? "Devbox: qwen3-embedding, granite-docling, and granite-vision. MLX models stay on the Mac. The worker reports what is actually cached."
                 : "Mac: Granite-Docling MLX. A devbox download uses the worker token.")
        }
    }
}
