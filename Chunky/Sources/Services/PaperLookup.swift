import Foundation

enum PaperIdentifier: Equatable {
    case doi(String)
    case arxiv(String)
}

enum PaperIdentifierParser {
    static func parse(_ raw: String) -> PaperIdentifier? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let arxiv = arxivID(in: text) {
            return .arxiv(arxiv)
        }
        if let doi = doi(in: text) {
            return .doi(doi)
        }
        return nil
    }

    private static func arxivID(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("arxiv.org") || lower.hasPrefix("arxiv:") {
            return firstMatch(in: text, pattern: #"(?i)(?:arxiv:|abs/|pdf/)([a-z-]+(?:\.[a-z]{2})?/\d{7}|\d{4}\.\d{4,5})(?:v\d+)?"#)
        }
        if let modern = wholeMatch(text, pattern: #"\d{4}\.\d{4,5}(?:v\d+)?"#) {
            return stripVersion(modern)
        }
        if let legacy = wholeMatch(text, pattern: #"[A-Za-z-]+(?:\.[A-Za-z]{2})?/\d{7}"#) {
            return legacy
        }
        return nil
    }

    private static func doi(in text: String) -> String? {
        guard let found = firstMatch(in: text, pattern: #"(?i)(10\.\d{4,9}/[-._;()/:A-Z0-9]+)"#) else { return nil }
        return found.trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))
    }

    private static func stripVersion(_ value: String) -> String {
        guard let range = value.range(of: #"v\d+$"#, options: .regularExpression) else { return value }
        return String(value[..<range.lowerBound])
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let hit = Range(match.range(at: 1), in: text) else { return nil }
        return stripVersion(String(text[hit]))
    }

    private static func wholeMatch(_ text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard expression.firstMatch(in: text, range: range) != nil else { return nil }
        return text
    }
}

