import AppKit
import SwiftUI

@main
struct ChunkyApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
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

        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
    }
}
