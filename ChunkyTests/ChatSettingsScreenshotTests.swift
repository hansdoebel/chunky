import AppKit
import SwiftUI
import Testing

@testable import Chunky

@MainActor
struct ChatSettingsScreenshotTests {

    @Test func rendersPiReadyAndInstallHint() throws {
        let ready = try ChatSettingsRenderer.png(
            report: .readyFixture,
            models: [
                PiModel(modelId: "qwen3", name: "Qwen3", provider: "ollama", contextWindow: 32768)
            ],
            backend: ChatBackendPreference.automatic.rawValue
        )
        let missing = try ChatSettingsRenderer.png(
            report: .notInstalled,
            models: [],
            backend: ChatBackendPreference.automatic.rawValue
        )
        #expect(ready.count > 1000)
        #expect(missing.count > 1000)
        #expect(ready.prefix(8) == ChatSettingsRenderer.pngMagic)
        #expect(missing.prefix(8) == ChatSettingsRenderer.pngMagic)
        let directory = URL(fileURLWithPath: "/tmp/chunky-chat-settings-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ready.write(to: directory.appendingPathComponent("chat-settings-pi-ready.png"))
        try missing.write(to: directory.appendingPathComponent("chat-settings-install-hint.png"))
    }
}

@MainActor
private enum ChatSettingsRenderer {
    static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func png(report: PiInstallReport, models: [PiModel], backend: String) throws -> Data {
        let view = ChatSettingsSnapshot(report: report, models: models, backend: backend)
            .frame(width: 500, height: 860, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 500, height: 860)
        if let image = renderer.nsImage, let data = pngData(from: image), data.count > 1000 {
            return data
        }
        return try hostedPNG(view)
    }

    private static func hostedPNG<V: View>(_ view: V) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 860)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileReadUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), data.count > 1000 else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct ChatSettingsSnapshot: View {
    var report: PiInstallReport
    var models: [PiModel]
    var backend: String
    @State private var backendValue: String
    @State private var piPath: String
    @State private var chatAPIURL: String
    @State private var piModel: String
    @State private var chatModel: String
    @State private var apiKey: String

    init(report: PiInstallReport, models: [PiModel], backend: String) {
        self.report = report
        self.models = models
        self.backend = backend
        _backendValue = State(initialValue: backend)
        _piPath = State(initialValue: "")
        _chatAPIURL = State(initialValue: "http://127.0.0.1:11434/v1")
        _piModel = State(initialValue: models.first?.modelIdentifier ?? "")
        _chatModel = State(initialValue: "qwen3")
        _apiKey = State(initialValue: "")
    }

    var body: some View {
        ChatSettingsPane(
            backend: $backendValue,
            piPath: $piPath,
            chatAPIURL: $chatAPIURL,
            piModel: $piModel,
            chatModel: $chatModel,
            apiKey: $apiKey,
            report: report,
            models: models,
            statusMessage: "",
            onCheck: {},
            onListModels: {}
        )
    }
}
