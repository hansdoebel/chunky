import SwiftUI

struct EmbeddingCacheSettingsPane: View {
    @Binding var streaming: Bool
    @Binding var reuseEmbeddings: Bool
    var host: ProcessingHost

    var body: some View {
        Toggle("Streaming Pipeline", isOn: $streaming)
            .disabled(host == .devbox)
        Toggle("Reuse embeddings in Qdrant", isOn: $reuseEmbeddings)
            .disabled(host == .devbox)
        Text(explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("The separate chunk cache can reuse conversions and matching model/dimension vectors in either pipeline. Manage it in About, Chunk cache.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var explanation: String {
        if host == .devbox {
            return "These controls apply to Local Mac ingest. Devbox jobs use the worker's chunk cache. Your local preferences are kept."
        }
        if streaming {
            return "Fresh streaming batches skip the Qdrant reuse lookup. When the chunk cache supplies all vectors, Qdrant reuse still applies even with streaming on. Turn streaming off to check Qdrant for other imports too."
        }
        return "With streaming off, reuse skips embedding unchanged chunks already in the target Qdrant collection for the same source, library, and model."
    }
}
