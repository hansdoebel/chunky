import AppKit
import SwiftUI
import Testing

@testable import Chunky

struct BibliographyTests {
    @Test func parsesBibTeXAndMatchesPdfs() {
        let text = """
        @comment{skip me}
        @article{lovelace2020,
          title = {Analytical {Engine}},
          author = {Lovelace, Ada and Turing, Alan},
          year = {2020},
          doi = {10.1000/xyz},
          journal = {Nature},
          abstract = {A short abstract.}
        }
        @article{aftercomment,
          title = {Why (},
          year = {1999}
        }
        """
        let records = BibTeXParser.parse(text)
        #expect(records.count == 2)
        #expect(records[0].citeKey == "lovelace2020")
        #expect(records[0].title == "Analytical Engine")
        #expect(records[0].authors == ["Ada Lovelace", "Alan Turing"])
        #expect(records[0].year == 2020)
        #expect(records[0].doi == "10.1000/xyz")
        #expect(records[0].venue == "Nature")
        #expect(records[0].abstract == "A short abstract.")
        let folder = URL(fileURLWithPath: "/tmp")
        let matched = BibliographyFiles.match(records, pdfs: [
            folder.appendingPathComponent("notes.pdf"),
            folder.appendingPathComponent("10.1000_xyz.pdf"),
        ])
        #expect(matched[0].pdf?.lastPathComponent == "10.1000_xyz.pdf")
        #expect(matched[0].warning == nil)
        let missing = BibliographyFiles.match(records, pdfs: [folder.appendingPathComponent("other.pdf")])
        #expect(missing[0].pdf == nil)
        #expect(missing[0].warning == "No PDF for lovelace2020")
        #expect(records[1].title == "Why (")
        let prefix = BibliographyFiles.match(
            [records[0]],
            pdfs: [
                folder.appendingPathComponent("10.1000_xyz123.pdf"),
                folder.appendingPathComponent("10.1000_xyz.pdf"),
            ]
        )
        #expect(prefix[0].pdf?.lastPathComponent == "10.1000_xyz.pdf")
    }

    @Test func parsesZoteroItemsAndRedactsTheKey() throws {
        let items = """
        [{"key":"ITEM1","data":{"itemType":"journalArticle","title":"Local Paper","creators":[{"firstName":"Ada","lastName":"Lovelace"}],"date":"2019-05-01","DOI":"10.5555/local","publicationTitle":"Notes","abstractNote":"From Zotero","citationKey":"lovelace2019"}}]
        """.data(using: .utf8)!
        let attachments = """
        [{"data":{"parentItem":"ITEM1","contentType":"application/pdf","filename":"paper.pdf","path":"/Users/me/Zotero/paper.pdf"}}]
        """.data(using: .utf8)!
        let records = try ZoteroLibraryParser.records(itemsJSON: items, attachmentsJSON: attachments)
        #expect(records.count == 1)
        #expect(records[0].citeKey == "lovelace2019")
        #expect(records[0].authors == ["Ada Lovelace"])
        #expect(records[0].year == 2019)
        #expect(records[0].doi == "10.5555/local")
        #expect(records[0].venue == "Notes")
        #expect(records[0].pdfPath == "/Users/me/Zotero/paper.pdf")
        let request = ZoteroLocalAPI.itemsRequest(baseURL: URL(string: "http://127.0.0.1:23119/api")!, apiKey: "super-secret")
        #expect(request.value(forHTTPHeaderField: "Zotero-API-Key") == "super-secret")
        #expect(request.url?.path.hasSuffix("/users/0/items") == true)
        let line = ZoteroLocalAPI.redacted(request)
        #expect(!line.contains("super-secret"))
        #expect(line.contains("[redacted]"))
    }

