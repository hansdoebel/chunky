import SwiftUI

struct RAGAnswerText: View {
    var text: String
    var citations: [RAGCitation]
    var onSelect: (RAGCitation) -> Void

    var body: some View {
        SegmentWrap {
            ForEach(Array(RAGCitationParser.segments(in: text, citations: citations).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    Text(value)
                        .font(.body)
                        .textSelection(.enabled)
                case .citation(let citation):
                    Button(action: { onSelect(citation) }) {
                        Text("\(citation.marker) \(citation.citeLabel)")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .help(citationHelp(citation))
                }
            }
        }
    }

    private func citationHelp(_ citation: RAGCitation) -> String {
        let page = citation.page.map { "page \($0)" } ?? "no page"
        return "\(citation.id) \(citation.source) \(page) \(String(format: "%.3f", citation.score))"
    }
}

struct SegmentWrap: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

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
    @Binding var yearFrom: String
    @Binding var yearTo: String
    @Binding var author: String
    @Binding var doi: String
    @Binding var title: String
    @Binding var heading: String
    @Binding var papersFirst: Bool
    @Binding var expandPapers: Bool
    @Binding var expandSection: Bool
    @Binding var sectionRatio: String
    @Binding var mode: String
    @Binding var denseWeight: String
    @Binding var lexicalWeight: String
    @Binding var rerankEnabled: Bool
    @Binding var rerankURL: String
    @Binding var rerankModel: String
    @Binding var rerankAPIKey: String
    var collections: [String]
    var routeLabel: String
    var statusLine: String
    var error: String?
    var hits: [RetrievalHit]
    var isSearching: Bool
    var scrolls: Bool
    var onSearch: () -> Void
    @Binding var generationModel: String
    var answer: String
    var citations: [RAGCitation]
    var selectedHitID: String?
    var isAnswering: Bool
    var onAsk: () -> Void
    var onSelectCitation: (RAGCitation) -> Void
    var onShowPDF: (RetrievalHit) -> Void = { _ in }

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

    @ViewBuilder
    private var controls: some View {
        if scrolls {
            ScrollView(.vertical) { controlFields }
        } else {
            controlFields
        }
    }

