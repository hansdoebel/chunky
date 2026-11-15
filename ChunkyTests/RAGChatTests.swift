import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

struct RAGChatTests {

    @Test func promptCarriesChunkIdentityAndScore() {
        let bundle = RAGPrompt.assemble(question: "How did revenue change?", hits: Self.hits)
        #expect(bundle.system.contains("[1]"))
        #expect(bundle.user.contains("id=p1"))
        #expect(bundle.user.contains("source=paper.pdf"))
        #expect(bundle.user.contains("page=2"))
        #expect(bundle.user.contains("score=0.912"))
        #expect(bundle.user.contains("id=p2"))
        #expect(bundle.user.contains("page=4"))
        #expect(bundle.citations.map(\.id) == ["p1", "p2"])
        #expect(bundle.citations.map(\.marker) == ["[1]", "[2]"])
    }

    @Test func parserSplitsClickableCitationMarkers() {
        let citations = RAGPrompt.assemble(question: "q", hits: Self.hits).citations
        let segments = RAGCitationParser.segments(in: "Revenue grew [1]. See [2] and [9].", citations: citations)
        #expect(segments.count == 5)
        guard case .text(let lead) = segments[0] else { Issue.record("lead"); return }
        #expect(lead == "Revenue grew ")
        guard case .citation(let first) = segments[1] else { Issue.record("first"); return }
        #expect(first.id == "p1")
        #expect(first.source == "paper.pdf")
        #expect(first.page == 2)
        #expect(first.score == 0.912)
        guard case .citation(let second) = segments[3] else { Issue.record("second"); return }
        #expect(second.id == "p2")
        guard case .text(let unknown) = segments[4] else { Issue.record("unknown"); return }
        #expect(unknown.contains("[9]"))
    }

    @Test func mockChatStreamsTheCitedAnswer() async throws {
        let bundle = RAGPrompt.assemble(question: "How did revenue change?", hits: Self.hits)
        let http = RAGScriptedHTTP()
        http.chunks = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"Revenue grew [1].\"}}]}\ndata: [DONE]\n".utf8)]
        let chat = OpenAIRAGChat(
            client: OpenAICompatibleChatClient(
                baseURL: "http://127.0.0.1:11434/v1",
                model: "qwen3",
                apiKey: "super-secret-token",
                http: http
            )
        )
        var text = ""
        for try await delta in chat.stream(system: bundle.system, user: bundle.user) {
            text += delta
        }
        #expect(text == "Revenue grew [1].")
        let body = try JSONSerialization.jsonObject(with: http.requests[0].httpBody ?? Data())
        let messages = PiJSONL.dictionary(body)?["messages"] as? [[String: Any]]
            ?? (PiJSONL.dictionary(body)?["messages"] as? [Any])?.compactMap { $0 as? [String: Any] }
        #expect(messages?.first?["role"] as? String == "system")
        #expect((messages?.last?["content"] as? String)?.contains("id=p1") == true)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer super-secret-token")
        let segments = RAGCitationParser.segments(in: text, citations: bundle.citations)
        let cited = segments.compactMap { segment -> RAGCitation? in
            if case .citation(let citation) = segment { return citation }
            return nil
        }
        #expect(cited.first?.id == "p1")
        #expect(cited.first?.score == 0.912)
    }

    @Test @MainActor func ragAnswerRendersCitations() throws {
        let hits = Self.hits
        let citations = RAGPrompt.assemble(question: "How did revenue change?", hits: hits).citations
        let host = RetrievalScreenshotHost(
            hits: hits,
            answer: "Revenue grew after the index change [1].",
            citations: citations,
            selectedHitID: "p1"
        )
        .frame(width: 960, height: 720)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-chat-settings-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("rag-chat-citations.png"))
    }

    private static let hits = [
        RetrievalHit(
            id: "p1",
            score: 0.912,
            text: "Revenue grew after the hybrid index was enabled.",
            source: "paper.pdf",
            page: 2,
            headings: ["Results"],
            payload: ["text": "Revenue grew after the hybrid index was enabled.", "source": "paper.pdf", "page": "2"]
        ),
        RetrievalHit(
            id: "p2",
            score: 0.640,
            text: "Table 1 lists quarterly revenue.",
            source: "paper.pdf",
            page: 4,
            headings: ["Tables"],
            payload: ["text": "Table 1 lists quarterly revenue.", "source": "paper.pdf", "page": "4"]
        )
    ]
}

private final class RAGScriptedHTTP: ChatHTTPStreaming, @unchecked Sendable {
    var requests: [URLRequest] = []
    var chunks: [Data] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{}".utf8), response)
    }

    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let chunks = chunks
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (response, stream)
    }
}
