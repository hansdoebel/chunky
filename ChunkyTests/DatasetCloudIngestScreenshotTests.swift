import AppKit
import SwiftUI
import Testing
@testable import Chunky

@MainActor
struct DatasetCloudIngestScreenshotTests {
    @Test func cloudIngestRendersNonblankLightAndDark() throws {
        for (dark, preembedded) in [(false, false), (true, false), (false, true), (true, true)] {
            let estimate = DatasetCloudEstimate(points: 4200, payloadBytes: 12_000_000, dimensions: preembedded ? 1536 : 768)
            let view = DatasetCloudIngestPanel(dataset: preembedded ? "fixture/pre-embedded" : "fixture/wiki-de", rows: 1000, snapshotBytes: 10 * 1024 * 1024, target: "fixture.cloud.qdrant.io", provider: preembedded ? "openai" : "ollama", model: preembedded ? "text-embedding-3-small" : "fixture-model", field: .constant("text"), preembedded: .constant(preembedded), chunkBytes: .constant(2048), tier: .constant(.free), ramGB: .constant("0.7"), diskGB: .constant("3"), running: false, estimate: estimate, status: "Rendering fixture only; no Cloud import has run.", available: DatasetCloudBudget(tier: .free, ram: 700_000_000, disk: 3_000_000_000), onSave: nil)
                .frame(width: 760, height: 1230, alignment: .top)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 1230)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = appearance
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            var lightest = 0.0
            var darkest = 1.0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let luminance = Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                    lightest = max(lightest, luminance)
                    darkest = min(darkest, luminance)
                }
            }
            #expect(png.count > 5000 && lightest - darkest > 0.2)
            try png.write(to: URL(fileURLWithPath: "/tmp/chunky-dataset-cloud-ingest-\(preembedded ? "vectors" : "text")-\(dark ? "dark" : "light").png"))
        }
    }
}
