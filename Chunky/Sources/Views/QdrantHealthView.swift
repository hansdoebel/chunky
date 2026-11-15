import SwiftUI

struct QdrantHealthScreen: View {
    var report: QdrantHealthReport
    var status: String
    var onRefresh: () -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Qdrant usage")
                        .font(.title2)
                    Spacer()
                    Button("Refresh", action: onRefresh)
                    Button("Close", action: onClose)
                }
                if !report.source.isEmpty {
                    Text(report.source)
                        .font(.caption.weight(.semibold))
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if report.recoveryMode {
                    Text("Recovery mode. Searches and updates can fail until Qdrant finishes recovering.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.statusOrange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.statusOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(AppTheme.statusOrange)
                }
                meter("RAM", used: report.ramBytes, limit: report.ramLimitBytes)
                meter("Disk", used: report.diskBytes, limit: report.diskLimitBytes)
                HStack(spacing: 16) {
                    count("Collections", report.collections)
                    count("Points", report.points)
                    count("Vectors", report.vectors)
                }
                if report.cpuThrottled {
                    Text("CPU throttling recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let collection = report.collection {
                    Divider()
                    Text(collection.name)
                        .font(.headline)
                    Text("\(collection.status.capitalized) · optimizer \(collection.optimizer)")
                        .font(.callout)
                    if !collection.summary.isEmpty {
                        Text(collection.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(collection.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(AppTheme.statusOrange)
                    }
                }
                if !report.memory.isEmpty {
                    Divider()
                    Text("Memory")
                        .font(.headline)
                    ForEach(report.memory) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text("disk \(ByteText.string(row.disk)) · RAM \(ByteText.string(row.ram)) · cache \(ByteText.string(row.cached))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let note = report.memoryNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func meter(_ title: String, used: Double?, limit: Double?) -> some View {
        let ratio = QdrantHealth.ratio(used, limit)
        let warn = (ratio ?? 0) >= QdrantHealth.alertRatio
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(meterText(used: used, limit: limit, ratio: ratio))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(warn ? AppTheme.statusOrange : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.16))
                    Capsule()
                        .fill(warn ? AppTheme.statusOrange : AppTheme.accentFallback)
                        .frame(width: geo.size.width * min(max(ratio ?? 0, 0), 1))
                }
            }
            .frame(height: 8)
        }
    }

    private func meterText(used: Double?, limit: Double?, ratio: Double?) -> String {
        let usedText = used.map(ByteText.string) ?? "not reported"
        if let limit, let ratio {
            return "\(usedText) of \(ByteText.string(limit)) · \(QdrantHealth.percent(ratio))"
        }
        return usedText
    }

    private func count(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { String(Int($0)) } ?? "—")
                .font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QdrantHealthRoot: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var report = QdrantHealthReport.empty
    @State private var status = "Loading usage."

    var body: some View {
        QdrantHealthScreen(report: report, status: status, onRefresh: { Task { await load() } }, onClose: { dismiss() })
            .frame(minWidth: 640, minHeight: 520)
            .task { await load() }
    }

    private func load() async {
        let settings = appState.settings
        let collection = settings.defaultCollection
        let client = QdrantHealthClient(transport: LiveQdrantHealthTransport())
        let loaded = await client.load(
            baseURL: settings.qdrantURL,
            apiKey: settings.qdrantAPIKey,
            collection: collection,
            lastSuccess: settings.qdrantLastSuccessAt,
            now: Date(),
            previousThrottle: settings.qdrantThrottleCount
        )
        report = loaded
        if loaded.source.isEmpty {
            status = loaded.memoryNote ?? "Qdrant metrics could not be loaded."
        } else {
            settings.noteQdrantSuccess()
            if let count = loaded.cpuThrottleCount {
                settings.qdrantThrottleCount = count
            }
            status = collection.isEmpty ? "Choose a collection to see its memory." : "Updated \(collection)."
        }
    }
}
