import Foundation

struct RAGCitation: Equatable, Identifiable, Sendable {
    var id: String
    var marker: String
    var source: String
    var page: Int?
    var score: Double
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
            citations.append(
                RAGCitation(
                    id: hit.id,
                    marker: marker,
                    source: hit.source,
                    page: hit.page,
                    score: hit.score
                )
            )
            let page = hit.page.map(String.init) ?? ""
            blocks.append(
                """
                \(marker) id=\(hit.id) source=\(hit.source) page=\(page) score=\(String(format: "%.3f", hit.score))
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
        return segments
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