    private var controlFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retrieval")
                .font(.headline)
            Text(routeLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.badgeBackgroundActive, in: Capsule())
            Picker("Mode", selection: $mode) {
                ForEach(RetrievalMode.allCases) { item in
                    Text(item.displayName).tag(item.rawValue)
                }
            }
            if mode == RetrievalMode.hybrid.rawValue {
                TextField("Dense weight", text: $denseWeight, prompt: Text("Dense weight"))
                    .textFieldStyle(.roundedBorder)
                TextField("BM25 weight", text: $lexicalWeight, prompt: Text("BM25 weight"))
                    .textFieldStyle(.roundedBorder)
                Text("Empty weights use equal RRF. BM25 reads the text field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Toggle("Rerank", isOn: $rerankEnabled)
            if rerankEnabled {
                TextField("Rerank URL", text: $rerankURL, prompt: Text("http://127.0.0.1:8081/v1/rerank"))
                    .textFieldStyle(.roundedBorder)
                TextField("Rerank model", text: $rerankModel, prompt: Text("jina-reranker"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Rerank API key", text: $rerankAPIKey, prompt: Text("Bearer token, if required"))
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Source", text: $source, prompt: Text("Source"))
                .textFieldStyle(.roundedBorder)
            TextField("Page", text: $page, prompt: Text("Page"))
                .textFieldStyle(.roundedBorder)
            Text("Filters")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Year from", text: $yearFrom, prompt: Text("Year from"))
                .textFieldStyle(.roundedBorder)
            TextField("Year to", text: $yearTo, prompt: Text("Year to"))
                .textFieldStyle(.roundedBorder)
            TextField("Author", text: $author, prompt: Text("Author"))
                .textFieldStyle(.roundedBorder)
            TextField("DOI", text: $doi, prompt: Text("DOI"))
                .textFieldStyle(.roundedBorder)
            TextField("Title contains", text: $title, prompt: Text("Title contains"))
                .textFieldStyle(.roundedBorder)
            TextField("Heading contains", text: $heading, prompt: Text("Heading contains"))
                .textFieldStyle(.roundedBorder)
            Picker("Content", selection: $contentType) {
                Text("Any").tag("")
                Text("text").tag("text")
                Text("picture").tag("picture")
                Text("table").tag("table")
                Text("formula").tag("formula")
            }
            Toggle("Papers first", isOn: $papersFirst)
            if papersFirst {
                Toggle("Expand to chunks", isOn: $expandPapers)
            }
            Toggle("Expand to section", isOn: $expandSection)
            if expandSection {
                TextField("Sibling ratio", text: $sectionRatio, prompt: Text("0.5"))
                    .textFieldStyle(.roundedBorder)
            }
            Button(action: onSearch) {
                Text(isSearching ? "Searching…" : "Search")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSearching || isAnswering || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextField("Generation model", text: $generationModel, prompt: Text("qwen3"))
                .textFieldStyle(.roundedBorder)
            Button(action: onAsk) {
                Text(isAnswering ? "Answering…" : "Ask")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isAnswering || isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Ask uses these retrieval settings and an OpenAI-compatible chat endpoint.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                if !answer.isEmpty || isAnswering {
                    answerBlock
                }
                if hits.isEmpty && error == nil && answer.isEmpty {
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

    private var answerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            RAGAnswerText(text: answer.isEmpty && isAnswering ? "Answering…" : answer, citations: citations, onSelect: onSelectCitation)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.accentFallback.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hitCard(_ hit: RetrievalHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.3f", hit.score))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.accentFallback.opacity(0.18), in: Capsule())
                Text(hit.docTitle.isEmpty ? (hit.source.isEmpty ? "unknown source" : hit.source) : hit.docTitle)
                    .font(.caption)
                    .lineLimit(1)
                if let page = hit.page {
                    let range = hit.pageEnd.flatMap { $0 == page ? nil : "–\($0)" } ?? ""
                    Text("p. \(page)\(range)")
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
            Button("Show in PDF") { onShowPDF(hit) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Text(payloadLine(hit.payload))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hit.id == selectedHitID ? AppTheme.accentFallback : Color.clear, lineWidth: 2)
        )
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
    @State private var yearFrom = ""
    @State private var yearTo = ""
    @State private var author = ""
    @State private var doi = ""
    @State private var title = ""
    @State private var heading = ""
    @State private var papersFirst = false
    @State private var expandPapers = false
    @State private var expandSection = false
    @State private var sectionRatio = "0.5"
    @State private var mode = RetrievalMode.dense.rawValue
    @State private var denseWeight = ""
    @State private var lexicalWeight = ""
    @State private var rerankEnabled = false
    @State private var rerankURL = ""
    @State private var rerankModel = ""
    @State private var rerankAPIKey = ""
    @State private var hits: [RetrievalHit] = []
    @State private var error: String?
    @State private var statusLine = RetrievalScreen.idleStatus
    @State private var isSearching = false
    @State private var prepared = false
    @State private var generationModel = ""
    @State private var answer = ""
    @State private var citations: [RAGCitation] = []
    @State private var selectedHitID: String?
    @State private var citationPDF: CitationHighlight?
    @State private var isAnswering = false
    @State private var answerTask: Task<Void, Never>?
    private let service: RetrievalService
    private let chatFactory: (String, String, String) -> any RAGChatStreaming

    init(
        service: RetrievalService = RetrievalService(),
        chatFactory: @escaping (String, String, String) -> any RAGChatStreaming = { model, endpoint, apiKey in
            OpenAIRAGChat(
                client: OpenAICompatibleChatClient(
                    baseURL: endpoint,
                    model: model,
                    apiKey: apiKey,
                    http: URLSessionChatHTTP()
                )
            )
        }
    ) {
        self.service = service
        self.chatFactory = chatFactory
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
            yearFrom: $yearFrom,
            yearTo: $yearTo,
            author: $author,
            doi: $doi,
            title: $title,
            heading: $heading,
            papersFirst: $papersFirst,
            expandPapers: $expandPapers,
            expandSection: $expandSection,
            sectionRatio: $sectionRatio,
            mode: $mode,
            denseWeight: $denseWeight,
            lexicalWeight: $lexicalWeight,
            rerankEnabled: $rerankEnabled,
            rerankURL: $rerankURL,
            rerankModel: $rerankModel,
            rerankAPIKey: $rerankAPIKey,
            collections: appState.availableCollections,
            routeLabel: route.displayName,
            statusLine: statusLine,
            error: error,
            hits: hits,
            isSearching: isSearching,
            scrolls: true,
            onSearch: {
                answer = ""
                citations = []
                selectedHitID = nil
                citationPDF = nil
                Task { await runSearch() }
            },
            generationModel: $generationModel,
            answer: answer,
            citations: citations,
            selectedHitID: selectedHitID,
            isAnswering: isAnswering,
            onAsk: {
                answerTask?.cancel()
                answerTask = Task { await ask() }
            },
            onSelectCitation: { citation in
                selectedHitID = citation.id
                citationPDF = CitationPDF.highlight(
                    citation: citation,
                    hit: hits.first { $0.id == citation.id },
                    known: knownPDFs
                )
            },
            onShowPDF: { hit in
                selectedHitID = hit.id
                citationPDF = CitationPDF.highlight(hit: hit, known: knownPDFs)
            }
        )
        .sheet(item: $citationPDF) { highlight in
            CitationPDFScreen(highlight: highlight, pageImage: { page in
                guard let url = highlight.pdfURL else { return nil }
                return PDFPageRenderer.render(url: url, page: page)
            })
        }
        .onDisappear {
            answerTask?.cancel()
            answerTask = nil
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            collection = appState.settings.defaultCollection
            backend = appState.settings.embeddingBackend
            model = appState.settings.embeddingModel
            if generationModel.isEmpty {
                generationModel = appState.settings.chatModel
            }
        }
    }

    private var knownPDFs: [URL] {
        appState.jobs.map(\.sourceURL)
    }

    private var route: RetrievalRoute {
        appState.settings.processingHost == .devbox ? .worker : .localQdrant
    }

    private func ask() async {
        let question = query
        isAnswering = true
        answer = ""
        citations = []
        selectedHitID = nil
        defer { isAnswering = false }
        await runSearch(question: question)
        guard !Task.isCancelled, error == nil, !hits.isEmpty else { return }
        let bundle = RAGPrompt.assemble(question: question, hits: hits)
        citations = bundle.citations
        let chat = chatFactory(generationModel, appState.settings.chatAPIURL, appState.settings.chatAPIKey)
        defer { Task { await chat.abort() } }
        do {
            for try await delta in chat.stream(system: bundle.system, user: bundle.user) {
                if Task.isCancelled { break }
                answer += delta
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func runSearch(question: String? = nil) async {
        isSearching = true
        error = nil
        defer { isSearching = false }
        let selected = RetrievalMode(rawValue: mode) ?? .dense
        let request = RetrievalRequest.make(
            text: question ?? query,
            collection: collection,
            mode: selected,
            limit: limit,
            offset: offset,
            backend: backend,
            model: model,
            filters: RetrievalFilter.playground(
                source: source,
                page: page,
                contentType: contentType,
                yearFrom: yearFrom,
                yearTo: yearTo,
                author: author,
                doi: doi,
                title: title,
                heading: heading
            ),
            papersFirst: papersFirst,
            expandPapers: expandPapers,
            expandSection: expandSection,
            sectionRatio: Double(sectionRatio.trimmingCharacters(in: .whitespacesAndNewlines)) ?? SectionExpansion.defaultThreshold,
            rrfWeights: Self.weights(dense: denseWeight, lexical: lexicalWeight),
            rerank: rerankEnabled
                ? RerankConfig(url: rerankURL, model: rerankModel, apiKey: rerankAPIKey)
                : nil,
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

    static let idleStatus = "Dense or hybrid search. Limit is explicit (maximum \(RetrievalLimits.maximum)). Browse loads at most \(CollectionBrowse.pointLimit) points."

    static func weights(dense: String, lexical: String) -> [Double]? {
        let left = dense.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = lexical.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty && right.isEmpty { return nil }
        guard let denseValue = Double(left), let lexicalValue = Double(right) else { return [-1] }
        return [denseValue, lexicalValue]
    }
}
