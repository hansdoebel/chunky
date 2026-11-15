import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import Chunky

struct VerificationTests {
    @Test func decodesAPartialReportAndMapsTheBox() throws {
        let report = try JSONDecoder().decode(VerificationReport.self, from: Data(Self.fixture.utf8))
        #expect(report.status == "yellow")
        #expect(report.pages.map(\.status) == ["green", "yellow", "red"])
        #expect(report.focusPage == 2)
        #expect(report.store.status == "green")
        #expect(report.spotChecks[0].preview == "Revenue grew in the first quarter.")
        let area = CGRect(x: 0, y: 0, width: 612, height: 792)
        let rect = report.spotChecks[0].bbox?.rect(pageWidth: 612, pageHeight: 792, in: area)
        #expect(rect != nil)
        #expect(abs((rect?.minX ?? 0) - 72) < 0.1)
        #expect(abs((rect?.minY ?? 0) - 92) < 0.1)
        #expect(abs((rect?.width ?? 0) - 328) < 0.1)
        #expect(abs((rect?.height ?? 0) - 60) < 0.1)
    }

    @Test func loggedSettingsAndErrorsDropSecrets() {
        let logged = VerificationPayload.logged(["qdrant_url": "https://cloud", "qdrant_api_key": "super-secret"])
        #expect(logged["qdrant_api_key"] == nil)
        #expect(logged["qdrant_url"] as? String == "https://cloud")
        let text = VerificationPayload.redact("rejected super-secret token abc", secrets: ["super-secret", "abc"])
        #expect(text == "rejected [redacted] token [redacted]")
        let chunk = ChunkingService.DocumentChunk(
            id: "c1",
            text: "Hello",
            source: "paper.pdf",
            page: 2,
            chunkIndex: 0,
            pageEnd: 3,
            bboxesJSON: "[{\"l\":1,\"t\":2,\"r\":3,\"b\":4}]"
        )
        let row = VerificationPayload.chunkRows([chunk])[0]
        #expect(row["id"] as? String == "c1")
        #expect(row["page_end"] as? Int == 3)
        #expect(row["bboxes"] != nil)
        #expect(row["text"] as? String == "Hello")
    }

    @MainActor
    @Test func rendersTheVerificationView() throws {
        let report = try JSONDecoder().decode(VerificationReport.self, from: Data(Self.fixture.utf8))
        let data = try VerificationRenderer.png(report: report)
        #expect(data.count > 1000)
        #expect(data.prefix(8) == VerificationRenderer.pngMagic)
        let directory = URL(fileURLWithPath: "/tmp/chunky-verification-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("verification.png"))
    }

    private static let fixture = """
    {
      "filename": "paper.pdf",
      "pdf_hash": "abc",
      "chunk_source": "job",
      "status": "yellow",
      "generated_at": "2026-11-15T00:00:00Z",
      "coverage_threshold": 0.9,
      "page_size": {"width": 612, "height": 792},
      "text": {"status": "yellow"},
      "pages": [
        {"page": 1, "status": "green", "coverage": 0.98, "flags": []},
        {"page": 2, "status": "yellow", "coverage": 0.74, "flags": ["coverage 74% is below 90%"]},
        {"page": 3, "status": "red", "coverage": 0.12, "flags": ["coverage 12% is below 90%"]}
      ],
      "attributions": [
        {"chunk_id": "c2", "page": 2, "page_end": 2, "similarity": 0.42, "matched": false, "suggested_page": 3}
      ],
      "store": {"status": "green"},
      "vector_spot_check": {"status": "green", "samples": [{"chunk_id": "c1", "cosine": 0.99, "status": "green"}]},
      "retrieval": {"status": "yellow"},
      "spot_checks": [
        {
          "chunk_id": "c2",
          "page": 2,
          "bbox": {"l": 72, "t": 700, "r": 400, "b": 640, "origin": "bottom_left"},
          "preview": "Revenue grew in the first quarter."
        }
      ]
    }
    """
}

@MainActor
private enum VerificationRenderer {
    static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func png(report: VerificationReport) throws -> Data {
        let size = NSSize(width: 900, height: 640)
        let view = VerificationScreen(
            documents: [VerificationDocument(id: "paper", filename: "paper.pdf", report: report, note: nil)],
            pageImage: { _, _ in pageImage() },
            onReverify: { _ in }
        )
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let candidates = [windowPNG(view, size: size), imageRendererPNG(view, size: size)]
        guard let data = candidates.compactMap({ $0 }).first(where: { !isMostlyBlank($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func pageImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        NSColor.darkGray.setFill()
        NSRect(x: 72, y: 700, width: 360, height: 14).fill()
        NSRect(x: 72, y: 660, width: 300, height: 10).fill()
        NSRect(x: 72, y: 630, width: 280, height: 10).fill()
        image.unlockFocus()
        return image
    }

    private static func windowPNG<V: View>(_ view: V, size: NSSize) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    private static func imageRendererPNG<V: View>(_ view: V, size: NSSize) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.isOpaque = true
        guard let image = renderer.nsImage else { return nil }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func isMostlyBlank(_ data: Data) -> Bool {
        guard data.count > 1000, data.prefix(8) == pngMagic, let rep = NSBitmapImageRep(data: data) else {
            return true
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 10, height > 10 else { return true }
        var ink = 0
        let stepX = max(width / 40, 1)
        let stepY = max(height / 40, 1)
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                if abs(red - green) > 0.04 || abs(green - blue) > 0.04 || red < 0.9 {
                    ink += 1
                }
            }
        }
        return ink < 12
    }
}
