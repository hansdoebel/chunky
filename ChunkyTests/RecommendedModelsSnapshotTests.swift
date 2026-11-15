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
        .frame(width: 640, height: 360)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 640, height: 360)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count > 1000 else {
            throw SnapshotError(description: "ImageRenderer did not produce a Preferences screenshot")
        }
        try png.write(to: url)
    }
}
