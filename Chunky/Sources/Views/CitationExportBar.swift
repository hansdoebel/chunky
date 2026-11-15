import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CitationExportBar: View {
    var records: [CitationSource]
    var note: String = "APA 7 as adapted by the IU Zitierleitfaden. Printed page labels are used first."

    var body: some View {
        let rendered = CitationExport.entries(records)
        VStack(alignment: .leading, spacing: 8) {
            Text("Citations")
                .font(.headline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rendered) { entry in
                Text(entry.typstCite)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Copy BibTeX") { CitationClipboard.copy(CitationExport.biblatex(records)) }
                Button("Copy Typst cite") { CitationClipboard.copy(CitationExport.typstCites(records)) }
                Button("Export .bib") { CitationClipboard.save(CitationExport.biblatex(records), suggestedName: "refs.bib") }
                Button("Export .yml") { CitationClipboard.save(CitationExport.hayagriva(records), suggestedName: "refs.yml") }
                Button("Export CSL") { CitationClipboard.saveStyle() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
    }
}

enum CitationClipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        let ext = (suggestedName as NSString).pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url)
    }

    static func saveStyle() {
        guard let text = styleText() else { return }
        save(text, suggestedName: "iu-apa7.csl")
    }

    static func styleText() -> String? {
        if let url = Bundle.main.url(forResource: "iu-apa7", withExtension: "csl"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/iu-apa7.csl")
        return try? String(contentsOf: bundled, encoding: .utf8)
    }
}
