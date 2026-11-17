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
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = makeWindow(host: host, width: 540, height: 760, dark: dark)
            defer { window.orderOut(nil) }
            let sidebar = SidebarView()
                .environmentObject(appState)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let sidebarHost = NSHostingView(rootView: sidebar)
            let sidebarWindow = makeWindow(host: sidebarHost, width: 280, height: 700, dark: dark)
            defer { sidebarWindow.orderOut(nil) }
            var preferenceContent: [Double]?
            var sidebarContent: [Double]?
            for mode in InterfaceMode.allCases {
                settings.interfaceMode = mode
                let newPreferenceContent = try capture(host: host, window: window, name: "preferences-\(mode.rawValue)-\(dark ? "dark" : "light")")
                let newSidebarContent = try capture(host: sidebarHost, window: sidebarWindow, name: "sidebar-\(mode.rawValue)-\(dark ? "dark" : "light")")
                if let preferenceContent { #expect(newPreferenceContent != preferenceContent) }
                if let sidebarContent { #expect(newSidebarContent != sidebarContent) }
                preferenceContent = newPreferenceContent
                sidebarContent = newSidebarContent
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
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func capture<V: View>(host: NSHostingView<V>, window: NSWindow, name: String) throws -> [Double] {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        var contentLuminance: [Double] = []
        var headerLightest = 0.0
        var headerDarkest = 1.0
        var interiorOpaque = true
        var lightest = 0.0
        var darkest = 1.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                if x > 20 && x < bitmap.pixelsWide - 20 && y > 20 && y < bitmap.pixelsHigh - 20 {
                    interiorOpaque = interiorOpaque && color.alphaComponent > 0.99
                    if y < bitmap.pixelsHigh / 4 {
                        headerLightest = max(headerLightest, luminance)
                        headerDarkest = min(headerDarkest, luminance)
                    }
                }
                lightest = max(lightest, luminance)
                darkest = min(darkest, luminance)
                if y > bitmap.pixelsHigh / 4 { contentLuminance.append(luminance) }
            }
        }
        #expect(png.count > 5000 && lightest - darkest > 0.2)
        #expect(interiorOpaque)
        #expect(headerLightest - headerDarkest > 0.2)
        try png.write(to: URL(fileURLWithPath: "/tmp/chunky-interface-\(name).png"))
        return contentLuminance
    }
}
