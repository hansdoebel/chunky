import SwiftUI

struct WorkerEndpointsPane: View {
    var endpoints: [WorkerEndpoint]
    var selectedID: UUID?
    var name: String
    var url: String
    var token: String
    var report: WorkerProbeReport?
    var onSelect: (UUID) -> Void
    var onName: (String) -> Void
    var onURL: (String) -> Void
    var onToken: (String) -> Void
    var onSave: () -> Void
    var onUse: () -> Void
    var onCheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Worker endpoints")
                .font(.headline)
            Text("Each profile is a name, a URL, and a token. The token stays in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(endpoints) { endpoint in
                let selected = endpoint.id == selectedID
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name)
                            .font(.body.weight(.medium))
                        Text(endpoint.url.isEmpty ? "URL not set" : endpoint.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(8)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(endpoint.id) }
            }
            TextField("Name", text: Binding(get: { name }, set: onName))
                .textFieldStyle(.roundedBorder)
            TextField("Worker URL", text: Binding(get: { url }, set: onURL), prompt: Text("http://host:8080 or https://host"))
                .textFieldStyle(.roundedBorder)
            SecureField("Worker token", text: Binding(get: { token }, set: onToken))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save", action: onSave)
                Button("Use", action: onUse)
                Button("Check reachability", action: onCheck)
            }
            if let report {
                Text(report.message)
                    .font(.caption)
                    .foregroundStyle(report.kind == .connected ? Color.secondary : Color.red)
                Text("Latency \(report.latencyMs) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppTheme.surfaceGrouped)
    }
}
