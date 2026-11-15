import AppKit
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct CitationExportTests {
    @Test func citeKeyAndPrintedPageWin() {
        let hit = RetrievalHit(
            id: "p1",
            score: 0.9,
            text: "Revenue grew.",
            source: "/papers/10.1000_xyz.pdf",
            page: 3,
            headings: [],
            payload: [
                "doc_title": "Analytical Engine",
                "authors": "Ada Lovelace; Alan Turing",
                "year": "2020",
                "doi": "10.1000/xyz",
                "venue": "Nature",
                "cite_key": "lovelace2020",
                "page_labels": "12 > 14",
                "abstract": "A & B 100%",
            ],
            docTitle: "Analytical Engine",
            pageEnd: 4
        )
        let source = CitationSource(hit: hit)
        #expect(CitationExport.typstCite(key: "lovelace2020", source: source) == "#cite(<lovelace2020>, supplement: [S. 12–14])")
        let bib = CitationExport.biblatex([source])
        #expect(bib.hasPrefix("@article{lovelace2020,"))
        #expect(bib.contains("author = {Lovelace, Ada and Turing, Alan},"))
        #expect(bib.contains("year = {2020},"))
        #expect(bib.contains("journal = {Nature},"))
        #expect(bib.contains("doi = {10.1000/xyz},"))
        #expect(bib.contains("pages = {12--14},"))
        #expect(bib.contains("abstract = {A \\& B 100\\%},"))
        let yml = CitationExport.hayagriva([source])
        #expect(yml.contains("lovelace2020:"))
        #expect(yml.contains("type: article"))
        #expect(yml.contains("title: \"Analytical Engine\""))
        #expect(yml.contains("family: \"Lovelace\""))
        #expect(yml.contains("given: \"Ada\""))
        #expect(yml.contains("family: \"Turing\""))
        #expect(yml.contains("date: 2020"))
        #expect(yml.contains("page-range: \"12-14\""))
        #expect(yml.contains("title: \"Nature\""))
    }

    @Test func pdfPageIsUsedWhenNoPrintedLabelExists() {
        let source = CitationSource(hit: RetrievalHit(
            id: "p2",
            score: 0.2,
            text: "Notes",
            source: "paper.pdf",
            page: 3,
            headings: [],
            payload: ["doc_title": "Notes", "authors": "Ada Lovelace", "year": "1999"],
            pageEnd: 5
        ))
        #expect(CitationExport.typstCites([source]) == "#cite(<lovelace-1999>, supplement: [S. 3–5])")
        #expect(CitationExport.biblatex([source]).contains("pages = {3--5},"))
    }

    @Test func singlePrintedLabelBeatsThePdfIndex() {
        let source = CitationSource(hit: RetrievalHit(
            id: "p3",
            score: 0.2,
            text: "Front matter",
            source: "paper.pdf",
            page: 2,
            headings: [],
            payload: ["doc_title": "Front", "page_labels": "ii"]
        ))
        #expect(source.pageLabels == ["ii"])
        #expect(CitationExport.typstCites([source]).contains("supplement: [S. ii]"))
        #expect(!CitationExport.typstCites([source]).contains("S. 2"))
    }

    @Test func fileNameStillProducesARecord() {
        let source = CitationSource(hit: RetrievalHit(
            id: "p4",
            score: 0,
            text: "",
            source: "scan.pdf",
            page: nil,
            headings: [],
            payload: [:]
        ))
        let bib = CitationExport.biblatex([source])
        #expect(bib.contains("@misc{scan-nd,"))
        #expect(bib.contains("title = {scan.pdf},"))
        #expect(!bib.contains("author ="))
        #expect(CitationExport.typstCites([source]) == "#cite(<scan-nd>)")
        let yml = CitationExport.hayagriva([source])
        #expect(yml.contains("type: misc"))
        #expect(yml.contains("title: \"scan.pdf\""))
    }

    @Test func particlesStayWithTheSurnameAndKeysStayUnique() {
        let first = CitationSource(hit: RetrievalHit(
            id: "a",
            score: 1,
            text: "One",
            source: "a.pdf",
            page: 1,
            headings: [],
            payload: ["doc_title": "Partizipation", "authors": "Hella von Unger", "year": "2014"]
        ))
        let second = CitationSource(hit: RetrievalHit(
            id: "b",
            score: 1,
            text: "Two",
            source: "b.pdf",
            page: 1,
            headings: [],
            payload: ["doc_title": "Partizipation", "authors": "Hella von Unger", "year": "2014"]
        ))
        #expect(CitationExport.familyName("Hella von Unger") == "von Unger")
        let bib = CitationExport.biblatex([first, second])
        #expect(bib.contains("author = {von Unger, Hella},"))
        #expect(bib.contains("@misc{vonunger-2014,"))
        #expect(bib.contains("@misc{vonunger-2014-2,"))
        let yml = CitationExport.hayagriva([first, second])
        #expect(yml.contains("vonunger-2014:"))
        #expect(yml.contains("vonunger-2014-2:"))
        #expect(yml.contains("family: \"von Unger\""))
    }

    @Test func styleFileCarriesTheAnhangCDeviations() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chunky/Resources/iu-apa7.csl")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("delimiter-precedes-last=\"never\""))
        #expect(text.contains("demote-non-dropping-particle=\"never\""))
        #expect(text.contains("default-locale=\"de-DE\""))
        #expect(text.contains("Hrsg."))
        #expect(text.contains("Kap."))
        #expect(text.contains("Aufl."))
        #expect(text.contains("Vorab-Onlinepublikation"))
        #expect(text.contains("Januar"))
        #expect(text.contains("<single>S.</single>"))
        #expect(!text.contains("original-date"))
        #expect(!text.contains("accessed"))
    }

    @Test func rendersTheExportActions() throws {
        let matched = CitationSource(hit: RetrievalHit(
            id: "p1",
            score: 0.91,
            text: "Revenue grew in the first quarter.",
            source: "paper.pdf",
            page: 4,
            headings: ["Results"],
            payload: [
                "doc_title": "Analytical Engine",
                "authors": "Ada Lovelace",
                "year": "2020",
                "doi": "10.1000/xyz",
                "venue": "Nature",
                "cite_key": "lovelace2020",
                "page_labels": "12",
            ],
            docTitle: "Analytical Engine"
        ))
        let bare = CitationSource(hit: RetrievalHit(
            id: "p2",
            score: 0.2,
            text: "Scan",
            source: "scan.pdf",
            page: nil,
            headings: [],
            payload: [:]
        ))
        let view = CitationExportBar(records: [matched, bare])
            .frame(width: 760, height: 220, alignment: .top)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-citation-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("citation-export.png"))
    }
}
