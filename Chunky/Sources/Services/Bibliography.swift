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
            guard let opener = text[typeStart...].firstIndex(where: { $0 == "{" || $0 == "(" }) else { break }
            let type = text[typeStart..<opener].filter { !$0.isWhitespace }.lowercased()
            let closer: Character = text[opener] == "{" ? "}" : ")"
            let afterOpener = text.index(after: opener)
            guard let comma = text[afterOpener...].firstIndex(of: ",") else { break }
            let key = text[afterOpener..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            var fields: [String: String] = [:]
            var index = text.index(after: comma)
            var depth = 1
            var name = ""
            var value = ""
            var readingName = true
            var quote: Character?
            while index < text.endIndex && depth > 0 {
                let character = text[index]
                if quote != nil {
                    if character == quote {
                        quote = nil
                    } else {
                        value.append(character)
                    }
                } else if character == "{" || character == "(" {
                    depth += 1
                    if !readingName { value.append(character) }
                } else if character == closer || character == "}" || character == ")" {
                    depth -= 1
                    if depth == 0 {
                        store(&fields, name: name, value: value)
                        break
                    }
                    if !readingName { value.append(character) }
                } else if character == "\"" {
                    quote = character
                } else if character == "=" && readingName {
                    readingName = false
                } else if character == "," && depth == 1 {
                    store(&fields, name: name, value: value)
                    name = ""
                    value = ""
                    readingName = true
                } else if readingName {
                    name.append(character)
                } else {
                    value.append(character)
                }
                index = text.index(after: index)
            }
            if !["comment", "string", "preamble"].contains(type), !key.isEmpty {
                records.append(record(key: key, fields: fields, source: "bibtex"))
            }
            cursor = index < text.endIndex ? text.index(after: index) : text.endIndex
        }
        return records
    }

    private static func store(_ fields: inout [String: String], name: String, value: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !cleaned.isEmpty else { return }
        fields[key] = cleaned
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
            if let pdf = pdfs.first(where: { file($0, matches: record) }) {
                return BibliographyMatch(record: record, pdf: pdf, warning: nil)
            }
            return BibliographyMatch(record: record, pdf: nil, warning: "No PDF for \(record.citeKey)")
        }
    }

    static func file(_ url: URL, matches record: BibliographicMetadata) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if stem == record.citeKey.lowercased() { return true }
        guard let doi = record.doi?.lowercased(), !doi.isEmpty else { return false }
        let collapsed = doi.replacingOccurrences(of: "/", with: "")
        let underscored = doi.replacingOccurrences(of: "/", with: "_")
        let dashed = doi.replacingOccurrences(of: "/", with: "-")
        return [doi, collapsed, underscored, dashed].contains { stem.contains($0) }
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
    static func itemsRequest(baseURL: URL, apiKey: String) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = baseURL.path.appending("/users/0/items")
        components?.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "limit", value: "100")]
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
