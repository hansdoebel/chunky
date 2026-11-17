import AppKit
import SwiftUI

struct LocalQdrantPane: View {
    var automaticallyRefresh = true
    var showsDetails = true
    @State private var snapshot = LocalQdrantSnapshot()
    @State private var busy = false
    @State private var message = ""
    @State private var stopVM = false
    @State private var confirmStop = false
    @State private var operation: Task<Void, Never>?
    private let runtime = LocalQdrantRuntime()

    var body: some View {
        LocalQdrantControls(snapshot: snapshot, busy: busy, message: message,
                            refresh: { perform { } }, start: { perform { try await runtime.start() } },
                            stop: { stopVM = false; confirmStop = true },
                            stopProfile: { stopVM = true; confirmStop = true },
                            cancel: { operation?.cancel() },
                            showsDetails: showsDetails, openConfiguration: openConfiguration)
            .task { if automaticallyRefresh { perform { } } }
            .onDisappear { operation?.cancel() }
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

    private func openConfiguration() {
        guard !busy else { return }
        guard let url = runtime.existingConfigurationURL() else {
            message = "The dedicated profile configuration is no longer available. Check status and try again."
            return
        }
        if !NSWorkspace.shared.open(url) {
            message = "macOS could not open the configuration. Choose a text editor for YAML files in Finder."
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = ""
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await action()
                snapshot = try await runtime.refresh()
            } catch is CancellationError {
                message = "Operation cancelled. Refresh status before retrying; completed changes and stored data are retained."
                snapshot = LocalQdrantSnapshot(profile: "Status unknown", container: "Refresh to check")
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
    var cancel: () -> Void = {}
    var showsDetails = true
    var openConfiguration: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local database").font(.headline)
            Text("Start Qdrant on this Mac using a dedicated Colima VM named chunky.")
                .font(.body).foregroundStyle(.secondary)
            HStack {
                statusRow("Colima VM", status: snapshot.profile, state: snapshot.profileState)
                Spacer()
                Button("Stop VM", action: stopProfile)
                    .disabled(busy || snapshot.profileState != .running)
            }
            HStack {
                statusRow("Qdrant", status: snapshot.container, state: snapshot.containerState)
                Spacer()
                if snapshot.running {
                    Button("Stop Qdrant", action: stop).disabled(busy)
                } else {
                    Button("Start Qdrant", action: start).disabled(busy)
                }
            }
            HStack {
                Button("Check status", action: refresh).disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel operation", action: cancel)
                }
            }
            Text("Runtime status does not verify a database connection. Use the Qdrant connection check before importing.")
                .font(.body).foregroundStyle(.secondary)
            if showsDetails {
                Divider()
                if snapshot.profileState == .absent {
                    Text("New VM defaults: 2 CPUs · 4 GiB memory · 30 GiB disk")
                        .font(.body)
                } else {
                    LabeledContent("Configured CPUs", value: snapshot.cpus.map(String.init) ?? "Not reported")
                    LabeledContent("Configured memory", value: capacity(snapshot.memoryBytes))
                    LabeledContent("Configured disk capacity", value: capacity(snapshot.diskBytes))
                    Text("Allocated capacity, not current usage. Existing VM settings are preserved.")
                        .font(.body).foregroundStyle(.secondary)
                }
                Button("Open configuration", action: openConfiguration)
                    .disabled(busy || snapshot.configurationURL == nil)
                    .help("Open the existing ~/.colima/chunky/colima.yaml in its default editor. Chunky does not change this file.")
                Text("REST http://127.0.0.1:6333 · gRPC 127.0.0.1:6334")
                    .font(.body).textSelection(.enabled)
                Text("Qdrant 1.20.2 · Storage: chunky-qdrant-data. First start downloads the VM and image. Stopping retains collections. Connection settings are not changed.")
                    .font(.body).foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Label("Action needs attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message).font(.body).textSelection(.enabled)
                Button("Copy details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func statusRow(_ title: String, status: String, state: LocalRuntimeState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Label(status, systemImage: state == .running ? "checkmark.circle.fill" :
                    state == .stopped || state == .unavailable ? "stop.circle.fill" : "questionmark.circle")
                .font(.body)
                .foregroundStyle(state == .running ? Color.green :
                    state == .stopped || state == .unavailable ? Color.red : Color.secondary)
        }
    }

    private func capacity(_ bytes: Int64?) -> String {
        guard let bytes else { return "Not reported" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
