import AppKit
import SwiftUI

struct BibliographyImportScreen: View {
    var matches: [BibliographyMatch]
    var status: String
    var onImport: ([BibliographyMatch]) -> Void
    @State private var selected: Set<String>

    init(matches: [BibliographyMatch], status: String = "", onImport: @escaping ([BibliographyMatch]) -> Void = { _ in }) {
        self.matches = matches
        self.status = status
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
            Text("Zotero local API or a BibTeX file plus PDFs. The API key stays in the Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
    @State private var status = "Zotero key is stored in the Keychain."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("BibTeX…") { pickBibliography() }
                Button("Load Zotero") { Task { await loadZotero() } }
                Spacer()
                Button("Close") { dismiss() }
            }
            BibliographyImportScreen(matches: matches, status: status) { chosen in
                appState.importBibliography(chosen)
                dismiss()
            }
        }
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

    private func loadZotero() async {
        let key = appState.settings.zoteroAPIKey
        guard !key.isEmpty else {
            status = "Add a Zotero local API key. It is saved in the Keychain."
            return
        }
        guard let base = URL(string: "http://127.0.0.1:23119/api") else { return }
        do {
            let items = try await ZoteroLocalClient().data(for: ZoteroLocalAPI.itemsRequest(baseURL: base, apiKey: key))
            var attachments: [[String: Any]] = []
            let rows = try JSONSerialization.jsonObject(with: items) as? [[String: Any]] ?? []
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
