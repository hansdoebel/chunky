import Foundation

struct RAGCitation: Equatable, Identifiable, Sendable {
    var id: String
    var marker: String
    var source: String
    var docTitle: String
    var page: Int?
    var pageEnd: Int?
    var score: Double

    var paperLabel: String {
        let title = docTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = (source as NSString).lastPathComponent
        if !title.isEmpty { return title }
        return file.isEmpty ? source : file
    }

    var pageLabel: String? {
        guard let page else { return nil }
        if let pageEnd, pageEnd != page {
            return "pp. \(page)–\(pageEnd)"
        }
        return "p. \(page)"
    }

    var citeLabel: String {
        if let pageLabel {
            return "\(paperLabel), \(pageLabel)"
        }
        return paperLabel
    }
}

struct RAGPromptBundle: Equatable, Sendable {
    var system: String
    var user: String
    var citations: [RAGCitation]
}

enum RAGSegment: Equatable, Sendable {
    case text(String)
    case citation(RAGCitation)
}

enum RAGPrompt {
    static func assemble(question: String, hits: [RetrievalHit]) -> RAGPromptBundle {
        var citations: [RAGCitation] = []
        var blocks: [String] = []
        for (offset, hit) in hits.enumerated() {
            let marker = "[\(offset + 1)]"
            let citation = RAGCitation(
                id: hit.id,
                marker: marker,
                source: hit.source,
                docTitle: hit.docTitle,
                page: hit.page,
                pageEnd: hit.pageEnd,
                score: hit.score
            )
            citations.append(citation)
            let page = citation.pageLabel ?? ""
            blocks.append(
                """
                \(marker) id=\(hit.id) paper=\(citation.paperLabel) source=\(hit.source) page=\(page) score=\(String(format: "%.3f", hit.score))
                \(hit.text)
                """
            )
        }
        let system = "Answer using only the retrieved chunks. Cite a chunk with its marker, such as [1]. Each marker stands for that chunk's id, source, page, and score."
        let user = "Question: \(question)\n\nRetrieved chunks:\n\n\(blocks.joined(separator: "\n\n"))"
        return RAGPromptBundle(system: system, user: user, citations: citations)
    }
}

enum RAGCitationParser {
    static func segments(in text: String, citations: [RAGCitation]) -> [RAGSegment] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\d+\]"#) else {
            return text.isEmpty ? [] : [.text(text)]
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return text.isEmpty ? [] : [.text(text)]
        }
        var segments: [RAGSegment] = []
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            if cursor < matchRange.lowerBound {
                segments.append(.text(String(text[cursor..<matchRange.lowerBound])))
            }
            let marker = String(text[matchRange])
            if let citation = citations.first(where: { $0.marker == marker }) {
                segments.append(.citation(citation))
            } else {
                segments.append(.text(marker))
            }
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex {
            segments.append(.text(String(text[cursor...])))
        }
        return mergeText(segments)
    }

    private static func mergeText(_ segments: [RAGSegment]) -> [RAGSegment] {
        var merged: [RAGSegment] = []
        for segment in segments {
            guard case .text(let next) = segment, case .text(let previous) = merged.last else {
                merged.append(segment)
                continue
            }
            merged.removeLast()
            merged.append(.text(previous + next))
        }
        return merged
    }
}

protocol RAGChatStreaming: Sendable {
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error>
    func abort() async
}

struct OpenAIRAGChat: RAGChatStreaming {
    var client: OpenAICompatibleChatClient

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        client.stream(system: system, user: user)
    }

    func abort() async {
        await client.abort()
    }
}
