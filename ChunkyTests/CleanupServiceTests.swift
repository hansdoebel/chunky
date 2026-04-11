import Foundation
import Testing

@testable import Chunky

struct CleanupServiceTests {
    let service = CleanupService()

    private func makeChunk(_ text: String, contentType: String = "text") -> ChunkingService.DocumentChunk {
        ChunkingService.DocumentChunk(
            text: text,
            source: "test.pdf",
            contentType: contentType
        )
    }

    @Test func doubledListMarkersRemoved() {
        let chunks = [makeChunk("- -Was war die Zielsetzung?\n- -Zweiter Punkt")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "- Was war die Zielsetzung?\n- Zweiter Punkt")
    }

    @Test func orphanListItemsRemoved() {
        let chunks = [makeChunk("Fazit\n-\nNächster Abschnitt")]
        let result = service.cleanup(chunks)
        #expect(!result[0].text.contains("\n-\n"))
    }

    @Test func multiSpaceCollapsed() {
        let chunks = [makeChunk("Verfügung  stehenden  Ressourcen")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "Verfügung stehenden Ressourcen")
    }

    @Test func runTogetherWordsSplitAtCaseBoundary() {
        let chunks = [makeChunk("amSeitenende")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "am Seitenende")
    }

    @Test func singleLetterSpaceRejoined() {
        let chunks = [makeChunk("P rojektberichtes")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "Projektberichtes")
    }

    @Test func letterDigitBoundarySpaced() {
        let chunks = [makeChunk("rechts2cm")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "rechts 2 cm")
    }

    @Test func digitLetterBoundarySpaced() {
        let chunks = [makeChunk("2cm breit")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "2 cm breit")
    }

    @Test func tocDetectionSetsContentType() {
        let tocText = """
        Inhaltsverzeichnis
        1. Einleitung 3
        2. Methodik 5
        3. Ergebnisse 10
        4. Diskussion 15
        5. Fazit 20
        """
        let chunks = [makeChunk(tocText)]
        let result = service.cleanup(chunks)
        #expect(result[0].contentType == "toc")
    }

    @Test func nonTocChunkUnchanged() {
        let chunks = [makeChunk("Dies ist ein normaler Absatz ohne besondere Probleme.")]
        let result = service.cleanup(chunks)
        #expect(result[0].contentType == "text")
        #expect(result[0].text == "Dies ist ein normaler Absatz ohne besondere Probleme.")
    }

    @Test func emptyChunksFiltered() {
        let chunks = [makeChunk("   \n  \n  ")]
        let result = service.cleanup(chunks)
        #expect(result.isEmpty)
    }

    @Test func tokenCountRecalculated() {
        let chunks = [makeChunk("Verfügung  stehenden  Ressourcen  sind  begrenzt")]
        let result = service.cleanup(chunks)
        let expectedTokens = result[0].text.count / 4
        #expect(result[0].tokenCount == max(1, expectedTokens))
    }

    @Test func formattedContentAlsoCleaned() {
        let chunk = ChunkingService.DocumentChunk(
            text: "amSeitenende",
            source: "test.pdf",
            formattedContent: "## Heading\n\namSeitenende"
        )
        let result = service.cleanup([chunk])
        #expect(result[0].formattedContent.contains("am Seitenende"))
    }

    @Test func multipleRulesAppliedTogether() {
        let chunks = [makeChunk("- -SoftwareLösung  für  rechts2cm")]
        let result = service.cleanup(chunks)
        #expect(result[0].text == "- Software Lösung für rechts 2 cm")
    }
}
