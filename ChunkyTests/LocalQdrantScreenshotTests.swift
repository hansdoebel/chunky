import AppKit
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct LocalQdrantScreenshotTests {
    @Test func localRuntimeControlsRenderInBothThemes() throws {
        for dark in [false, true] {
            let view = LocalQdrantControls(snapshot: LocalQdrantSnapshot(profile: "Running", container: "Running", running: true), busy: false, message: "", refresh: {}, start: {}, stop: {}, stopProfile: {})
                .padding(24).frame(width: 560, height: 360, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var low: CGFloat = 1
            var high: CGFloat = 0
            var contrastPixels = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    low = min(low, brightness)
                    high = max(high, brightness)
                    if dark ? brightness > 0.6 : brightness < 0.4 { contrastPixels += 1 }
                }
            }
            #expect(high - low > 0.4)
            #expect(contrastPixels > 100)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            #expect(data.count > 2000)
            try data.write(to: URL(fileURLWithPath: "/tmp/chunky-colima-\(dark ? "dark" : "light").png"))
        }
    }
}
