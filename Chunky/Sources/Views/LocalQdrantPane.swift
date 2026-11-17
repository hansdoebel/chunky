import SwiftUI

struct LocalQdrantPane: View {
    @State private var snapshot = LocalQdrantSnapshot()
    @State private var busy = false
    @State private var message = ""
    @State private var stopVM = false
    @State private var confirmStop = false
    private let runtime = LocalQdrantRuntime()

    var body: some View {
        LocalQdrantControls(snapshot: snapshot, busy: busy, message: message,
                            refresh: { perform { } }, start: { perform { try await runtime.start() } },
                            stop: { stopVM = false; confirmStop = true },
                            stopProfile: { stopVM = true; confirmStop = true })
            .task { perform { } }
            .confirmationDialog(stopVM ? "Stop the Chunky Colima VM?" : "Stop local Qdrant?", isPresented: $confirmStop) {
                Button("Stop", role: .destructive) {
                    perform {
                        if stopVM { try await runtime.stopProfile() }
                        else { try await runtime.stopContainer() }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Active requests to this local database will fail until restarted. Stored collections are retained. Unrelated containers and profiles will not be stopped.")
            }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = ""
        Task {
            defer { busy = false }
            do {
                try await action()
                snapshot = try await runtime.refresh()
            } catch {
                message = error.localizedDescription
                snapshot = LocalQdrantSnapshot(profile: "Status unknown", container: "Refresh after resolving the error")
            }
        }
    }
}

struct LocalQdrantControls: View {
    let snapshot: LocalQdrantSnapshot
    let busy: Bool
    let message: String
    let refresh: () -> Void
    let start: () -> Void
    let stop: () -> Void
    let stopProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Qdrant with Colima").font(.headline)
            Text("Dedicated chunky VM · Qdrant 1.20.2").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Colima", value: snapshot.profile)
            LabeledContent("Qdrant container", value: snapshot.container)
            HStack {
                Button("Refresh", action: refresh)
                Button("Start Qdrant", action: start).disabled(snapshot.running)
                if busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("Stop Qdrant", action: stop).disabled(!snapshot.running)
                Button("Stop VM", action: stopProfile).disabled(snapshot.profile != "Running")
            }
            Text("REST http://127.0.0.1:6333 · gRPC 127.0.0.1:6334")
                .font(.caption).textSelection(.enabled)
            Text("Persistent storage: chunky-qdrant-data. Start may download the VM and image. Ports must be free. Connection settings are not changed; select this local endpoint below when ready.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .disabled(busy)
        .accessibilityElement(children: .contain)
    }
}
