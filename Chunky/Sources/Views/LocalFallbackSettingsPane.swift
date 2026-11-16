import SwiftUI

struct LocalFallbackSettingsPane: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use Local Mac if the worker is unreachable", isOn: $enabled)
            Text("Off by default. Checks before uploading; never retries a submitted job. Requires local services and a matching Local Docker collection plan for ingest. Cloud jobs keep their configured target and fail clearly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
