import AppKit
import SwiftUI
import Testing
@testable import Chunky

@MainActor
struct DatasetBenchmarkScreenshotTests {
    @Test func datasetBenchmarkRendersNonblankLightAndDark() throws {
        for dark in [false, true] {
            let report = DatasetBenchmarkReport(createdAt: Date(timeIntervalSince1970: 0), datasetID: "fixture/corpus", revision: String(repeating: "a", count: 40), config: "corpus", split: "test", sha256: String(repeating: "b", count: 64), textField: "text", rows: 100, backend: "ollama", model: "fixture-model", dimensions: 3, warmupSeconds: 1, embeddingSeconds: 2, indexingSeconds: 0.5, collection: "chunky-dataset-test-fixture")
            let view = DatasetBenchmarkPanel(dataset: "fixture/corpus", revision: report.revision, availableRows: 100, fields: ["text", "title"], field: .constant("text"), rowLimit: .constant(100), seed: .constant(true), provider: "ollama", model: "fixture-model", target: "localhost:6334", running: false, status: "Rendering fixture only; these are not measured benchmark results.", report: report)
                .frame(width: 760, height: 980, alignment: .top)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 980)
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
            try png.write(to: URL(fileURLWithPath: "/tmp/chunky-dataset-benchmark-\(dark ? "dark" : "light").png"))
        }
    }
}