enum CrossrefPaper {
    static func metadata(_ payload: [String: Any], citeKey: String? = nil) -> BibliographicMetadata {
        let message = (payload["message"] as? [String: Any]) ?? payload
        let title = firstString(message["title"]) ?? ""
        let authors = (message["author"] as? [Any] ?? []).compactMap { item -> String? in
            guard let person = item as? [String: Any] else { return nil }
            let name = [person["given"] as? String, person["family"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return name.isEmpty ? nil : name
        }
        let doi = (message["DOI"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BibliographicMetadata(
            citeKey: citeKey ?? (doi?.isEmpty == false ? doi! : title),
            title: title,
            authors: authors,
            year: year(message["issued"]),
            doi: doi?.isEmpty == false ? doi : nil,
            venue: firstString(message["container-title"]),
            abstract: nonEmpty(message["abstract"] as? String),
            source: "crossref",
            pdfPath: nil
        )
    }

    static func openPDF(_ payload: [String: Any]) -> URL? {
        let message = (payload["message"] as? [String: Any]) ?? payload
        for item in message["link"] as? [Any] ?? [] {
            guard let link = item as? [String: Any] else { continue }
            let content = ((link["content-type"] as? String) ?? "").split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            let raw = (link["URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if content == "application/pdf", raw.lowercased().hasPrefix("http"), let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    static func request(doi: String) -> URLRequest {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        var request = URLRequest(url: URL(string: "https://api.crossref.org/works/\(encoded)")!)
        request.setValue("chunky (mailto:chunky@localhost)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func year(_ issued: Any?) -> Int? {
        guard let parts = (issued as? [String: Any])?["date-parts"] as? [Any],
              let row = parts.first as? [Any],
              let first = row.first else { return nil }
        if let number = first as? Int { return number }
        if let number = first as? NSNumber { return number.intValue }
        if let text = first as? String, let number = Int(text) { return number }
        return nil
    }

    private static func firstString(_ value: Any?) -> String? {
        if let text = value as? String { return nonEmpty(text) }
        if let list = value as? [Any], let text = list.first as? String { return nonEmpty(text) }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum ArXivPaper {
    static func metadata(atom: String, id: String) -> BibliographicMetadata? {
        guard let entry = AtomEntry(atom: atom) else { return nil }
        guard !entry.title.isEmpty else { return nil }
        return BibliographicMetadata(
            citeKey: "arxiv:\(id)",
            title: entry.title,
            authors: entry.names,
            year: entry.year,
            doi: entry.doi,
            venue: entry.journal,
            abstract: entry.summary,
            source: "arxiv",
            pdfPath: nil
        )
    }

    static func pdfURL(id: String) -> URL {
        URL(string: "https://export.arxiv.org/pdf/\(id).pdf")!
    }

    static func request(id: String) -> URLRequest {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: id)]
        return URLRequest(url: components.url!)
    }
}

private nonisolated final class AtomEntry: NSObject, XMLParserDelegate {
    var title = ""
    var names: [String] = []
    var year: Int?
    var doi: String?
    var journal: String?
    var summary: String?
    private var inEntry = false
    private var text = ""

    init?(atom: String) {
        super.init()
        let xml = atom
            .replacingOccurrences(of: "<arxiv:", with: "<")
            .replacingOccurrences(of: "</arxiv:", with: "</")
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        guard parser.parse(), !title.isEmpty else { return nil }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "entry" { inEntry = true }
        if inEntry { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard inEntry else { return }
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch name {
        case "title":
            if title.isEmpty { title = value }
        case "name":
            if !value.isEmpty { names.append(value) }
        case "published":
            year = Int(value.prefix(4))
        case "summary":
            summary = value.isEmpty ? nil : value
        case "doi":
            doi = value.isEmpty ? nil : value
        case "journal_ref":
            journal = value.isEmpty ? nil : value
        case "entry":
            inEntry = false
        default:
            break
        }
        text = ""
    }
}

struct PaperLookupResult: Equatable {
    var record: BibliographicMetadata
    var pdfURL: URL?
    var notice: String?
}

enum PaperLookup {
    static let needsPDF = "No open PDF. Attach a local file."

    static func result(identifier: PaperIdentifier, payload: [String: Any]) -> PaperLookupResult {
        let citeKey: String
        if case .doi(let value) = identifier {
            citeKey = value
        } else {
            citeKey = ""
        }
        let record = CrossrefPaper.metadata(payload, citeKey: citeKey)
        let pdf = CrossrefPaper.openPDF(payload)
        return PaperLookupResult(record: record, pdfURL: pdf, notice: pdf == nil ? needsPDF : nil)
    }

    static func result(identifier: PaperIdentifier, atom: String) -> PaperLookupResult? {
        guard case .arxiv(let id) = identifier, let record = ArXivPaper.metadata(atom: atom, id: id) else { return nil }
        return PaperLookupResult(record: record, pdfURL: ArXivPaper.pdfURL(id: id), notice: nil)
    }

    static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Data("%PDF".utf8))
    }

    static func attachIndex(in matches: [BibliographyMatch]) -> Int? {
        guard matches.count == 1, matches[0].pdf == nil else { return nil }
        return 0
    }
}

struct PaperLookupClient: Sendable {
    var session: URLSession = .shared

    func fetch(_ text: String) async throws -> PaperLookupResult {
        guard let identifier = PaperIdentifierParser.parse(text) else {
            throw URLError(.badURL)
        }
        switch identifier {
        case .doi(let doi):
            let (data, response) = try await session.data(for: CrossrefPaper.request(doi: doi))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            return PaperLookup.result(identifier: identifier, payload: payload)
        case .arxiv(let id):
            let (data, response) = try await session.data(for: ArXivPaper.request(id: id))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let atom = String(data: data, encoding: .utf8),
                  let found = PaperLookup.result(identifier: identifier, atom: atom) else {
                throw URLError(.badServerResponse)
            }
            return found
        }
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, PaperLookup.isPDF(data) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
