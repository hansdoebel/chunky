import AppKit
import CoreGraphics
import PDFKit
import SwiftUI
import Testing

@testable import Chunky

struct CitationPDFTests {
    @Test func resolvesTheOriginalPDFAndReportsAMissingFile() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pdf = folder.appendingPathComponent("paper.pdf")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pdf.path, contents: Data("%PDF".utf8))
        let known = [pdf]
        let found = CitationPDF.resolve(path: pdf.path, source: "paper.pdf", known: known)
        #expect(found == pdf)
        let byName = CitationPDF.resolve(path: "/missing/paper.pdf", source: "paper.pdf", known: known)
        #expect(byName == pdf)
        let missing = CitationPDF.resolve(path: "/missing/other.pdf", source: "other.pdf", known: known)
        #expect(missing == nil)
        let highlight = CitationPDF.highlight(
            hit: RetrievalHit(
                id: "c1",
                score: 0.9,
                text: "Revenue grew.",
                source: "other.pdf",
                page: 2,
                headings: [],
                payload: ["source_path": "/missing/other.pdf", "printed_page": "p. 12"]
            ),
            known: known
        )
        #expect(highlight.pdfURL == nil)
        #expect(highlight.message == CitationPDF.missingFile)
        #expect(highlight.chrome == "p. 12")
        #expect(highlight.page == 2)
    }

    @Test func mapsDoclingBoxesIntoPDFSpaceAndTheSharedView() {
        let page = CGRect(x: 10, y: 20, width: 612, height: 792)
        let bottom = VerificationBBox(l: 72, t: 700, r: 400, b: 640, origin: "bottom_left")
        let top = VerificationBBox(l: 72, t: 92, r: 400, b: 152, origin: "top_left")
        let bottomPDF = CitationPDF.pdfRect(bottom, pageHeight: 792)
        let topPDF = CitationPDF.pdfRect(top, pageHeight: 792)
        #expect(abs(bottomPDF.minX - 72) < 0.1)
        #expect(abs(bottomPDF.minY - 640) < 0.1)
        #expect(abs(bottomPDF.width - 328) < 0.1)
        #expect(abs(bottomPDF.height - 60) < 0.1)
        #expect(abs(topPDF.minY - bottomPDF.minY) < 0.1)
        #expect(abs(topPDF.height - bottomPDF.height) < 0.1)
        let view = CitationPDF.viewRect(top, pageWidth: 612, pageHeight: 792, in: page)
        let shared = bottom.rect(pageWidth: 612, pageHeight: 792, in: page)
        #expect(abs(view.minX - shared.minX) < 0.1)
        #expect(abs(view.minY - shared.minY) < 0.1)
        #expect(abs(view.width - shared.width) < 0.1)
        #expect(abs(view.height - shared.height) < 0.1)
        let json = #"[{"page":2,"l":72,"t":700,"r":400,"b":640,"coord_origin":"BOTTOMLEFT"},{"page":3,"l":0,"t":1,"r":2,"b":0}]"#
        let boxes = CitationPDF.boxes(json: json, page: 2)
        #expect(boxes.count == 1)
        #expect(boxes[0].origin == "bottom_left")
        #expect(CitationPDF.boxes(json: json, page: 2)[0].l == 72)
    }

    @Test func aHitAndACitationOpenTheSameHighlightedPage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pdf = folder.appendingPathComponent("paper.pdf")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pdf.path, contents: Data("%PDF".utf8))
        let boxes = #"[{"page":2,"l":72,"t":700,"r":400,"b":640},{"page":3,"l":1,"t":2,"r":3,"b":0}]"#
        let hit = RetrievalHit(
            id: "c1",
            score: 0.8,
            text: "Revenue grew.",
            source: "renamed.pdf",
            page: 2,
            headings: [],
            payload: [
                "source_path": pdf.path,
                "bboxes": boxes,
                "page_labels": "12",
                "doc_title": "Paper",
            ],
            docTitle: "Paper"
        )
        let opened = CitationPDF.highlight(hit: hit, known: [])
        #expect(opened.pdfURL == pdf)
        #expect(opened.boxes.count == 1)
        #expect(opened.chrome == "p. 12")
        #expect(opened.message == nil)
        let citation = RAGCitation(
            id: "c1",
            marker: "[1]",
            source: "renamed.pdf",
            docTitle: "Paper",
            page: 2,
            printedPage: nil,
            score: 0.8
        )
        let fromCitation = CitationPDF.highlight(citation: citation, hit: hit, known: [])
        #expect(fromCitation.pdfURL == opened.pdfURL)
        #expect(fromCitation.page == opened.page)
        #expect(fromCitation.boxes == opened.boxes)
        let raw: [String: Any] = [
            "id": "c1",
            "score": 0.4,
            "payload": [
                "text": "Revenue grew.",
                "source": "paper.pdf",
                "page": 2,
                "bboxes": [["page": 2, "l": 72, "t": 700, "r": 400, "b": 640]],
                "page_labels": ["12"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let row = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = RetrievalHit(workerRow: row)
        #expect(decoded.payload["bboxes"]?.contains("\"l\"") == true)
        #expect(CitationPDF.boxes(json: decoded.payload["bboxes"], page: 2).count == 1)
        #expect(decoded.payload["page_labels"] == "12")
    }

    @MainActor
    @Test func storesTheLocalPathOnTheChunk() {
        let settings = IsolatedSettings.make()
        settings.enableEmbeddingCache = false
        let chunk = ChunkingService.DocumentChunk(text: "Hello", source: "paper.pdf", page: 2)
        let processor = DocumentProcessor()
        let point = processor.buildPoints(
            chunks: [chunk],
            embeddings: [[0.1, 0.2]],
            sparseVectors: [nil],
            settings: settings,
            ingestedAt: "2026-11-15T00:00:00Z",
            sourcePath: "/Users/me/paper.pdf"
        )[0]
        #expect(point.metadata["source_path"] == "/Users/me/paper.pdf")
        #expect(point.source == "paper.pdf")
    }

    @MainActor
    @Test func rendersTheHighlightedPage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("paper.pdf")
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        NSColor.black.setFill()
        NSRect(x: 72, y: 640, width: 328, height: 60).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)
        #expect(document.write(to: pdf))
        #expect(PDFPageRenderer.render(url: pdf, page: 1) != nil)
        let highlight = CitationHighlight(
            id: "c1",
            title: "Paper",
            page: 1,
            chrome: "p. 12",
            boxes: [VerificationBBox(l: 72, t: 700, r: 400, b: 640, origin: "bottom_left")],
            pdfURL: pdf,
            message: nil
        )
        let data = try CitationPDFRenderer.png(highlight: highlight)
        #expect(data.count > 1000)
        let directory = URL(fileURLWithPath: "/tmp/chunky-citation-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("citation-pdf.png"))
    }
}

@MainActor
private enum CitationPDFRenderer {
    static func png(highlight: CitationHighlight) throws -> Data {
        let size = NSSize(width: 520, height: 640)
        let view = CitationPDFScreen(highlight: highlight, pageImage: { _ in
            (CitationPDFRenderer.pageImage(), VerificationReport.PageSize(width: 612, height: 792))
        })
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

    static func pageImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        NSColor.darkGray.setFill()
        NSRect(x: 72, y: 640, width: 328, height: 60).fill()
        image.unlockFocus()
        return image
    }
}
