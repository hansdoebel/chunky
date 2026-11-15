import Foundation
import Testing

@testable import Chunky

@MainActor
struct PaperLibraryTests {
    @Test func defaultLibraryKeepsUntaggedPointsAndDropsAnotherLibrary() {
        let filters = LibraryFilter.filters(activeID: PaperLibrary.defaultID, selectedIDs: [], scope: .active)
        #expect(LibraryFilter.keeps([:], filters: filters))
        #expect(LibraryFilter.keeps(["library_id": ""], filters: filters))
        #expect(LibraryFilter.keeps(["library_id": PaperLibrary.defaultID], filters: filters))
        #expect(!LibraryFilter.keeps(["library_id": "thesis"], filters: filters))
    }

    @Test func libraryADoesNotReturnLibraryB() {
        let filters = LibraryFilter.membership(ids: ["thesis"])
        #expect(LibraryFilter.keeps(["library_id": "thesis", "text": "kept"], filters: filters))
        #expect(!LibraryFilter.keeps(["library_id": "notes", "text": "other"], filters: filters))
        #expect(!LibraryFilter.keeps([:], filters: filters))
        let all = LibraryFilter.filters(activeID: "thesis", selectedIDs: [], scope: .all)
        #expect(all.isEmpty)
        #expect(LibraryFilter.keeps(["library_id": "notes"], filters: all))
    }

    @Test func selectedSetIncludesTheDefaultLibraryWhenAsked() {
        let filters = LibraryFilter.filters(activeID: "thesis", selectedIDs: ["thesis", PaperLibrary.defaultID], scope: .selected)
        #expect(LibraryFilter.keeps(["library_id": "thesis"], filters: filters))
        #expect(LibraryFilter.keeps([:], filters: filters))
        #expect(!LibraryFilter.keeps(["library_id": "notes"], filters: filters))
    }

    @Test func newLibraryGetsAStableSlugAndAMoveDoesNotReembed() {
        let first = PaperLibrary.adding(name: "Thesis", to: [PaperLibrary.starter])
        let second = PaperLibrary.adding(name: "thesis", to: first)
        #expect(first.map(\.id) == [PaperLibrary.defaultID, "thesis"])
        #expect(second.map(\.id) == first.map(\.id))
        let again = PaperLibrary.adding(name: "Thesis Notes", to: first)
        #expect(again.last?.id == "thesis-notes")
    }

    @Test func backfillWritesTheDefaultLibraryAndAMoveDoesNotReembed() {
        #expect(LibraryFilter.backfill(existing: nil) == PaperLibrary.defaultID)
        #expect(LibraryFilter.backfill(existing: "  ") == PaperLibrary.defaultID)
        #expect(LibraryFilter.backfill(existing: "thesis") == nil)
        let move = LibraryMove.plan(ids: ["a", "b"], libraryID: "thesis")
        #expect(move.payload == ["library_id": "thesis"])
        #expect(move.ids == ["a", "b"])
        #expect(move.reembed == false)
    }

    @Test func payloadWriteUsesTheActiveLibrary() {
        let settings = IsolatedSettings.make()
        settings.activeLibraryID = "thesis"
        let chunk = ChunkingService.DocumentChunk(text: "Hello", source: "paper.pdf", contentType: "text")
        let point = DocumentProcessor().buildPoints(
            chunks: [chunk],
            embeddings: [[0.1]],
            sparseVectors: [nil],
            settings: settings,
            ingestedAt: "2026-11-15T00:00:00Z"
        )[0]
        #expect(point.metadata["library_id"] == "thesis")
        #expect(point.vector == [0.1])
    }

    @Test func sectionSiblingsStayInsideTheSearchedLibrary() {
        let filters = LibraryFilter.membership(ids: ["thesis"])
        let siblings = [
            SectionSibling(id: "a", source: "paper.pdf", headings: ["Results"], text: "A", libraryID: "thesis"),
            SectionSibling(id: "b", source: "paper.pdf", headings: ["Results"], text: "B", libraryID: "notes"),
            SectionSibling(id: "c", source: "paper.pdf", headings: ["Results"], text: "C"),
        ]
        let kept = SectionExpansion.restricting(siblings, filters: filters)
        #expect(kept.map(\.id) == ["a"])
        #expect(LibraryFilter.belongs(existing: nil, to: PaperLibrary.defaultID))
        #expect(!LibraryFilter.belongs(existing: "thesis", to: PaperLibrary.defaultID))
        #expect(LibraryFilter.belongs(existing: "thesis", to: "thesis"))
    }

    @Test func integerPointIDsStayIntegers() {
        #expect(StoredPointID.wire("42") == "integer:42")
        #expect(StoredPointID.wire("bdefd408-de82-54f7-b74f-8478d8f689e9") == "uuid:bdefd408-de82-54f7-b74f-8478d8f689e9")
    }

    @Test func mcpReadsTheLibrarySavedAfterStartup() {
        let name = "chunky-library-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let second = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        second.activeLibraryID = "thesis"
        #expect(first.activeLibraryID == PaperLibrary.defaultID)
        #expect(first.storedActiveLibraryID() == "thesis")
    }

    @Test func scopedSearchCarriesTheLibraryFilter() {
        let settings = IsolatedSettings.make()
        settings.activeLibraryID = "thesis"
        let request = RetrievalRequest.make(
            text: "revenue",
            collection: "documents",
            limit: 5,
            librarySearch: .active,
            settings: settings
        )
        let filters = request.scopedFilters()
        #expect(filters.contains { $0.key == "library_id" && $0.match == .text("thesis") })
        #expect(!LibraryFilter.keeps(["library_id": "notes"], filters: filters))
        #expect(LibraryFilter.keeps(["library_id": "thesis"], filters: filters))
    }
}
