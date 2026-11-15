import Testing

@testable import Chunky

struct DocumentSummaryTests {
    @Test func abstractBeatsAGeneratedSummary() {
        let chunks = [
            SummaryChunk(text: "We study revenue.", headings: ["Abstract"], page: 1),
            SummaryChunk(text: "Later.", headings: ["Methods"], page: 3),
        ]
        var calls = 0
        let generated = DocumentSummary.abstractText(chunks: chunks) == nil ? { calls += 1; return "LLM" }() : nil
        let choice = DocumentSummary.resolve(chunks: chunks, title: "Revenue", generated: generated)
        #expect(choice.kind == "abstract")
        #expect(choice.text == "We study revenue.")
        #expect(calls == 0)
    }

    @Test func missingAbstractUsesTheGeneratedText() {
        let choice = DocumentSummary.resolve(
            chunks: [SummaryChunk(text: "Opening paragraph.", headings: ["Introduction"], page: 1)],
            title: "Revenue",
            generated: "A short generated abstract."
        )
        #expect(choice.kind == "generated")
        #expect(choice.text == "A short generated abstract.")
    }

    @Test func missingGeneratorFallsBackToTheOpeningPages() {
        let choice = DocumentSummary.resolve(
            chunks: [
                SummaryChunk(text: "Opening paragraph.", headings: ["Introduction"], page: 1),
                SummaryChunk(text: "Much later.", headings: ["Appendix"], page: 9),
            ],
            title: "Revenue",
            generated: "  "
        )
        #expect(choice.kind == "extract")
        #expect(choice.text.contains("Revenue"))
        #expect(choice.text.contains("Opening paragraph."))
        #expect(!choice.text.contains("Much later."))
    }

    @Test func summaryIdentityIsStableForASource() {
        #expect(DocumentSummary.summaryID(source: "paper.pdf") == "bdefd408-de82-54f7-b74f-8478d8f689e9")
        #expect(DocumentSummary.summaryID(source: "paper.pdf") == DocumentSummary.summaryID(source: "paper.pdf"))
    }

    @Test func defaultSearchDropsSummaryPointsAndPapersFirstKeepsThem() {
        let settings = IsolatedSettings.make()
        let chunks = RetrievalRequest.make(text: "revenue", collection: "documents", limit: 8, settings: settings).scopedFilters()
        let papers = RetrievalRequest.make(text: "revenue", collection: "documents", limit: 8, papersFirst: true, settings: settings).scopedFilters()
        let document: [String: Any] = ["record_type": "document", "text": "abstract", "source": "paper.pdf"]
        let body: [String: Any] = ["text": "body", "source": "paper.pdf"]
        #expect(!RetrievalFilter.keeps(document, filters: chunks))
        #expect(RetrievalFilter.keeps(body, filters: chunks))
        #expect(RetrievalFilter.keeps(document, filters: papers))
        #expect(!RetrievalFilter.keeps(body, filters: papers))
    }
}
