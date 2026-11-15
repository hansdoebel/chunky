import SwiftUI

struct RetrievalPlayground: View {
    @Binding var query: String
    @Binding var collection: String
    @Binding var backend: String
    @Binding var model: String
    @Binding var limit: Int
    @Binding var offset: Int
    @Binding var source: String
    @Binding var page: String
    @Binding var contentType: String
    var collections: [String]
    var routeLabel: String
    var modeLabel: String
    var statusLine: String
    var error: String?
    var hits: [RetrievalHit]
    var isSearching: Bool
    var scrolls: Bool
    var onSearch: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            controls
                .frame(width: 280, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.gray.opacity(0.08))
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppTheme.surfaceGrouped)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retrieval")
                .font(.headline)
            Text(routeLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.badgeBackgroundActive, in: Capsule())
            Text(modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Query", text: $query, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            TextField("Collection", text: $collection, prompt: Text("Collection name"))
                .textFieldStyle(.roundedBorder)
            if !collectionChoices.isEmpty {
                Picker("Known", selection: $collection) {
                    ForEach(collectionChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            Picker("Backend", selection: $backend) {
                ForEach(EmbeddingBackendKind.allCases) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            TextField("Model", text: $model)
                .textFieldStyle(.roundedBorder)
            Stepper(value: $limit, in: 1...RetrievalLimits.maximum) {
                Text("Top \(limit)")
            }
            Stepper(value: $offset, in: 0...10_000) {
                Text("Offset \(offset)")
            }
            Text("Limit \(limit) of \(RetrievalLimits.maximum). No silent 1,000 cap.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Source", text: $source, prompt: Text("Source"))
                .textFieldStyle(.roundedBorder)
            TextField("Page", text: $page, prompt: Text("Page"))
                .textFieldStyle(.roundedBorder)
            Picker("Content", selection: $contentType) {
                Text("Any").tag("")
                Text("text").tag("text")
                Text("picture").tag("picture")
                Text("table").tag("table")
            }
            Button(action: onSearch) {
                Text(isSearching ? "Searching…" : "Search")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var collectionChoices: [String] {
        var names = collections
        if !collection.isEmpty && !names.contains(collection) {
            names.insert(collection, at: 0)
        }
        if names.isEmpty {
            names = ["documents"]
        }
        return names
    }

    private var results: some View {
        fitted {
            VStack(alignment: .leading, spacing: 12) {
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(AppTheme.statusRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hits.isEmpty && error == nil {
                    Text("Run a dense query to see scores, text, source, page, headings, and payload.")
                        .foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    hitCard(hit)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hitCard(_ hit: RetrievalHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.3f", hit.score))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.accentFallback.opacity(0.18), in: Capsule())
                Text(hit.source.isEmpty ? "unknown source" : hit.source)
                    .font(.caption)
                    .lineLimit(1)
                if let page = hit.page {
                    Text("p. \(page)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(hit.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !hit.headings.isEmpty {
                Text(hit.headings.joined(separator: " › "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(payloadLine(hit.payload))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
    }

    private func payloadLine(_ payload: [String: String]) -> String {
        payload.keys.sorted().map { key in
            "\(key)=\(payload[key] ?? "")"
        }.joined(separator: "  ")
    }

    @ViewBuilder
    private func fitted<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if scrolls {
            ScrollView { content() }
        } else {
            content()
        }
    }
}

struct RetrievalScreen: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var collection = ""
    @State private var backend = EmbeddingBackendKind.ollama.rawValue
    @State private var model = ""
    @State private var limit = 8
    @State private var offset = 0
    @State private var source = ""
    @State private var page = ""
    @State private var contentType = ""
    @State private var hits: [RetrievalHit] = []
    @State private var error: String?
    @State private var statusLine = RetrievalScreen.idleStatus
    @State private var isSearching = false
    @State private var prepared = false
    private let service: RetrievalService

    init(service: RetrievalService = RetrievalService()) {
        self.service = service
    }

    var body: some View {
        RetrievalPlayground(
            query: $query,
            collection: $collection,
            backend: $backend,
            model: $model,
            limit: $limit,
            offset: $offset,
            source: $source,
            page: $page,
            contentType: $contentType,
            collections: appState.availableCollections,
            routeLabel: route.displayName,
            modeLabel: RetrievalMode.dense.displayName,
            statusLine: statusLine,
            error: error,
            hits: hits,
            isSearching: isSearching,
            scrolls: true,
            onSearch: { Task { await runSearch() } }
        )
        .onAppear {
            guard !prepared else { return }
            prepared = true
            collection = appState.settings.defaultCollection
            backend = appState.settings.embeddingBackend
            model = appState.settings.embeddingModel
        }
    }

    private var route: RetrievalRoute {
        appState.settings.processingHost == .devbox ? .worker : .localQdrant
    }

    private func runSearch() async {
        isSearching = true
        error = nil
        defer { isSearching = false }
        let request = RetrievalRequest.make(
            text: query,
            collection: collection,
            mode: .dense,
            limit: limit,
            offset: offset,
            backend: backend,
            model: model,
            filters: RetrievalFilter.playground(source: source, page: page, contentType: contentType),
            settings: appState.settings
        )
        do {
            let index: (any RetrievalIndex)?
            if request.route == .localQdrant {
                try await appState.ensureQdrantConnection()
                guard let qdrant = appState.qdrantService else {
                    throw RetrievalError.notConnected
                }
                index = QdrantRetrievalIndex(service: qdrant)
            } else {
                index = nil
            }
            let result = try await service.search(request, index: index)
            hits = result.hits
            statusLine = result.statusLine
        } catch {
            hits = []
            self.error = error.localizedDescription
            statusLine = Self.idleStatus
        }
    }

    static let idleStatus = "Dense search. Limit is explicit (maximum \(RetrievalLimits.maximum)). Browse loads at most \(CollectionBrowse.pointLimit) points."
}
