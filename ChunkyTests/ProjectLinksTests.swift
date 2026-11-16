import AppKit
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct ProjectLinksTests {
    @Test func repositoryLinkOpensChunky() {
        #expect(ProjectLinksPane.repositoryURL.absoluteString == "https://github.com/hansdoebel/chunky")
    }

    @Test func aboutLinksRenderNonblankScreenshot() throws {
        let view = VStack(alignment: .leading, spacing: 12) {
            ProjectLinksPane()
        }
        .padding(24)
        .frame(width: 420, height: 150, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .tint(.blue)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
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
        #expect(png.count > 1000)
        var darkest = 1.0
        var lightest = 0.0
        var samples = 0
        var bluePixels = 0
        var yellowPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let brightness = Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                darkest = min(darkest, brightness)
                lightest = max(lightest, brightness)
                samples += 1
                if color.blueComponent > color.redComponent + 0.15,
                   color.blueComponent > color.greenComponent + 0.05 {
                    bluePixels += 1
                }
                if color.redComponent > 0.8, color.greenComponent > 0.6, color.blueComponent < 0.2 {
                    yellowPixels += 1
                }
            }
        }
        #expect(samples > 100)
        #expect(lightest - darkest > 0.2)
        #expect(bluePixels > 20)
        #expect(yellowPixels == 0)
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-project-links.png"))
    }
}
