import Testing

@testable import Chunky

@MainActor
struct ChunkPayloadTests {

    private func point(
        text: String,
        embeddingText: String?,
        contentType: String,
        pictureDescription: String? = nil,
        pictureClass: String? = nil,
        tableMarkdown: String? = nil
    ) -> ChunkPoint {
        let settings = IsolatedSettings.make()
        let previous = settings.enableEmbeddingCache
        settings.enableEmbeddingCache = false
        defer { settings.enableEmbeddingCache = previous }
        let chunk = ChunkingService.DocumentChunk(
            text: text,
            source: "paper.pdf",
            contentType: contentType,
            embeddingText: embeddingText,
            pictureDescription: pictureDescription,
            pictureClass: pictureClass,
            tableMarkdown: tableMarkdown
        )
        return DocumentProcessor().buildPoints(
            chunks: [chunk],
            embeddings: [[0.1, 0.2]],
            sparseVectors: [nil],
            settings: settings,
            ingestedAt: "2026-11-15T00:00:00Z"
        )[0]
    }

    private func payload(_ point: ChunkPoint) -> [String: String] {
        var fields = point.metadata
        fields["text"] = point.text
        return fields
    }

    @Test func plainTextPayloadStoresSerializedTextOnly() {
        let fields = payload(point(text: "Hello", embeddingText: "Hello", contentType: "text"))
        #expect(fields["text"] == "Hello")
        #expect(fields["embedding_text"] == "Hello")
        #expect(fields["content_type"] == "text")
        #expect(fields["picture_description"] == nil)
        #expect(fields["picture_class"] == nil)
        #expect(fields["table_markdown"] == nil)
    }

    @Test func picturePayloadStoresDescriptionAndClass() {
        let fields = payload(
            point(
                text: "Figure 1",
                embeddingText: "Figure 1\nA bar chart of revenue.",
                contentType: "picture",
                pictureDescription: "A bar chart of revenue.",
                pictureClass: "bar_chart"
            )
        )
        #expect(fields["text"] == "Figure 1\nA bar chart of revenue.")
        #expect(fields["embedding_text"] == "Figure 1\nA bar chart of revenue.")
        #expect(fields["content_type"] == "picture")
        #expect(fields["picture_description"] == "A bar chart of revenue.")
        #expect(fields["picture_class"] == "bar_chart")
        #expect(fields["table_markdown"] == nil)
    }

    @Test func tablePayloadStoresMarkdown() {
        let markdown = "| Year | Revenue |\n| --- | --- |\n| 2024 | 10 |"
        let fields = payload(
            point(
                text: "Year Revenue",
                embeddingText: "Year Revenue\n" + markdown,
                contentType: "table",
                tableMarkdown: markdown
            )
        )
        #expect(fields["text"] == "Year Revenue\n" + markdown)
        #expect(fields["embedding_text"] == fields["text"])
        #expect(fields["content_type"] == "table")
        #expect(fields["table_markdown"] == markdown)
        #expect(fields["picture_description"] == nil)
        #expect(fields["picture_class"] == nil)
    }
}
