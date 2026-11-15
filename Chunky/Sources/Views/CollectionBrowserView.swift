import SwiftUI

struct CollectionBrowserView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var searchQuery = ""
    @State private var sourceFilter = ""
    @State private var selectedIds: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var showNewCollection = false
    @State private var showSnapshots = false

    var body: some View {
        VStack(spacing: 0) {

            HStack(spacing: 8) {
                Picker(selection: $appState.settings.defaultCollection) {
                    ForEach(appState.availableCollections, id: \.self) { collection in
                        Text(collection).tag(collection)
                    }
                } label: {
                    Text("Collection...")
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .fixedSize()

                Picker(selection: $sourceFilter) {
                    Text("All Sources").tag("")
                    ForEach(appState.browserSources, id: \.self) { source in
                        Text(source).tag(source)
                    }
                } label: {
                    Text("Source...")
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .fixedSize()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search...", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.badgeBackground, in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 180)

                Spacer()

                if appState.isLoadingPoints {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(AppTheme.accentFallback)
                }

                Text("\(filteredPoints.count) of \(appState.browserPointCount) · limit \(CollectionBrowse.pointLimit)")
                    .foregroundStyle(.tertiary)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .help("Substring browse loads at most \(CollectionBrowse.pointLimit) points. Use Retrieval for semantic search.")

                Button("New") { showNewCollection = true }
                    .buttonStyle(.bordered)
                Button("Snapshots") { showSnapshots = true }
                    .buttonStyle(.bordered)
                Button(action: { Task { await appState.loadBrowserPoints() } }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh points")

                if !selectedIds.isEmpty {
                    Button("Copy Typst cite") {
                        CitationClipboard.copy(CitationExport.typstCites(selectedRecords))
                    }
                    Button("Export .bib") {
                        CitationClipboard.save(CitationExport.biblatex(selectedRecords), suggestedName: "refs.bib")
                    }
                    Button("Export .yml") {
                        CitationClipboard.save(CitationExport.hayagriva(selectedRecords), suggestedName: "refs.yml")
                    }
                    Button("Export CSL") {
                        CitationClipboard.saveStyle()
                    }
                }

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
                            Button("Copy Typst cite") {
                                CitationClipboard.copy(CitationExport.typstCites([CitationSource(point: point)]))
                            }
                            Button("Copy BibTeX") {
                                CitationClipboard.copy(CitationExport.biblatex([CitationSource(point: point)]))
                            }
                            Button("Delete", role: .destructive) {
                                Task { await appState.deletePoints(ids: [point.id]) }
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            Task {
                await appState.fetchCollections()
                await appState.loadBrowserPoints()
            }
        }
        .sheet(isPresented: $showSnapshots) {
            CollectionSnapshotsScreen(onRestored: { selectedIds.removeAll() })
                .environmentObject(appState)
        }
        .sheet(isPresented: $showNewCollection) {
            NewCollectionSheet(
                vectorSize: appState.settings.embeddingDimensions,
                embeddingBackend: appState.settings.embeddingBackend,
                embeddingModel: appState.settings.embeddingModel
            )
            .environmentObject(appState)
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

    private var selectedRecords: [CitationSource] {
        filteredPoints.filter { selectedIds.contains($0.id) }.map(CitationSource.init(point:))
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
