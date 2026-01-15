import SwiftUI

struct CollectionBrowserView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var searchQuery = ""
    @State private var sourceFilter = ""
    @State private var selectedIds: Set<String> = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search...", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.badgeBackground, in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 200)

                Picker("Source", selection: $sourceFilter) {
                    Text("All Sources").tag("")
                    ForEach(appState.browserSources, id: \.self) { source in
                        Text(source).tag(source)
                    }
                }
                .frame(width: 160)

                Spacer()

                if appState.isLoadingPoints {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(AppTheme.accentFallback)
                }

                Text("\(filteredPoints.count) of \(appState.browserPointCount)")
                    .foregroundStyle(.tertiary)
                    .font(.system(.caption, design: .rounded, weight: .medium))

                Button(action: { Task { await appState.loadBrowserPoints() } }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh points")

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Text("Delete")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.statusRed)
                .disabled(selectedIds.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()
                .opacity(0.5)

            // Points list
            if appState.isLoadingPoints && appState.browserPoints.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .tint(AppTheme.accentFallback)
                    Text("Loading points...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else if filteredPoints.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(AppTheme.badgeBackground)
                            .frame(width: 80, height: 80)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                    }
                    if appState.browserPoints.isEmpty {
                        Text("No points in collection")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Select a collection and upload documents")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("No results match your filter")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                List(filteredPoints, id: \.id, selection: $selectedIds) { point in
                    PointRowView(point: point)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { await appState.deletePoints(ids: [point.id]) }
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            Task { await appState.loadBrowserPoints() }
        }
        .onChange(of: appState.settings.defaultCollection) { _, _ in
            selectedIds.removeAll()
            Task { await appState.loadBrowserPoints() }
        }
        .alert("Delete Points?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deletePoints(ids: Array(selectedIds))
                    selectedIds.removeAll()
                }
            }
        } message: {
            Text("Delete \(selectedIds.count) point(s)? This cannot be undone.")
        }
    }

    private var filteredPoints: [QdrantPoint] {
        var result = appState.browserPoints

        if !sourceFilter.isEmpty {
            result = result.filter { $0.source == sourceFilter }
        }

        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            result = result.filter { $0.text.lowercased().contains(query) }
        }

        return result
    }
}

struct PointRowView: View {
    let point: QdrantPoint
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(textPreview)
                .lineLimit(2)
                .font(.system(.body))
                .foregroundStyle(.primary.opacity(0.9))

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.caption2)
                    Text(point.source)
                        .lineLimit(1)
                }

                if let page = point.page {
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.caption2)
                        Text("\(page)")
                    }
                }

                if !point.headings.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.indent")
                            .font(.caption2)
                        Text(point.headings.joined(separator: " > "))
                            .lineLimit(1)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var textPreview: String {
        let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 200 {
            return String(text.prefix(200)) + "..."
        }
        return text
    }
}
