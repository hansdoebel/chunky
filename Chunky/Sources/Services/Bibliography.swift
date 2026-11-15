import Foundation

struct BibliographicMetadata: Equatable, Codable, Identifiable {
    var citeKey: String
    var title: String
    var authors: [String]
    var year: Int?
    var doi: String?
    var venue: String?
    var abstract: String?
    var source: String
    var pdfPath: String?

    var id: String { citeKey.isEmpty ? (doi ?? title) : citeKey }
}

struct BibliographyMatch: Equatable, Identifiable {
    var record: BibliographicMetadata
    var pdf: URL?
    var warning: String?

    var id: String { record.id }
}

enum BibTeXParser {
    static func parse(_ text: String) -> [BibliographicMetadata] {
        var records: [BibliographicMetadata] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let at = text[cursor...].firstIndex(of: "@") else { break }
            let typeStart = text.index(after: at)
            var typeEnd = typeStart
            while typeEnd < text.endIndex, text[typeEnd].isLetter {
                typeEnd = text.index(after: typeEnd)
            }
            let type = String(text[typeStart..<typeEnd]).lowercased()
            var openerIndex = typeEnd
            while openerIndex < text.endIndex, text[openerIndex].isWhitespace {
                openerIndex = text.index(after: openerIndex)
            }
            guard openerIndex < text.endIndex, text[openerIndex] == "{" || text[openerIndex] == "(" else {
                cursor = typeEnd < text.endIndex ? typeEnd : text.endIndex
                continue
            }
            let opener = text[openerIndex]
            let closer: Character = opener == "{" ? "}" : ")"
            let contentStart = text.index(after: openerIndex)
            guard let contentEnd = endOfEntry(text, from: contentStart, open: opener, close: closer) else { break }
            let content = String(text[contentStart..<contentEnd])
            cursor = text.index(after: contentEnd)
            if ["comment", "string", "preamble"].contains(type) { continue }
            let parsed = fields(in: content)
            if !parsed.key.isEmpty {
                records.append(record(key: parsed.key, fields: parsed.fields, source: "bibtex"))
            }
        }
        return records
    }

    private static func endOfEntry(
        _ text: String,
        from start: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 1
        var index = start
        var quoted = false
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func fields(in content: String) -> (key: String, fields: [String: String]) {
        var parsed: [String: String] = [:]
        guard let comma = separator(in: content, from: content.startIndex) else {
            return (content.trimmingCharacters(in: .whitespacesAndNewlines), parsed)
        }
        let key = content[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        var index = content.index(after: comma)
        while index < content.endIndex {
            guard let equals = content[index...].firstIndex(of: "=") else { break }
            let name = content[index..<equals]
            var valueStart = content.index(after: equals)
            while valueStart < content.endIndex, content[valueStart].isWhitespace {
                valueStart = content.index(after: valueStart)
            }
            let end = separator(in: content, from: valueStart) ?? content.endIndex
            store(&parsed, name: String(name), value: String(content[valueStart..<end]))
            if end == content.endIndex { break }
            index = content.index(after: end)
        }
        return (key, parsed)
    }

    private static func separator(in content: String, from start: String.Index) -> String.Index? {
        var brace = 0
        var quoted = false
        var index = start
        while index < content.endIndex {
            let character = content[index]
            if quoted {
                if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                brace += 1
            } else if character == "}" && brace > 0 {
                brace -= 1
            } else if character == "," && brace == 0 {
                return index
            }
            index = content.index(after: index)
        }
        return nil
    }

    private static func store(_ fields: inout [String: String], name: String, value: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleaned = unwrap(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty, !cleaned.isEmpty else { return }
        fields[key] = cleaned
    }

    private static func unwrap(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        if (first == "{" && last == "}") || (first == "\"" && last == "\"") {
            return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func record(key: String, fields: [String: String], source: String) -> BibliographicMetadata {
        let yearText = fields["year"] ?? fields["date"] ?? ""
        let year = yearText.range(of: #"\d{4}"#, options: .regularExpression).map { Int(yearText[$0]) ?? 0 }
        let doi = fields["doi"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BibliographicMetadata(
            citeKey: key,
            title: strip(fields["title"] ?? ""),
            authors: authors(fields["author"] ?? ""),
            year: year == 0 ? nil : year,
            doi: doi?.isEmpty == false ? doi : nil,
            venue: nonEmpty(fields["journal"] ?? fields["booktitle"] ?? fields["publisher"]),
            abstract: nonEmpty(fields["abstract"]),
            source: source,
            pdfPath: nil
        )
    }

    static func authors(_ value: String) -> [String] {
        splitAuthors(value).map(displayName).filter { !$0.isEmpty }
    }

    private static func splitAuthors(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "{" { depth += 1 }
            if value[index] == "}" && depth > 0 { depth -= 1 }
            if depth == 0, value[index...].lowercased().hasPrefix(" and ") {
                parts.append(current)
                current = ""
                index = value.index(index, offsetBy: 5)
                continue
            }
            current.append(value[index])
            index = value.index(after: index)
        }
        parts.append(current)
        return parts.map { strip($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func displayName(_ value: String) -> String {
        let pieces = value.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if pieces.count == 2 {
            return "\(pieces[1]) \(pieces[0])"
        }
        return value
    }

    private static func strip(_ value: String) -> String {
        var result = ""
        var depth = 0
        for character in value {
            if character == "{" {
                depth += 1
                continue
            }
            if character == "}" && depth > 0 {
                depth -= 1
                continue
            }
            result.append(character)
        }
        return result.replacingOccurrences(of: "\\", with: "")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = strip(value.trimmingCharacters(in: .whitespacesAndNewlines))
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum BibliographyFiles {
    static func match(_ records: [BibliographicMetadata], pdfs: [URL]) -> [BibliographyMatch] {
        records.map { record in
            if let pdf = pdfs.first(where: { stem($0) == record.citeKey.lowercased() }) {
                return BibliographyMatch(record: record, pdf: pdf, warning: nil)
            }
            if let pdf = pdfs.first(where: { doiMatch($0, record: record) }) {
                return BibliographyMatch(record: record, pdf: pdf, warning: nil)
            }
            return BibliographyMatch(record: record, pdf: nil, warning: "No PDF for \(record.citeKey)")
        }
    }

    private static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func doiMatch(_ url: URL, record: BibliographicMetadata) -> Bool {
        guard let doi = record.doi?.lowercased(), !doi.isEmpty else { return false }
        let forms = [
            doi,
            doi.replacingOccurrences(of: "/", with: "_"),
            doi.replacingOccurrences(of: "/", with: "-"),
            doi.replacingOccurrences(of: "/", with: ""),
        ]
        return forms.contains(stem(url))
    }
}

enum ZoteroLibraryParser {
    static func records(itemsJSON: Data, attachmentsJSON: Data? = nil) throws -> [BibliographicMetadata] {
        let items = try JSONSerialization.jsonObject(with: itemsJSON) as? [[String: Any]] ?? []
        let attachments = (attachmentsJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }) ?? []
        let paths = attachmentPaths(attachments)
        return items.compactMap { item in
            let data = item["data"] as? [String: Any] ?? item
            let type = (data["itemType"] as? String ?? "").lowercased()
            if type == "attachment" || type == "note" { return nil }
            let key = item["key"] as? String ?? data["key"] as? String ?? ""
            let creators = data["creators"] as? [[String: Any]] ?? []
            let names = creators.compactMap { creator -> String? in
                if let name = creator["name"] as? String, !name.isEmpty { return name }
                let first = creator["firstName"] as? String ?? ""
                let last = creator["lastName"] as? String ?? ""
                let combined = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                return combined.isEmpty ? nil : combined
            }
            let date = data["date"] as? String ?? ""
            let year = date.range(of: #"\d{4}"#, options: .regularExpression).map { Int(date[$0]) ?? 0 }
            let doi = (data["DOI"] as? String ?? data["doi"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cite = (data["citationKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BibliographicMetadata(
                citeKey: (cite?.isEmpty == false ? cite! : key),
                title: data["title"] as? String ?? "",
                authors: names,
                year: year == 0 ? nil : year,
                doi: doi?.isEmpty == false ? doi : nil,
                venue: data["publicationTitle"] as? String ?? data["bookTitle"] as? String,
                abstract: data["abstractNote"] as? String,
                source: "zotero",
                pdfPath: paths[key]
            )
        }
    }

    static func attachmentPaths(_ attachments: [[String: Any]]) -> [String: String] {
        var paths: [String: String] = [:]
        for item in attachments {
            let data = item["data"] as? [String: Any] ?? item
            let parent = data["parentItem"] as? String ?? ""
            let content = (data["contentType"] as? String ?? "").lowercased()
            let filename = (data["filename"] as? String ?? "").lowercased()
            guard content == "application/pdf" || filename.hasSuffix(".pdf") else { continue }
            let path = data["path"] as? String ?? data["localPath"] as? String
            if let path, !path.isEmpty, !parent.isEmpty {
                paths[parent] = path
            }
        }
        return paths
    }
}

enum ZoteroLocalAPI {
    static func itemsRequest(baseURL: URL, apiKey: String, start: Int = 0) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = baseURL.path.appending("/users/0/items")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "start", value: String(start)),
        ]
        var request = URLRequest(url: components?.url ?? baseURL)
        request.setValue(apiKey, forHTTPHeaderField: "Zotero-API-Key")
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        return request
    }

    static func childrenRequest(baseURL: URL, itemKey: String, apiKey: String) -> URLRequest {
        var request = itemsRequest(baseURL: baseURL, apiKey: apiKey)
        guard var components = URLComponents(url: request.url ?? baseURL, resolvingAgainstBaseURL: false) else {
            return request
        }
        components.path += "/\(itemKey)/children"
        request.url = components.url
        return request
    }

    static func redacted(_ request: URLRequest) -> String {
        let url = request.url?.absoluteString ?? ""
        return "GET \(url) Zotero-API-Key=[redacted]"
    }
}

extension ChunkingService.DocumentChunk {
    func applyingBibliography(_ record: BibliographicMetadata) -> ChunkingService.DocumentChunk {
        var meta = metadata
        if let venue = record.venue, !venue.isEmpty { meta["venue"] = venue }
        if let abstract = record.abstract, !abstract.isEmpty { meta["abstract"] = abstract }
        if !record.citeKey.isEmpty { meta["cite_key"] = record.citeKey }
        return ChunkingService.DocumentChunk(
            id: id,
            text: text,
            source: source,
            page: page,
            headings: headings,
            metadata: meta,
            tokenCount: tokenCount,
            formattedContent: formattedContent,
            chunkIndex: chunkIndex,
            contentType: contentType,
            section: section,
            docTitle: record.title.isEmpty ? docTitle : record.title,
            authors: record.authors.isEmpty ? authors : record.authors,
            doi: record.doi ?? doi,
            documentId: documentId,
            url: url,
            year: record.year ?? year,
            language: language,
            embeddingText: embeddingText,
            pictureDescription: pictureDescription,
            pictureClass: pictureClass,
            tableMarkdown: tableMarkdown,
            pageEnd: pageEnd,
            bboxesJSON: bboxesJSON
        )
    }
}
