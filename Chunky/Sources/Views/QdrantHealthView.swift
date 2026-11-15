import SwiftUI

struct QdrantHealthScreen: View {
    var report: QdrantHealthReport
    var status: String
    var cloud: CloudOverview?
    var cloudStatus: String
    var accountID: String
    var clusterID: String
    var managementKey: String
    var keepAlive: Bool
    var onAccount: (String) -> Void
    var onCluster: (String) -> Void
    var onManagementKey: (String) -> Void
    var onKeepAlive: (Bool) -> Void
    var onUnsuspend: () -> Void
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
                cloudSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Qdrant Cloud")
                .font(.headline)
            Text("Optional. The management key stays in the Keychain and is separate from the database API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Account ID", text: Binding(get: { accountID }, set: onAccount))
                .textFieldStyle(.roundedBorder)
            TextField("Cluster ID", text: Binding(get: { clusterID }, set: onCluster))
                .textFieldStyle(.roundedBorder)
            SecureField("Cloud management key", text: Binding(get: { managementKey }, set: onManagementKey))
                .textFieldStyle(.roundedBorder)
            Toggle("Keep-alive ping", isOn: Binding(get: { keepAlive }, set: onKeepAlive))
            Text("Off unless you turn it on. A daily database request can keep a free cluster from suspending after a week idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let cloud {
                Text(cloud.name.isEmpty ? cloud.phase : "\(cloud.name) · \(cloud.phase)")
                    .font(.headline)
                Text([cloud.version, cloud.nodesUp.map { "\($0) nodes up" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !cloud.ram.isEmpty || !cloud.disk.isEmpty || !cloud.cpu.isEmpty {
                    Text("Allocated RAM \(cloud.ram) · disk \(cloud.disk) · CPU \(cloud.cpu)")
                        .font(.caption)
                }
                Text("Alerts \(cloud.alerts.count) · events \(cloud.events) · logs \(cloud.logs) · usage points \(cloud.usagePoints)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tokens = cloud.inferenceTokens {
                    Text("Inference tokens \(Int(tokens))")
                        .font(.caption)
                }
                ForEach(cloud.alerts, id: \.self) { alert in
                    Text(alert)
                        .font(.callout)
                        .foregroundStyle(AppTheme.statusOrange)
                }
                if let warning = cloud.keyWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(AppTheme.statusOrange)
                }
                if cloud.canUnsuspend {
                    Button("Unsuspend", action: onUnsuspend)
                        .buttonStyle(.borderedProminent)
                }
            }
            if !cloudStatus.isEmpty {
                Text(cloudStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
    @State private var cloud: CloudOverview?
    @State private var cloudStatus = ""
    @State private var accountID = ""
    @State private var clusterID = ""
    @State private var managementKey = ""

    var body: some View {
        QdrantHealthScreen(
            report: report,
            status: status,
            cloud: cloud,
            cloudStatus: cloudStatus,
            accountID: accountID,
            clusterID: clusterID,
            managementKey: managementKey,
            keepAlive: appState.settings.qdrantKeepAlive,
            onAccount: { accountID = $0; appState.settings.qdrantCloudAccountID = $0 },
            onCluster: { clusterID = $0; appState.settings.qdrantCloudClusterID = $0 },
            onManagementKey: { managementKey = $0; appState.settings.qdrantCloudManagementKey = $0 },
            onKeepAlive: { appState.settings.qdrantKeepAlive = $0 },
            onUnsuspend: { Task { await unsuspend() } },
            onRefresh: { Task { await load() } },
            onClose: { dismiss() }
        )
            .frame(minWidth: 640, minHeight: 520)
            .task {
                accountID = appState.settings.qdrantCloudAccountID
                clusterID = appState.settings.qdrantCloudClusterID
                managementKey = appState.settings.qdrantCloudManagementKey
                await load()
            }
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
        await loadCloud()
    }

    private func loadCloud() async {
        let settings = appState.settings
        guard !accountID.isEmpty, !clusterID.isEmpty, !managementKey.isEmpty else {
            cloud = nil
            cloudStatus = "Add an account ID, cluster ID, and management key to read cluster phase."
            return
        }
        let client = CloudManagementClient(transport: LiveCloudManagementTransport())
        do {
            cloud = try await client.load(accountID: accountID, clusterID: clusterID, managementKey: managementKey, now: Date())
            cloudStatus = "Cloud management key accepted."
        } catch {
            cloud = nil
            cloudStatus = error.localizedDescription
        }
    }

    private func unsuspend() async {
        let client = CloudManagementClient(transport: LiveCloudManagementTransport())
        do {
            try await client.unsuspend(accountID: accountID, clusterID: clusterID, managementKey: managementKey)
            cloudStatus = "Unsuspend requested."
            await loadCloud()
        } catch {
            cloudStatus = error.localizedDescription
        }
    }
}
