import AppKit
import SwiftUI
import Testing
@testable import Chunky

@MainActor
struct InterfaceModeScreenshotTests {
    @Test func preferencesAndSidebarRenderBothModesWithoutChangingConfiguration() throws {
        let appState = AppState()
        let settings = IsolatedSettings.make()
        appState.settings = settings
        settings.embeddingBackend = "openai"
        settings.embeddingModel = "example-embedding"
        settings.embeddingDimensions = 768
        settings.embeddingAPIURL = "https://example.invalid/v1/embeddings"
        settings.maxTokensPerChunk = 512
        settings.chunkOverlap = 64
        settings.qdrantAPIKey = "fixture-key"
        settings.workerToken = "fixture-token"
        settings.doclingModel = DoclingModel.standard.rawValue
        appState.viewMode = .benchmark

        for dark in [false, true] {
            let view = PreferencesView(initialTab: 1, automaticallyCheckConnections: false)
                .environmentObject(appState)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = makeWindow(host: host, width: 540, height: 760, dark: dark)
            defer { window.orderOut(nil) }
            for mode in InterfaceMode.allCases {
                settings.interfaceMode = mode
                try capture(host: host, window: window, name: "preferences-\(mode.rawValue)-\(dark ? "dark" : "light")")
                let sidebar = SidebarView()
                    .environmentObject(appState)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let sidebarHost = NSHostingView(rootView: sidebar)
                let sidebarWindow = makeWindow(host: sidebarHost, width: 280, height: 700, dark: dark)
                defer { sidebarWindow.orderOut(nil) }
                try capture(host: sidebarHost, window: sidebarWindow, name: "sidebar-\(mode.rawValue)-\(dark ? "dark" : "light")")
                #expect(settings.embeddingModel == "example-embedding")
                #expect(settings.embeddingDimensions == 768)
                #expect(settings.embeddingAPIURL == "https://example.invalid/v1/embeddings")
                #expect(settings.maxTokensPerChunk == 512)
                #expect(settings.chunkOverlap == 64)
                #expect(settings.qdrantAPIKey == "fixture-key")
                #expect(settings.workerToken == "fixture-token")
                #expect(appState.viewMode == .benchmark)
            }
        }
    }

    private func makeWindow<V: View>(host: NSHostingView<V>, width: CGFloat, height: CGFloat, dark: Bool) -> NSWindow {
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }

    private func capture<V: View>(host: NSHostingView<V>, window: NSWindow, name: String) throws {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-interface-\(name).png"))
    }
}
