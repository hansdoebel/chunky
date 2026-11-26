import Foundation
import ChunkyVectorStore

enum PgVectorBridge {
    static func distance(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dot", "dot product", "dotproduct":
            return "dot"
        case "euclid", "euclidean":
            return "euclid"
        default:
            return "cosine"
        }
    }

    static func store(url: String, distance: String) throws -> PgVectorStore {
        PgVectorStore(database: try PostgresNIODatabase(url: url), distance: distance)
    }

    static func record(_ point: ChunkPoint) -> VectorRecord {
        var fields: [String: JSONValue] = [
            "text": .string(point.text),
            "source": .string(point.source),
        ]
        if let page = point.page {
            fields["page"] = .int(page)
        }
        if let year = point.year {
            fields["year"] = .int(year)
        }
        if !point.headings.isEmpty {
            fields["headings"] = .array(point.headings.map { .string($0) })
        }
        if !point.contentTypes.isEmpty {
            fields["content_types"] = .array(point.contentTypes.map { .string($0) })
        }
        if let formulaLatex = point.formulaLatex, !formulaLatex.isEmpty {
            fields["formula_latex"] = .string(formulaLatex)
        }
        for (key, value) in point.metadata {
            if key == "page_end" || key == "chunk_index", let number = Int(value) {
                fields[key] = .int(number)
            } else {
                fields[key] = .string(value)
            }
        }
        return VectorRecord(id: point.id, vector: point.vector.map(Double.init), payload: .object(fields))
    }

    static func filter(_ filter: RetrievalFilter) -> VectorFilter {
        let match: VectorFilter.Match?
        switch filter.match {
        case .text(let value):
            match = .text(value)
        case .integer(let value):
            match = .int(value)
        case .boolean(let value):
            match = .bool(value)
        case .contains(let value):
            match = .contains(value)
        case .anyText(let values):
            match = .any(values)
        case nil:
            match = nil
        }
        return VectorFilter(
            key: filter.key,
            match: match,
            gt: filter.gt,
            gte: filter.gte,
            lt: filter.lt,
            lte: filter.lte,
            negated: filter.negated,
            should: filter.should,
            matchEmpty: filter.matchEmpty
        )
    }

    static func hit(_ hit: VectorHit) -> RetrievalHit {
        let fields = object(hit.payload)
        let headings = strings(fields["headings"])
        var payload: [String: String] = [:]
        for (key, value) in fields {
            switch value {
            case .string(let text):
                payload[key] = text
            case .int(let number):
                payload[key] = String(number)
            case .double(let number):
                payload[key] = String(number)
            case .bool(let flag):
                payload[key] = flag ? "true" : "false"
            case .array:
                if key == "headings" {
                    payload[key] = headings.joined(separator: " > ")
                }
            case .object, .null:
                break
            }
        }
        return RetrievalHit(
            id: hit.id,
            score: hit.score,
            text: payload["text"] ?? "",
            source: payload["source"] ?? "",
            page: intValue(fields["page"]),
            headings: headings,
            payload: payload,
            docTitle: payload["doc_title"] ?? "",
            pageEnd: intValue(fields["page_end"])
        )
    }

    private static func object(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let fields) = value { return fields }
        return [:]
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            if case .string(let text) = item { return text }
            return nil
        }
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let number):
            return number
        case .string(let text):
            return Int(text)
        default:
            return nil
        }
    }
}
