import Charts
import SwiftUI

struct AnalyticsView: View {
    var runs: [RunDraft]
    @State private var group: RunGroup
    @State private var selectedID: UUID?

    init(runs: [RunDraft], group: RunGroup = .host, selectedID: UUID? = nil) {
        self.runs = runs
        _group = State(initialValue: group)
        _selectedID = State(initialValue: selectedID ?? runs.first?.runID)
    }

    private var selected: RunDraft? {
        runs.first { $0.runID == selectedID } ?? runs.first
    }

    private var sameFile: [RunDraft] {
        guard let selected else { return [] }
        return runs.filter { $0.contentHash == selected.contentHash }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Runs")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                if runs.isEmpty {
                    Text("No finished jobs yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(runs) { run in
                            runRow(run)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 240)
            .background(Color.gray.opacity(0.08))

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                if let selected {
                    PostJobPanel(run: selected)
                    comparison
                    if sameFile.count > 1 {
                        sameFileChart
                    }
                } else {
                    Text("Finish a job to see stage timings.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("History stores timings only. Vectors and API keys are not kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.white)
        .onChange(of: runs) { _, updated in
            let current = selectedID
            if current == nil || !updated.contains(where: { $0.runID == current }) {
                selectedID = updated.first?.runID
            }
        }
    }

    private func runRow(_ run: RunDraft) -> some View {
        let isSelected = run.runID == selected?.runID
        return VStack(alignment: .leading, spacing: 2) {
            Text(run.fileName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text("\(run.host) · \(run.runtime)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = run.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = run.runID }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compare by")
                    .font(.headline)
                ForEach(RunGroup.allCases) { item in
                    Text(item.title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(group == item ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12), in: Capsule())
                        .onTapGesture { group = item }
                }
            }
            Chart(RunHistory.aggregate(runs, by: group)) { bucket in
                BarMark(
                    x: .value(group.title, bucket.key),
                    y: .value("Embeddings/s", bucket.averageEmbeddingsPerSecond ?? 0)
                )
                .foregroundStyle(by: .value(group.title, bucket.key))
            }
            .chartYAxisLabel("Embeddings/s")
            .frame(height: 180)
        }
    }

    private var sameFileChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Same file")
                .font(.headline)
            Text(selected?.fileName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(sameFile) { run in
                BarMark(
                    x: .value("Run", run.createdAt),
                    y: .value("Wall ms", run.wallMs)
                )
                .foregroundStyle(by: .value("Host", run.host))
            }
            .chartXAxis(.hidden)
            .frame(height: 140)
        }
    }
}

struct PostJobPanel: View {
    var run: RunDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(run.fileName)
                .font(.title3.weight(.semibold))
            Text("\(run.host) · \(run.runtime)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                metric("Pages", value: "\(run.pages)")
                metric("Chunks", value: "\(run.chunks)")
                metric("Tokens", value: "\(run.tokens)")
                metric("Embeddings/s", value: rateText)
                metric("Qdrant", value: upsertText)
            }
            Text(run.errorMessage ?? "No errors")
                .font(.callout)
                .foregroundStyle(run.errorMessage == nil ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.stages, id: \.name) { stage in
                    HStack(spacing: 8) {
                        Text(Self.label(stage.name))
                            .font(.caption)
                            .frame(width: 88, alignment: .leading)
                        Rectangle()
                            .fill(Self.color(stage.status))
                            .frame(width: barWidth(stage), height: 12)
                        Text(stage.status == "skipped" ? "skipped" : "\(Int(stage.durationMs)) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var rateText: String {
        guard let rate = run.embeddingsPerSecond else { return "—" }
        return String(format: "%.0f", rate)
    }

    private var upsertText: String {
        "\(Int(run.upsertMs)) ms \(run.upsertStatus)"
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func barWidth(_ stage: StageMetric) -> CGFloat {
        let maxDuration = max(run.stages.map(\.durationMs).max() ?? 1, 1)
        if stage.status == "skipped" { return 4 }
        return CGFloat(stage.durationMs / maxDuration) * 220
    }

    static func label(_ name: String) -> String {
        switch name {
        case "convert_layout": return "Convert"
        case "ocr": return "OCR"
        case "table": return "Tables"
        case "picture_description": return "Pictures"
        case "vlm_convert": return "VLM"
        case "chunking": return "Chunk"
        case "embedding": return "Embed"
        case "qdrant_upsert": return "Qdrant"
        default: return name
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "error": return .red
        case "skipped": return .gray.opacity(0.35)
        default: return .teal
        }
    }
}
