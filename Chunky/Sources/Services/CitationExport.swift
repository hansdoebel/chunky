import Foundation

struct CitationSource: Equatable, Sendable {
    var citeKey: String = ""
    var title: String = ""
    var authors: [String] = []
    var year: Int?
    var doi: String = ""
    var venue: String = ""
    var url: String = ""
    var abstract: String = ""
    var pageLabels: [String] = []
    var page: Int?
    var pageEnd: Int?
    var fileName: String = ""

    init(hit: RetrievalHit) {
        let payload = hit.payload
        citeKey = payload["cite_key"] ?? ""
        let named = hit.docTitle.isEmpty ? (payload["doc_title"] ?? "") : hit.docTitle
        fileName = (hit.source as NSString).lastPathComponent
        title = named.isEmpty ? fileName : named
        authors = Self.authors(from: payload["authors"])
        year = Int(payload["year"] ?? "")
        doi = payload["doi"] ?? ""
        venue = payload["venue"] ?? ""
        url = payload["url"] ?? ""
        abstract = payload["abstract"] ?? ""
        pageLabels = hit.pageLabels.isEmpty ? RetrievalHit.pageLabels(from: payload["page_labels"]) : hit.pageLabels
        page = hit.page ?? Int(payload["page"] ?? "")
        pageEnd = hit.pageEnd ?? Int(payload["page_end"] ?? "")
        if title.isEmpty {
            title = "Untitled"
        }
    }

    init(point: QdrantPoint) {
        self.init(hit: RetrievalHit(
            id: point.id,
            score: 0,
            text: point.text,
            source: point.source,
            page: point.page,
            headings: point.headings,
            payload: point.metadata
        ))
    }

