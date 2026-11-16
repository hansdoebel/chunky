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
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        var darkest = 1.0
        var lightest = 0.0
        var samples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let brightness = Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                darkest = min(darkest, brightness)
                lightest = max(lightest, brightness)
                samples += 1
            }
        }
        #expect(samples > 100)
        #expect(lightest - darkest > 0.2)
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-project-links.png"))
    }
}