    @MainActor
    @Test func bibliographyWinsOverDoclingFields() {
        let chunk = ChunkingService.DocumentChunk(
            text: "Hello",
            source: "paper.pdf",
            docTitle: "Weak",
            authors: ["Nobody"],
            year: 1999
        )
        let record = BibliographicMetadata(
            citeKey: "lovelace2020",
            title: "Ground Truth",
            authors: ["Ada Lovelace"],
            year: 2020,
            doi: "10.1000/xyz",
            venue: "Nature",
            abstract: "A short abstract.",
            source: "bibtex",
            pdfPath: nil
        )
        let applied = chunk.applyingBibliography(record)
        #expect(applied.docTitle == "Ground Truth")
        #expect(applied.authors == ["Ada Lovelace"])
        #expect(applied.year == 2020)
        #expect(applied.doi == "10.1000/xyz")
        #expect(applied.metadata["venue"] == "Nature")
        #expect(applied.metadata["abstract"] == "A short abstract.")
        #expect(applied.metadata["cite_key"] == "lovelace2020")
        #expect(applied.metadata["metadata_source"] == "bibtex")
        let settings = IsolatedSettings.make()
        let points = DocumentProcessor().buildPoints(
            chunks: [applied],
            embeddings: [[0.1, 0.2]],
            sparseVectors: [nil],
            settings: settings,
            ingestedAt: "2026-11-15T00:00:00Z"
        )
        #expect(points[0].metadata["doc_title"] == "Ground Truth")
        #expect(points[0].metadata["authors"] == "Ada Lovelace")
        #expect(points[0].metadata["doi"] == "10.1000/xyz")
        #expect(points[0].metadata["venue"] == "Nature")
        #expect(points[0].metadata["cite_key"] == "lovelace2020")
        #expect(points[0].metadata["metadata_source"] == "bibtex")
    }

    @Test func parsesDOIAndArXivIdentifiers() {
        #expect(PaperIdentifierParser.parse("10.1000/xyz.") == .doi("10.1000/xyz"))
        #expect(PaperIdentifierParser.parse("https://doi.org/10.5555/abc") == .doi("10.5555/abc"))
        #expect(PaperIdentifierParser.parse("https://dx.doi.org/10.5555/abc") == .doi("10.5555/abc"))
        #expect(PaperIdentifierParser.parse("arXiv:2101.00001v2") == .arxiv("2101.00001"))
        #expect(PaperIdentifierParser.parse("https://arxiv.org/abs/2101.00001") == .arxiv("2101.00001"))
        #expect(PaperIdentifierParser.parse("https://arxiv.org/pdf/2101.00001.pdf") == .arxiv("2101.00001"))
        #expect(PaperIdentifierParser.parse("https://export.arxiv.org/abs/hep-th/9901001") == .arxiv("hep-th/9901001"))
        #expect(PaperIdentifierParser.parse("hep-th/9901001") == .arxiv("hep-th/9901001"))
        #expect(PaperIdentifierParser.parse("not a paper") == nil)
    }

    @Test func doiFillsMetadataAndDownloadsOnlyAnOpenPDF() throws {
        let closed = try json("""
        {"message":{"title":["Confirmed"],"author":[{"given":"Ada","family":"Lovelace"}],"issued":{"date-parts":[[2021]]},"container-title":["Real Journal"],"DOI":"10.1000/xyz","abstract":"A short abstract.","link":[{"URL":"https://publisher.example/article","content-type":"text/html"}]}}
        """)
        let hidden = PaperLookup.result(identifier: .doi("10.1000/xyz"), payload: closed)
        #expect(hidden.record.source == "crossref")
        #expect(hidden.record.title == "Confirmed")
        #expect(hidden.record.authors == ["Ada Lovelace"])
        #expect(hidden.record.year == 2021)
        #expect(hidden.record.venue == "Real Journal")
        #expect(hidden.record.doi == "10.1000/xyz")
        #expect(hidden.pdfURL == nil)
        #expect(hidden.notice == PaperLookup.needsPDF)
        let open = try json("""
        {"message":{"title":["Confirmed"],"author":[{"given":"Ada","family":"Lovelace"}],"issued":{"date-parts":[[2021]]},"container-title":["Real Journal"],"DOI":"10.1000/xyz","link":[{"URL":"https://publisher.example/article","content-type":"text/html"},{"URL":"https://publisher.example/paper.pdf","content-type":"application/pdf"}]}}
        """)
        let downloaded = PaperLookup.result(identifier: .doi("10.1000/xyz"), payload: open)
        #expect(downloaded.pdfURL?.absoluteString == "https://publisher.example/paper.pdf")
        #expect(downloaded.notice == nil)
        let request = CrossrefPaper.request(doi: "10.1000/xyz")
        #expect(request.url?.absoluteString == "https://api.crossref.org/works/10.1000/xyz")
    }

