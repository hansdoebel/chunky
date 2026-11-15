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
    }
}

@MainActor
private enum BibliographyRenderer {
    static func png(matches: [BibliographyMatch]) throws -> Data {
        let size = NSSize(width: 640, height: 420)
        let view = BibliographyImportScreen(matches: matches, status: "Zotero key is stored in the Keychain.")
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
