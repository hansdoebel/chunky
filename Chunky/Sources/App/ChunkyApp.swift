import SwiftUI

@main
struct ChunkyApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showResumeAlert = false
    @State private var pendingResume: PersistedQueue?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onChange(of: appState.overallProgress) { _, newValue in
                    updateDockBadge(progress: newValue)
                }
                .onChange(of: appState.isProcessing) { _, newValue in
                    if !newValue {
                        clearDockBadge()
                    }
                }
                .onAppear {
                    checkForSavedState()
                    setupTerminationObserver()
                }
                .alert("Resume Previous Session?", isPresented: $showResumeAlert) {
                    Button("Resume") {
                        if let queue = pendingResume {
                            appState.restoreJobs(from: queue)
                        }
                        appState.clearState()
                    }
                    Button("Discard", role: .destructive) {
                        appState.clearState()
                    }
                } message: {
                    Text("Found \(pendingResume?.jobs.count ?? 0) pending job(s) from a previous session.")
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1000, height: 700)

        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
    }

    private func updateDockBadge(progress: Double) {
        guard appState.isProcessing else { return }
        let percentage = Int(progress * 100)
        NSApp.dockTile.badgeLabel = "\(percentage)%"
    }

    private func clearDockBadge() {
        NSApp.dockTile.badgeLabel = nil
    }

    private func checkForSavedState() {
        if let queue = appState.loadState(), !queue.jobs.isEmpty {
            pendingResume = queue
            showResumeAlert = true
        }
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                appState.saveState()
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