    @Test func arxivCreatesMetadataAndAPDFLink() throws {
        let atom = """
        <feed><title>ArXiv Query</title>
        <entry>
          <title>A &amp; B</title>
          <author><name>Ada Lovelace</name></author>
          <author><name>Alan Turing</name></author>
          <published>2021-03-04T00:00:00Z</published>
          <summary>A short abstract.</summary>
          <arxiv:doi>10.1000/xyz</arxiv:doi>
          <arxiv:journal_ref>Real Journal</arxiv:journal_ref>
        </entry>
        </feed>
        """
        let found = try #require(PaperLookup.result(identifier: .arxiv("2101.00001"), atom: atom))
        #expect(found.record.source == "arxiv")
        #expect(found.record.citeKey == "arxiv:2101.00001")
        #expect(found.record.title == "A & B")
        #expect(found.record.authors == ["Ada Lovelace", "Alan Turing"])
        #expect(found.record.year == 2021)
        #expect(found.record.doi == "10.1000/xyz")
        #expect(found.record.venue == "Real Journal")
        #expect(found.record.abstract == "A short abstract.")
        #expect(found.pdfURL == ArXivPaper.pdfURL(id: "2101.00001"))
        #expect(found.notice == nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("arxiv-2101.00001.pdf")
        try Data("%PDF-1.1".utf8).write(to: pdf)
        let match = BibliographyMatch(record: found.record, pdf: pdf, warning: nil)
        let state = AppState()
        state.importBibliography([match])
        #expect(state.jobs.count == 1)
        #expect(state.jobs[0].bibliography?.source == "arxiv")
        #expect(state.jobs[0].bibliography?.title == "A & B")
        state.importBibliography([BibliographyMatch(record: found.record, pdf: nil, warning: PaperLookup.needsPDF)])
        #expect(state.jobs.count == 1)
        #expect(PaperLookup.isPDF(Data("%PDF-1.4".utf8)))
        #expect(!PaperLookup.isPDF(Data("<html>login</html>".utf8)))
        #expect(PaperLookup.attachIndex(in: [BibliographyMatch(record: found.record, pdf: nil, warning: PaperLookup.needsPDF)]) == 0)
        let library = [
            BibliographyMatch(record: found.record, pdf: pdf, warning: nil),
            BibliographyMatch(record: found.record, pdf: nil, warning: PaperLookup.needsPDF),
        ]
        #expect(PaperLookup.attachIndex(in: library) == nil)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @MainActor
    @Test func rendersTheImportScreen() throws {
        let matched = BibliographyMatch(
            record: BibliographicMetadata(
                citeKey: "lovelace2020",
                title: "Analytical Engine",
                authors: ["Ada Lovelace"],
                year: 2020,
                doi: "10.1000/xyz",
                venue: "Nature",
                abstract: nil,
                source: "bibtex",
                pdfPath: "/tmp/10.1000_xyz.pdf"
            ),
            pdf: URL(fileURLWithPath: "/tmp/10.1000_xyz.pdf"),
            warning: nil
        )
        let missing = BibliographyMatch(
            record: BibliographicMetadata(
                citeKey: "missing1900",
                title: "Untitled notes",
                authors: [],
                year: nil,
                doi: nil,
                venue: nil,
                abstract: nil,
                source: "zotero",
                pdfPath: nil
            ),
            pdf: nil,
            warning: "No PDF for missing1900"
        )
        let data = try BibliographyRenderer.png(matches: [matched, missing])
        #expect(data.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-bibliography-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("bibliography-import.png"))
        let doi = BibliographyMatch(
            record: BibliographicMetadata(
                citeKey: "10.1000/xyz",
                title: "Confirmed",
                authors: ["Ada Lovelace"],
                year: 2021,
                doi: "10.1000/xyz",
                venue: "Real Journal",
                abstract: nil,
                source: "crossref",
                pdfPath: nil
            ),
            pdf: nil,
            warning: PaperLookup.needsPDF
        )
        let lookup = try BibliographyRenderer.png(
            matches: [doi],
            status: PaperLookup.needsPDF,
            lookupText: "https://doi.org/10.1000/xyz"
        )
        try lookup.write(to: directory.appendingPathComponent("doi-arxiv-import.png"))
    }
}

@MainActor
private enum BibliographyRenderer {
    static func png(
        matches: [BibliographyMatch],
        status: String = "Zotero key is stored in the Keychain.",
        lookupText: String = ""
    ) throws -> Data {
        let size = NSSize(width: 640, height: 420)
        let view = BibliographyImportScreen(matches: matches, status: status, lookupText: lookupText)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]), data.count > 1000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
}
