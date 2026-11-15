import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Chunky

private struct SnapshotError: Error, CustomStringConvertible {
    var description: String
}

@MainActor
struct RecommendedModelsSnapshotTests {
    @Test func rendersRecommendedModelLists() throws {
        let directory = URL(fileURLWithPath: "/tmp/chunky-ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(directory.appendingPathComponent("preferences-models-devbox.png"), host: .devbox, downloading: [])
        try write(
            directory.appendingPathComponent("preferences-models-downloading.png"),
            host: .devbox,
            downloading: ["ibm-granite/granite-docling-258M"]
        )
        try write(directory.appendingPathComponent("preferences-models-mac.png"), host: .localMac, downloading: [])
    }

    private func write(_ url: URL, host: ProcessingHost, downloading: Set<String>) throws {
        let view = Form {
            RecommendedModelsSection(
                host: host,
                downloading: downloading,
                statusMessage: "",
                onDownload: { _ in }
            )
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 380)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 380)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError(description: "Preferences view did not produce a bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              drawnPixels(in: rep) > 800 else {
            throw SnapshotError(description: "Preferences screenshot was blank")
        }
        try png.write(to: url)
        window.close()
    }

    private func drawnPixels(in rep: NSBitmapImageRep) -> Int {
        var drawn = 0
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let step = max(1, min(width, height) / 80)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let color = rep.colorAt(x: x, y: y) {
                    var red: CGFloat = 0
                    var green: CGFloat = 0
                    var blue: CGFloat = 0
                    var alpha: CGFloat = 0
                    color.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    if alpha > 0.2 && (red < 0.97 || green < 0.97 || blue < 0.97) {
                        drawn += 1
                    }
                }
                x += step
            }
            y += step
        }
        return drawn
    }
}
