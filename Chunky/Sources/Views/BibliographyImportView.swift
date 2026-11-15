import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BibliographyImportScreen: View {
    var matches: [BibliographyMatch]
    var status: String
    var lookupText: String
    var onLookupChange: (String) -> Void
    var onFetch: () -> Void
    var onImport: ([BibliographyMatch]) -> Void
    @State private var selected: Set<String>

    init(
        matches: [BibliographyMatch],
        status: String = "",
        lookupText: String = "",
        onLookupChange: @escaping (String) -> Void = { _ in },
        onFetch: @escaping () -> Void = {},
        onImport: @escaping ([BibliographyMatch]) -> Void = { _ in }
    ) {
        self.matches = matches
        self.status = status
        self.lookupText = lookupText
        self.onLookupChange = onLookupChange
        self.onFetch = onFetch
        self.onImport = onImport
        _selected = State(initialValue: Set(matches.filter { $0.pdf != nil }.map(\.id)))
    }

    private var chosen: [BibliographyMatch] {
        matches.filter { selected.contains($0.id) && $0.pdf != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import library")
                .font(.title2)
            Text("Zotero local API, a BibTeX file, or one DOI or arXiv id. The API key stays in the Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("DOI or arXiv", text: Binding(get: { lookupText }, set: onLookupChange))
                    .textFieldStyle(.roundedBorder)
                Button("Fetch") { onFetch() }
                    .disabled(lookupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if matches.isEmpty {
                Text(status.isEmpty ? "Load a library to see papers." : status)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(matches) { match in
                            row(match)
                        }
                    }
                }
            }
            HStack {
                Button("Import \(chosen.count)") { onImport(chosen) }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ match: BibliographyMatch) -> some View {
        let enabled = match.pdf != nil
        return Button {
            if enabled {
                if selected.contains(match.id) {
                    selected.remove(match.id)
                } else {
                    selected.insert(match.id)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected.contains(match.id) && enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(enabled ? AppTheme.accentFallback : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.record.title.isEmpty ? match.record.citeKey : match.record.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(detail(match))
                        .font(.caption)
                        .foregroundStyle(match.warning == nil ? .secondary : AppTheme.statusOrange)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(8)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func detail(_ match: BibliographyMatch) -> String {
        if let warning = match.warning { return warning }
        let authors = match.record.authors.joined(separator: ", ")
        let year = match.record.year.map(String.init) ?? ""
        return [authors, year, match.record.doi ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct BibliographyImportSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var matches: [BibliographyMatch] = []
    @State private var status = "The Zotero key is saved in the Keychain."
    @State private var apiKey = ""
    @State private var lookupText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Zotero local API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKey) { _, newValue in
                    appState.settings.zoteroAPIKey = newValue
                }
            HStack {
                Button("BibTeX…") { pickBibliography() }
                Button("Load Zotero") { Task { await loadZotero() } }
                if matches.contains(where: { $0.pdf == nil }) {
                    Button("Attach PDF…") { attachPDF() }
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            BibliographyImportScreen(
                matches: matches,
                status: status,
                lookupText: lookupText,
                onLookupChange: { lookupText = $0 },
                onFetch: { Task { await fetchPaper() } }
            ) { chosen in
                appState.importBibliography(chosen)
                dismiss()
            }
            .id(matches.map(\.id).joined(separator: "|"))
        }
        .onAppear { apiKey = appState.settings.zoteroAPIKey }
        .padding(12)
        .frame(width: 640, height: 520)
    }

    private func pickBibliography() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let bib = panel.url else { return }
        let folder = NSOpenPanel()
        folder.canChooseDirectories = true
        folder.canChooseFiles = false
        folder.prompt = "Choose PDF Folder"
        guard folder.runModal() == .OK, let directory = folder.url else { return }
        let text = (try? String(contentsOf: bib, encoding: .utf8)) ?? ""
        let pdfs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension.lowercased() == "pdf"
        } ?? []
        matches = BibliographyFiles.match(BibTeXParser.parse(text), pdfs: pdfs)
        let missing = matches.filter { $0.pdf == nil }.count
        status = missing == 0 ? "Matched \(matches.count) PDFs." : "\(missing) items have no PDF."
    }

    private func attachPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, !matches.isEmpty else { return }
        matches[0].pdf = url
        matches[0].warning = nil
        status = "Ready to import \(matches[0].record.title)."
    }

    private func fetchPaper() async {
        let text = lookupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PaperIdentifierParser.parse(text) != nil else {
            status = "Enter a DOI or an arXiv id."
            return
        }
        do {
            let client = PaperLookupClient()
            let found = try await client.fetch(text)
            var pdf: URL?
            if let remote = found.pdfURL {
                let data = try await client.download(remote)
                pdf = try writePDF(data, name: found.record.citeKey)
            }
            let warning = pdf == nil ? PaperLookup.needsPDF : nil
            matches = [BibliographyMatch(record: found.record, pdf: pdf, warning: warning)]
            status = warning ?? "Ready to import \(found.record.title)."
        } catch {
            status = "The paper could not be fetched."
        }
    }

    private func writePDF(_ data: Data, name: String) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func loadZotero() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = "Add a Zotero local API key. It is saved in the Keychain."
            return
        }
        appState.settings.zoteroAPIKey = key
        guard let base = URL(string: "http://127.0.0.1:23119/api") else { return }
        do {
            let client = ZoteroLocalClient()
            var rows: [[String: Any]] = []
            var start = 0
            while true {
                let page = try await client.page(for: ZoteroLocalAPI.itemsRequest(baseURL: base, apiKey: key, start: start))
                let batch = try JSONSerialization.jsonObject(with: page.data) as? [[String: Any]] ?? []
                rows.append(contentsOf: batch)
                start += batch.count
                if batch.isEmpty || batch.count < 100 || (page.total != nil && start >= page.total!) {
                    break
                }
            }
            let items = try JSONSerialization.data(withJSONObject: rows)
            var attachments: [[String: Any]] = []
            for row in rows {
                guard let itemKey = row["key"] as? String, !itemKey.isEmpty else { continue }
                let children = try await ZoteroLocalClient().data(
                    for: ZoteroLocalAPI.childrenRequest(baseURL: base, itemKey: itemKey, apiKey: key)
                )
                if let childRows = try JSONSerialization.jsonObject(with: children) as? [[String: Any]] {
                    attachments.append(contentsOf: childRows)
                }
            }
            let records = try ZoteroLibraryParser.records(itemsJSON: items, attachmentsJSON: JSONSerialization.data(withJSONObject: attachments))
            matches = records.map { record in
                if let path = record.pdfPath, FileManager.default.isReadableFile(atPath: path) {
                    return BibliographyMatch(record: record, pdf: URL(fileURLWithPath: path), warning: nil)
                }
                return BibliographyMatch(record: record, pdf: nil, warning: "No PDF for \(record.citeKey)")
            }
            status = "Zotero key is stored in the Keychain."
        } catch {
            status = "Zotero could not be reached."
        }
    }
}

struct ZoteroLocalClient: Sendable {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> Data {
        try await page(for: request).data
    }

    func page(for request: URLRequest) async throws -> (data: Data, total: Int?) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let total = http.value(forHTTPHeaderField: "Total-Results").flatMap(Int.init)
        return (data, total)
    }
}
