import AppKit
import SwiftUI

@main
enum ChunkyMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            ChunkyMCPMain.run()
            return
        }
        ChunkyApp.main()
    }
}

struct ChunkyApp: App {
    @StateObject private var appState: AppState
    @StateObject private var appearanceController: AppAppearanceController

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _appearanceController = StateObject(wrappedValue: AppAppearanceController(settings: state.settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear { _ = appearanceController }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.piSession.terminate()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(appState.sidebarVisibility == .all ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation {
                        appState.sidebarVisibility = appState.sidebarVisibility == .all ? .detailOnly : .all
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        Window("Datasets", id: "datasets") {
            DatasetLibraryView()
                .onAppear { _ = appearanceController }
        }
        .defaultSize(width: 820, height: 760)

        Window("Dataset Cloud Ingest", id: "dataset-cloud-ingest") {
            DatasetCloudIngestView().environmentObject(appState)
                .onAppear { _ = appearanceController }
        }
        .defaultSize(width: 780, height: 900)

        Settings {
            PreferencesView()
                .environmentObject(appState)
                .onAppear { _ = appearanceController }
        }
    }
}