    static func authors(from raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains(";") {
            return trimmed.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if trimmed.contains(" and ") {
            return trimmed.components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return [trimmed]
    }
}

enum CitationExport {
    struct Entry: Equatable, Identifiable, Sendable {
        var key: String
        var source: CitationSource
        var id: String { key }
        var typstCite: String { CitationExport.typstCite(key: key, source: source) }
    }

    static func entries(_ sources: [CitationSource]) -> [Entry] {
        sources.map { source in
            Entry(key: preferredKey(source), source: source)
        }
    }

    static func bibliographyEntries(_ sources: [CitationSource]) -> [Entry] {
        var seen: Set<String> = []
        return entries(sources).filter { entry in
            if seen.contains(entry.key) { return false }
            seen.insert(entry.key)
            return true
        }
    }

    static func biblatex(_ sources: [CitationSource]) -> String {
        bibliographyEntries(sources).map(biblatexEntry).joined(separator: "\n\n")
    }

    static func hayagriva(_ sources: [CitationSource]) -> String {
        bibliographyEntries(sources).map(hayagrivaEntry).joined(separator: "\n")
    }

    static func typstCites(_ sources: [CitationSource]) -> String {
        entries(sources).map(\.typstCite).joined(separator: "\n")
    }

    static func typstCite(key: String, source: CitationSource) -> String {
        guard let span = pageSpan(source) else {
            return "#cite(<\(key)>)"
        }
        return "#cite(<\(key)>, supplement: [S. \(typstLiteral(span))])"
    }

    static func preferredKey(_ source: CitationSource) -> String {
        let imported = sanitize(source.citeKey, allowHyphen: true)
        if !imported.isEmpty {
            return finishKey(imported)
        }
        let family = sanitize(familyName(source.authors.first ?? ""), allowHyphen: false)
        let year = source.year.map(String.init) ?? "nd"
        let doi = sanitize(source.doi, allowHyphen: false)
        let stem = sanitize((source.fileName as NSString).deletingPathExtension, allowHyphen: false)
        let title = sanitize(source.title, allowHyphen: false)
        var parts: [String] = []
        if family.isEmpty {
            parts.append(stem.isEmpty ? (title.isEmpty ? "untitled" : title) : stem)
        } else {
            parts.append(family)
        }
        parts.append(year)
        if !doi.isEmpty {
            parts.append(doi)
        } else if !family.isEmpty {
            if !stem.isEmpty {
                parts.append(stem)
            } else if !title.isEmpty {
                parts.append(String(title.prefix(48)))
            }
        }
        return finishKey(parts.filter { !$0.isEmpty }.joined(separator: "-"))
    }

    private static func finishKey(_ raw: String) -> String {
        let key = sanitize(raw, allowHyphen: true)
        if key.isEmpty { return "untitled" }
        if key.first?.isNumber == true { return "k\(key)" }
        return key
    }

    static func typstLiteral(_ raw: String) -> String {
        var out = ""
        for character in raw {
            switch character {
            case "\\", "#", "$", "@", "*", "_", "`", "<", ">", "[", "]", "~":
                out.append("\\")
                out.append(character)
            case "\n", "\r":
                out.append(" ")
            default:
                out.append(character)
            }
        }
        return out
    }

    static func familyName(_ name: String) -> String {
        splitName(name).family
    }

    static func splitName(_ raw: String) -> (family: String, given: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return ("", "") }
        if let comma = name.firstIndex(of: ",") {
            let family = name[..<comma].trimmingCharacters(in: .whitespaces)
            let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return (family, given)
        }
        let words = name.split(separator: " ").map(String.init)
        if let index = words.firstIndex(where: { particles.contains($0.lowercased()) }), index > 0 {
            return (words[index...].joined(separator: " "), words[..<index].joined(separator: " "))
        }
        guard let family = words.last else { return (name, "") }
        return (family, words.dropLast().joined(separator: " "))
    }

    private static let particles: Set<String> = ["von", "van", "de", "der", "den", "ten", "ter", "da", "di", "du", "la", "le", "del"]

    private static func sanitize(_ raw: String, allowHyphen: Bool) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let mapped = folded.map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || (allowHyphen && character == "-") {
                return character
            }
            return " "
        }
        let collapsed = String(mapped).split(separator: " ").joined(separator: allowHyphen ? "-" : "")
        return collapsed.lowercased()
    }

    private static func pageSpan(_ source: CitationSource) -> String? {
        let labels = source.pageLabels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if labels.count == 1 {
            return labels[0]
        }
        if labels.count == 2 {
            return "\(labels[0])–\(labels[1])"
        }
        if labels.count > 2 {
            return labels.joined(separator: ", ")
        }
        guard let page = source.page else { return nil }
        if let pageEnd = source.pageEnd, pageEnd != page {
            let start = min(page, pageEnd)
            let end = max(page, pageEnd)
            return "\(start)–\(end)"
        }
        return "\(page)"
    }

    private static func biblatexEntry(_ entry: Entry) -> String {
        let source = entry.source
        let type = source.venue.isEmpty ? "misc" : "article"
        var lines = ["@\(type){\(entry.key),"]
        lines.append("  title = {\(bibtexEscape(source.title))},")
        let authors = source.authors.map { name in
            let parts = splitName(name)
            return parts.given.isEmpty ? bibtexEscape(parts.family) : "\(bibtexEscape(parts.family)), \(bibtexEscape(parts.given))"
        }
        if !authors.isEmpty {
            lines.append("  author = {\(authors.joined(separator: " and "))},")
        }
        if let year = source.year {
            lines.append("  year = {\(year)},")
        }
        if !source.venue.isEmpty {
            lines.append("  journal = {\(bibtexEscape(source.venue))},")
        }
        if !source.doi.isEmpty {
            lines.append("  doi = {\(bibtexEscape(source.doi))},")
        }
        if !source.url.isEmpty {
            lines.append("  url = {\(bibtexEscape(source.url))},")
        }
        if !source.abstract.isEmpty {
            lines.append("  abstract = {\(bibtexEscape(source.abstract))},")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    static func bibtexEscape(_ raw: String) -> String {
        var out = ""
        for character in raw {
            switch character {
            case "\\", "{", "}":
                out.append("\\")
                out.append(character)
            case "&", "%", "$", "#", "_":
                out.append("\\")
                out.append(character)
            case "~", "^":
                out.append("\\")
                out.append(character)
                out.append("{}")
            default:
                out.append(character)
            }
        }
        return out
    }

    private static func hayagrivaEntry(_ entry: Entry) -> String {
        let source = entry.source
        var lines = ["\(entry.key):"]
        if source.venue.isEmpty {
            lines.append("  type: misc")
        } else {
            lines.append("  type: article")
        }
        lines.append("  title: \(yamlQuote(source.title))")
        if !source.authors.isEmpty {
            lines.append("  author:")
            for name in source.authors {
                let parts = splitName(name)
                lines.append("    - name: \(yamlQuote(parts.family))")
                if !parts.given.isEmpty {
                    lines.append("      given-name: \(yamlQuote(parts.given))")
                }
            }
        }
        if let year = source.year {
            lines.append("  date: \(year)")
        }
        if !source.doi.isEmpty {
            lines.append("  doi: \(yamlQuote(source.doi))")
        }
        if !source.url.isEmpty {
            lines.append("  url: \(yamlQuote(source.url))")
        }
        if !source.abstract.isEmpty {
            lines.append("  abstract: \(yamlQuote(source.abstract))")
        }
        if !source.venue.isEmpty {
            lines.append("  parent:")
            lines.append("    type: periodical")
            lines.append("    title: \(yamlQuote(source.venue))")
        }
        return lines.joined(separator: "\n")
    }

    private static func yamlQuote(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
