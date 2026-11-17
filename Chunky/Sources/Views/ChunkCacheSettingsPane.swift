import SwiftUI

struct ChunkCacheSettingsPane: View {
    @Binding var limitMB: Int
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $limitMB, in: 0...10240, step: 256) {
                Text(limitMB == 0 ? "Size limit: none" : "Size limit: \(limitMB) MB")
            }
            Text("Least recently used conversions are removed when the cache passes this limit. 0 keeps every entry.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Clear cache", action: onClear)
            Text("Re-ingest skips Docling when the PDF, Docling version, pipeline, and chunker settings match. A stored vector for the same embedding model skips embedding too.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
