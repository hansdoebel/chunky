import SwiftUI

struct WorkerEndpointsPane: View {
    var endpoints: [WorkerEndpoint]
    var selectedID: UUID?
    var activeID: UUID?
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
            Text("Save stores the name, URL, and Keychain token. Use applies that profile to new documents.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(endpoints) { endpoint in
                let selected = endpoint.id == selectedID
                let active = endpoint.id == activeID
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name)
                            .font(.body.weight(.medium))
                        Text(endpoint.url.isEmpty ? "URL not set" : PreferenceDiagnostic.message(endpoint.url, secrets: [token]))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if active {
                        Text("In use")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(8)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(endpoint.id) }
            }
            TextField("Name", text: Binding(get: { name }, set: onName))
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)
            TextField("Worker URL", text: Binding(get: { url }, set: onURL), prompt: Text("http://host:8080 or https://host"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)
            SecureField("Worker token", text: Binding(get: { token }, set: onToken))
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)
            HStack {
                Button("Save", action: onSave)
                Button("Use", action: onUse)
                Button("Check reachability", action: onCheck)
            }
            if let report {
                PreferenceMessage(context: "Worker check", message: report.message, secrets: [token], isError: report.kind != .connected)
                Text("Latency \(report.latencyMs) ms")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppTheme.surfaceGrouped)
    }
}
