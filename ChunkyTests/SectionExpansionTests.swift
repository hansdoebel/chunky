import Testing

@testable import Chunky

struct SectionExpansionTests {
    @Test func enoughSiblingsMergeIntoOneSection() {
        let hits = [
            hit("a", source: "paper.pdf", headings: ["Methods"], page: 2, text: "First."),
            hit("c", source: "paper.pdf", headings: ["Methods"], page: 4, text: "Third."),
        ]
        let siblings = [
            sibling("a", source: "paper.pdf", headings: ["Methods"], page: 2, text: "First."),
            sibling("b", source: "paper.pdf", headings: ["Methods"], page: 3, text: "Second."),
            sibling("c", source: "paper.pdf", headings: ["Methods"], page: 4, text: "Third."),
        ]
        let merged = SectionExpansion.merge(hits: hits, siblings: siblings, threshold: 0.5)
        #expect(merged.count == 1)
        #expect(merged[0].source == "paper.pdf")
        #expect(merged[0].page == 2)
        #expect(merged[0].pageEnd == 4)
        #expect(merged[0].text == "First.\n\nSecond.\n\nThird.")
        #expect(merged[0].payload["chunk_ids"] == "a,c")
        #expect(merged[0].headings == ["Methods"])
    }

    @Test func tooFewSiblingsStaySeparate() {
        let hits = [
            hit("a", source: "paper.pdf", headings: ["Methods"], page: 2, text: "First."),
        ]
        let siblings = (1...4).map { index in
            sibling("s\(index)", source: "paper.pdf", headings: ["Methods"], page: index, text: "Part \(index).")
        }
        let merged = SectionExpansion.merge(hits: hits, siblings: siblings, threshold: 0.5)
        #expect(merged.count == 1)
        #expect(merged[0].id == "a")
        #expect(merged[0].text == "First.")
    }

    @Test func unmergedHitsKeepTheirRank() {
        let hits = [
            hit("a1", source: "paper.pdf", headings: ["A"], page: 1, text: "A1"),
            hit("b1", source: "paper.pdf", headings: ["B"], page: 1, text: "B1"),
            hit("a2", source: "paper.pdf", headings: ["A"], page: 2, text: "A2"),
        ]
        let siblings = hits.map { sibling($0.id, source: $0.source, headings: $0.headings, page: $0.page ?? 1, text: $0.text) }
            + [sibling("a3", source: "paper.pdf", headings: ["A"], page: 3, text: "A3")]
        let merged = SectionExpansion.merge(hits: hits, siblings: siblings, threshold: 0.9)
        #expect(merged.map(\.id) == ["a1", "b1", "a2"])
    }

    @Test func documentHitsStayInPlace() {
        var paper = hit("doc", source: "paper.pdf", headings: [], page: 1, text: "Abstract")
        paper.payload["record_type"] = "document"
        let passage = hit("a", source: "paper.pdf", headings: ["Methods"], page: 2, text: "Body")
        let merged = SectionExpansion.merge(hits: [paper, passage], siblings: [], threshold: 0.5)
        #expect(merged.map(\.id) == ["doc", "a"])
        #expect(merged[0].text == "Abstract")
    }

    @Test func samePageUsesChunkIndexOrder() {
        let hits = [
            hit("late", source: "paper.pdf", headings: ["Methods"], page: 2, text: "Late"),
            hit("early", source: "paper.pdf", headings: ["Methods"], page: 2, text: "Early"),
        ]
        let siblings = [
            SectionSibling(id: "late", source: "paper.pdf", headings: ["Methods"], page: 2, pageEnd: 2, text: "Late", chunkIndex: 2),
            SectionSibling(id: "early", source: "paper.pdf", headings: ["Methods"], page: 2, pageEnd: 2, text: "Early", chunkIndex: 1),
        ]
        let merged = SectionExpansion.merge(hits: hits, siblings: siblings, threshold: 0.5)
        #expect(merged.count == 1)
        #expect(merged[0].text == "Early\n\nLate")
    }

    @Test func differentDocumentsDoNotMerge() {
        let hits = [
            hit("a", source: "one.pdf", headings: ["Methods"], page: 1, text: "One."),
            hit("b", source: "two.pdf", headings: ["Methods"], page: 1, text: "Two."),
        ]
        let merged = SectionExpansion.merge(hits: hits, siblings: [], threshold: 0.5)
        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged.map(\.source) == ["one.pdf", "two.pdf"])
    }

    private func hit(_ id: String, source: String, headings: [String], page: Int, text: String) -> RetrievalHit {
        RetrievalHit(id: id, score: 0.5, text: text, source: source, page: page, headings: headings, payload: ["source": source])
    }

    private func sibling(_ id: String, source: String, headings: [String], page: Int, text: String) -> SectionSibling {
        SectionSibling(id: id, source: source, headings: headings, page: page, pageEnd: page, text: text)
    }
}
