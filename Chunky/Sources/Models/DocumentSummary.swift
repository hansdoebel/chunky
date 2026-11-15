import Foundation

nonisolated struct SummaryChunk: Equatable, Sendable {
    var text: String
    var headings: [String]
    var page: Int?
}

nonisolated struct DocumentSummaryChoice: Equatable, Sendable {
    var text: String
    var kind: String
    var source: String
}

nonisolated enum DocumentSummary {
    static let abstractHeadings: Set<String> = ["abstract", "summary", "zusammenfassung"]
    static let documentRecord = "document"

    static func resolve(chunks: [SummaryChunk], title: String, generated: String?) -> DocumentSummaryChoice {
        let material = fallbackSource(chunks: chunks, title: title)
        if let abstract = abstractText(chunks: chunks) {
            return DocumentSummaryChoice(text: abstract, kind: "abstract", source: material)
        }
        let written = generated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !written.isEmpty {
            return DocumentSummaryChoice(text: written, kind: "generated", source: material)
        }
        return DocumentSummaryChoice(text: material, kind: "extract", source: material)
    }

    static func abstractText(chunks: [SummaryChunk]) -> String? {
        let parts = chunks.compactMap { chunk -> String? in
            let headings = chunk.headings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard headings.contains(where: { abstractHeadings.contains($0) }) else { return nil }
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func fallbackSource(chunks: [SummaryChunk], title: String) -> String {
        var headings: [String] = []
        var pages: [String] = []
        for chunk in chunks {
            for heading in chunk.headings where !headings.contains(heading) {
                headings.append(heading)
            }
            if (chunk.page ?? 1) <= 2 {
                let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    pages.append(text)
                }
            }
        }
        var lines: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            lines.append(trimmedTitle)
        }
        if !headings.isEmpty {
            lines.append("Sections: \(headings.prefix(12).joined(separator: " > "))")
        }
        let body = pages.joined(separator: "\n")
        if !body.isEmpty {
            lines.append(String(body.prefix(4000)))
        }
        return lines.joined(separator: "\n")
    }
}
