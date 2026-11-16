import AppKit
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct LocalFallbackScreenshotTests {
    @Test func rendersPreferenceAndPersistentQueueNotice() throws {
        let job = ProcessingJob(url: URL(fileURLWithPath: "/tmp/fallback-paper.pdf"))
        job.status = .embedding
        job.statusMessage = "Generating embeddings..."
        job.localFallbackNotice = "Worker unreachable. Running on Local Mac with granite-docling-mlx, local Ollama and local Qdrant."
        let view = VStack(alignment: .leading, spacing: 24) {
            Text("Document processing").font(.title2)
            LocalFallbackSettingsPane(enabled: .constant(true))
            Divider()
            Text("Queue").font(.title2)
            FileRowView(job: job, onRemove: {})
        }
        .padding(24)
        .frame(width: 760, height: 350, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        let data = try LocalFallbackRenderer.png(view)
        #expect(!LocalFallbackRenderer.isMostlyBlank(data))
        try data.write(to: URL(fileURLWithPath: "/tmp/chunky-local-fallback.png"))
    }
}

@MainActor
private enum LocalFallbackRenderer {
    static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func png<V: View>(_ view: V) throws -> Data {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 350)
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), !isMostlyBlank(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    static func isMostlyBlank(_ data: Data) -> Bool {
        guard data.count > 1000, data.prefix(8) == pngMagic, let rep = NSBitmapImageRep(data: data),
              rep.pixelsWide > 10, rep.pixelsHigh > 10 else { return true }
        var darkPixels = 0
        var lowest: CGFloat = 1
        var highest: CGFloat = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 60, 1)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 80, 1)) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let light = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                lowest = min(lowest, light)
                highest = max(highest, light)
                if light < 0.5 { darkPixels += 1 }
            }
        }
        return darkPixels < 12 || highest - lowest < 0.3
    }
}
