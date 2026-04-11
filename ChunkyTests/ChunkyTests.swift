import Foundation
import Testing

@testable import Chunky

// MARK: - AppState Tests

@MainActor
struct AppStateTests {

    // MARK: - Initialization Tests

    @Test func initialState() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        #expect(appState.jobs.isEmpty)
        #expect(appState.viewMode == .queue)
        #expect(appState.processingMode == .chunkOnly)
        #expect(appState.isProcessing == false)
        #expect(appState.isCancellationRequested == false)
    }

    // MARK: - Job Management Tests

    @Test func addFilesCreatesJobs() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        // Create a temporary file that actually exists
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile.path, contents: nil)

        defer { try? FileManager.default.removeItem(at: testFile) }

        appState.addFiles([testFile])

        #expect(appState.jobs.count == 1)
        #expect(appState.jobs.first?.fileName == testFile.lastPathComponent)
    }

    @Test func addFilesIgnoresUnreadableFiles() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()
        let nonExistentFile = URL(fileURLWithPath: "/nonexistent/path/file.pdf")

        appState.addFiles([nonExistentFile])

        #expect(appState.jobs.isEmpty)
    }

    @Test func addFilesPreventsPreventsDuplicates() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile.path, contents: nil)

        defer { try? FileManager.default.removeItem(at: testFile) }

        appState.addFiles([testFile])
        appState.addFiles([testFile])  // Try to add same file again

        #expect(appState.jobs.count == 1)  // Should still be 1
    }

    @Test func removeJobWorks() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile.path, contents: nil)

        defer { try? FileManager.default.removeItem(at: testFile) }

        appState.addFiles([testFile])
        #expect(appState.jobs.count == 1)

        let job = appState.jobs.first!
        appState.removeJob(job)

        #expect(appState.jobs.isEmpty)
    }

    @Test func clearAllRemovesAllJobs() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        let tempDir = FileManager.default.temporaryDirectory
        let testFile1 = tempDir.appendingPathComponent("test1_\(UUID().uuidString).pdf")
        let testFile2 = tempDir.appendingPathComponent("test2_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile1.path, contents: nil)
        FileManager.default.createFile(atPath: testFile2.path, contents: nil)

        defer {
            try? FileManager.default.removeItem(at: testFile1)
            try? FileManager.default.removeItem(at: testFile2)
        }

        appState.addFiles([testFile1, testFile2])
        #expect(appState.jobs.count == 2)

        appState.clearAll()
        #expect(appState.jobs.isEmpty)
    }

    @Test func clearCompletedOnlyRemovesCompletedJobs() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        let tempDir = FileManager.default.temporaryDirectory
        let testFile1 = tempDir.appendingPathComponent("test1_\(UUID().uuidString).pdf")
        let testFile2 = tempDir.appendingPathComponent("test2_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile1.path, contents: nil)
        FileManager.default.createFile(atPath: testFile2.path, contents: nil)

        defer {
            try? FileManager.default.removeItem(at: testFile1)
            try? FileManager.default.removeItem(at: testFile2)
        }

        appState.addFiles([testFile1, testFile2])

        // Mark first job as completed
        appState.jobs[0].status = .completed

        appState.clearCompleted()

        #expect(appState.jobs.count == 1)
        #expect(appState.jobs.first?.status == .pending)
    }

    // MARK: - Computed Properties Tests

    @Test func pendingJobsFiltersCorrectly() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        let tempDir = FileManager.default.temporaryDirectory
        let testFile1 = tempDir.appendingPathComponent("test1_\(UUID().uuidString).pdf")
        let testFile2 = tempDir.appendingPathComponent("test2_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile1.path, contents: nil)
        FileManager.default.createFile(atPath: testFile2.path, contents: nil)

        defer {
            try? FileManager.default.removeItem(at: testFile1)
            try? FileManager.default.removeItem(at: testFile2)
        }

        appState.addFiles([testFile1, testFile2])
        appState.jobs[0].status = .completed

        #expect(appState.pendingJobs.count == 1)
        #expect(appState.completedJobs.count == 1)
    }

    @Test func failedJobsFiltersCorrectly() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile.path, contents: nil)

        defer { try? FileManager.default.removeItem(at: testFile) }

        appState.addFiles([testFile])
        appState.jobs[0].status = .failed

        #expect(appState.failedJobs.count == 1)
        #expect(appState.pendingJobs.isEmpty)
    }

    @Test func hasJobsToProcessReflectsState() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        #expect(appState.hasJobsToProcess == false)

        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: testFile.path, contents: nil)

        defer { try? FileManager.default.removeItem(at: testFile) }

        appState.addFiles([testFile])
        #expect(appState.hasJobsToProcess == true)

        appState.jobs[0].status = .completed
        #expect(appState.hasJobsToProcess == false)
    }

    // MARK: - Cancellation Tests

    @Test func cancellationRequestWorks() {
        guard #available(macOS 15.0, *) else { return }
        let appState = AppState()

        #expect(appState.isCancellationRequested == false)

        appState.requestCancellation()
        #expect(appState.isCancellationRequested == true)

        appState.resetCancellation()
        #expect(appState.isCancellationRequested == false)
    }
}
