import SwiftUI

struct CollectionPackingScreen: View {
    var collection: String
    var packing: CollectionPacking
    var status: String
    var onVectors: (MemoryTier) -> Void
    var onHNSW: (MemoryTier) -> Void
    var onQuantizationTier: (MemoryTier) -> Void
    var onPayload: (MemoryTier) -> Void
    var onQuantization: (CollectionQuantization) -> Void
    var onApply: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pack \(collection.isEmpty ? "collection" : collection)")
                    .font(.title2)
                Spacer()
                Button("Close", action: onClose)
            }
            Text(packing.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            tierPicker("Vectors", selection: packing.vectors, onChange: onVectors)
            tierPicker("HNSW", selection: packing.hnsw, onChange: onHNSW)
            tierPicker("Quantized vectors", selection: packing.quantizationTier, onChange: onQuantizationTier)
            tierPicker("Payload", selection: packing.payload, onChange: onPayload)
            Picker("Quantization", selection: Binding(get: { packing.quantization }, set: onQuantization)) {
                ForEach(CollectionQuantization.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            if let error = packing.tierError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(AppTheme.statusRed)
            }
            Button("Apply to collection", action: onApply)
                .buttonStyle(.borderedProminent)
                .disabled(collection.isEmpty || packing.tierError != nil)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This updates the existing collection. Free Qdrant Cloud has no scheduled backups, so keep a local snapshot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tierPicker(_ title: String, selection: MemoryTier, onChange: @escaping (MemoryTier) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: onChange)) {
            ForEach(MemoryTier.allCases) { tier in
                Text(tier.displayName).tag(tier)
            }
        }
    }
}

struct CollectionPackingRoot: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var packing = CollectionPacking.freeTier
    @State private var status = "Choose tiers, then apply them to the current collection."

    var body: some View {
        CollectionPackingScreen(
            collection: appState.settings.defaultCollection,
            packing: packing,
            status: status,
            onVectors: { packing.vectors = $0 },
            onHNSW: { packing.hnsw = $0 },
            onQuantizationTier: { packing.quantizationTier = $0 },
            onPayload: { packing.payload = $0 },
            onQuantization: { packing.quantization = $0 },
            onApply: { Task { await apply() } },
            onClose: { dismiss() }
        )
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            let name = appState.settings.defaultCollection
            if let stored = CollectionPackingStore.load(name: name, defaults: appState.settings.defaults) {
                packing = stored
            }
        }
    }

    private func apply() async {
        let name = appState.settings.defaultCollection
        let client = CollectionPackingClient(transport: LiveCollectionPackingTransport())
        do {
            try await client.update(
                baseURL: appState.settings.qdrantURL,
                apiKey: appState.settings.qdrantAPIKey,
                collection: name,
                packing: packing
            )
            CollectionPackingStore.save(packing, name: name, defaults: appState.settings.defaults)
            status = "Updated \(name)."
        } catch {
            status = error.localizedDescription
        }
    }
}
