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
        let size = NSSize(width: 520, height: 820)
        let view = ChatSettingsSnapshot(report: report, models: models, backend: backend)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let candidates = [windowPNG(view, size: size), pdfPNG(view, size: size), imageRendererPNG(view, size: size)]
        guard let data = candidates.compactMap({ $0 }).first(where: { !isMostlyBlank($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
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

    private static func pdfPNG<V: View>(_ view: V, size: NSSize) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let pdf = host.dataWithPDF(inside: host.bounds)
        guard let image = NSImage(data: pdf) else { return nil }
        return pngData(from: image)
    }

    private static func imageRendererPNG<V: View>(_ view: V, size: NSSize) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.isOpaque = true
        guard let image = renderer.nsImage else { return nil }
        return pngData(from: image)
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
