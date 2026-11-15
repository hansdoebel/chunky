import AppKit
import SwiftUI
import Testing

@testable import Chunky

struct WorkerEndpointTests {
    @Test @MainActor func profilesKeepTokensOutOfUserDefaults() throws {
        let settings = IsolatedSettings.make()
        settings.devboxWorkerURL = "http://192.0.2.10:8080"
        settings.workerToken = "existing-token"
        let endpoints = settings.workerEndpoints()
        #expect(endpoints[0].url == "http://192.0.2.10:8080")
        #expect(settings.workerEndpointToken(id: endpoints[0].id) == "existing-token")
        #expect(endpoints.map(\.name) == WorkerEndpoint.starterNames)
        let wifi = endpoints[1]
        var saved = endpoints
        saved[1].url = "https://worker.example.ts.net"
        settings.replaceWorkerEndpoints(saved)
        settings.setWorkerEndpointToken(id: wifi.id, "endpoint-secret")
        #expect(settings.devboxWorkerURL == "http://192.0.2.10:8080")
        #expect(settings.workerToken == "existing-token")
        settings.useWorkerEndpoint(saved[1])
        #expect(settings.devboxWorkerURL == "https://worker.example.ts.net")
        #expect(settings.workerToken == "endpoint-secret")
        #expect(settings.workerEndpointToken(id: wifi.id) == "endpoint-secret")
        let loaded = WorkerEndpointStore.load(defaults: settings.defaults)
        #expect(loaded.contains { $0.url == "https://worker.example.ts.net" })
        let text = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        #expect(!text.contains("endpoint-secret"))
        #expect(!text.contains("existing-token"))
        #expect(WorkerProbe.accepts(url: "https://worker.example.ts.net"))
        #expect(!WorkerProbe.accepts(url: "ftp://worker"))
    }

    @Test func probeClassifiesReachabilityAndLatency() {
        let connected = WorkerProbe.classify(
            url: "https://worker.example.ts.net",
            healthStatus: 200,
            healthFailedSecure: false,
            healthUnreachable: false,
            modelsStatus: 200,
            modelsFailedSecure: false,
            modelsUnreachable: false,
            elapsed: 0.018
        )
        #expect(connected.kind == .connected)
        #expect(connected.latencyMs == 18)
        let denied = WorkerProbe.classify(
            url: "http://worker.local:8080",
            healthStatus: 200,
            healthFailedSecure: false,
            healthUnreachable: false,
            modelsStatus: 401,
            modelsFailedSecure: false,
            modelsUnreachable: false,
            elapsed: 0.04
        )
        #expect(denied.kind == .unauthorized)
        #expect(denied.latencyMs == 40)
        let blocked = WorkerProbe.classify(
            url: "http://worker.example.ts.net:8080",
            healthStatus: nil,
            healthFailedSecure: true,
            healthUnreachable: false,
            modelsStatus: nil,
            modelsFailedSecure: false,
            modelsUnreachable: false,
            elapsed: 0.01
        )
        #expect(blocked.kind == .appTransportSecurity)
        let down = WorkerProbe.classify(
            url: "http://192.0.2.10:8080",
            healthStatus: nil,
            healthFailedSecure: false,
            healthUnreachable: true,
            modelsStatus: nil,
            modelsFailedSecure: false,
            modelsUnreachable: false,
            elapsed: 1
        )
        #expect(down.kind == .unreachable)
        #expect(down.latencyMs == 1000)
        let bad = WorkerProbe.classify(
            url: "not a url",
            healthStatus: nil,
            healthFailedSecure: false,
            healthUnreachable: false,
            modelsStatus: nil,
            modelsFailedSecure: false,
            modelsUnreachable: false,
            elapsed: 0
        )
        #expect(bad.kind == .invalidURL)
        #expect(WorkerProbe.isCurrent(started: 2, url: "http://worker.local:8080", token: "a", generation: 2, currentURL: "http://worker.local:8080", currentToken: "a"))
        #expect(!WorkerProbe.isCurrent(started: 2, url: "http://worker.local:8080", token: "a", generation: 3, currentURL: "http://worker.local:8080", currentToken: "a"))
        #expect(!WorkerProbe.isCurrent(started: 2, url: "http://worker.local:8080", token: "a", generation: 2, currentURL: "https://worker.example.ts.net", currentToken: "a"))
    }

    @Test @MainActor func endpointPaneRendersAColoredScreenshot() throws {
        let endpoints = [
            WorkerEndpoint(id: UUID(), name: "Wired LAN", url: "http://192.0.2.10:8080"),
            WorkerEndpoint(id: UUID(), name: "Wi-Fi", url: "http://worker.local:8080"),
            WorkerEndpoint(id: UUID(), name: "Tailscale", url: "https://worker.example.ts.net"),
        ]
        let report = WorkerProbeReport(kind: .connected, latencyMs: 18, message: "Connected in 18 ms.")
        let view = WorkerEndpointsPane(
            endpoints: endpoints,
            selectedID: endpoints[1].id,
            activeID: endpoints[1].id,
            name: "Wi-Fi",
            url: "http://worker.local:8080",
            token: "secret",
            report: report,
            onSelect: { _ in },
            onName: { _ in },
            onURL: { _ in },
            onToken: { _ in },
            onSave: {},
            onUse: {},
            onCheck: {}
        )
        .frame(width: 520, height: 560, alignment: .top)
        let data = try WorkerEndpointRenderer.png(view)
        #expect(!WorkerEndpointRenderer.isMostlyBlank(data))
        try data.write(to: URL(fileURLWithPath: "/tmp/chunky-worker-endpoints.png"))
    }
}

@MainActor
private enum WorkerEndpointRenderer {
    static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func png<V: View>(_ view: V) throws -> Data {
        let size = NSSize(width: 520, height: 560)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    static func isMostlyBlank(_ data: Data) -> Bool {
        guard data.count > 1000, data.prefix(8) == pngMagic, let rep = NSBitmapImageRep(data: data) else {
            return true
        }
        var ink = 0
        let stepX = max(rep.pixelsWide / 40, 1)
        let stepY = max(rep.pixelsHigh / 40, 1)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if abs(color.redComponent - color.greenComponent) > 0.04
                    || abs(color.greenComponent - color.blueComponent) > 0.04
                    || color.redComponent < 0.9 {
                    ink += 1
                }
            }
        }
        return ink < 12
    }
}
