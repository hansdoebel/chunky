import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import Chunky

@MainActor
struct LocalQdrantRuntimeTests {
    @Test func inheritedRemoteOverridesAreRemoved() {
        let clean = LocalQdrantRuntime.cleanEnvironment(["HOME": "/home/test", "DOCKER_HOST": "tcp://remote", "DOCKER_CONTEXT": "prod", "DOCKER_CONFIG": "/other", "COLIMA_HOME": "/other", "LIMA_HOME": "/other", "PATH": "/custom"])
        #expect(clean["HOME"] == "/home/test")
        #expect(clean["DOCKER_HOST"] == nil)
        #expect(clean["DOCKER_CONFIG"] == nil)
        #expect(clean["DOCKER_CONTEXT"] == nil)
        #expect(clean["COLIMA_HOME"] == nil)
        #expect(clean["LIMA_HOME"] == nil)
        #expect(clean["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    @Test func newProfileCreatesOnlyLabeledPersistentLoopbackResources() async throws {
        let fixture = try RuntimeFixture(owned: false, outputs: ["", "started", "", "", "volume", "[{\"Driver\":\"local\",\"Labels\":{\"io.chunky.managed\":\"qdrant-v1\"},\"Options\":null}]", "container"])
        defer { fixture.cleanup() }
        try await fixture.runtime.start()
        #expect(fixture.runtime.ownsProfile)
        let calls = await fixture.script.calls
        #expect(calls[1].arguments == ["start", "--profile", "chunky", "--activate=false", "--runtime", "docker", "--cpu", "2", "--memory", "4", "--disk", "30"])
        let dockerCalls = calls.filter { $0.executable == "/fixture/docker" }
        #expect(dockerCalls.allSatisfy { $0.arguments.prefix(2) == ["--host", fixture.runtime.socket] })
        #expect(dockerCalls.allSatisfy { $0.environment["DOCKER_HOST"] == nil })
        let create = try #require(calls.last)
        #expect(create.arguments.contains("127.0.0.1:6333:6333"))
        #expect(create.arguments.contains("127.0.0.1:6334:6334"))
        #expect(create.arguments.contains("type=volume,source=chunky-qdrant-data,target=/qdrant/storage"))
        #expect(create.arguments.contains("io.chunky.managed=qdrant-v1"))
        #expect(create.arguments.last == "qdrant/qdrant:v1.20.2")
        #expect(!calls.flatMap(\.arguments).contains("rm"))
    }

    @Test func existingProfileRetainsResourceConfigurationOnRestart() async throws {
        let fixture = try RuntimeFixture(owned: true, outputs: ["{\"name\":\"chunky\",\"status\":\"Stopped\",\"runtime\":\"docker\"}", "started", "chunky-qdrant", String(decoding: Self.containerData(), as: UTF8.self), "chunky-qdrant-data", "[{\"Driver\":\"local\",\"Labels\":{\"io.chunky.managed\":\"qdrant-v1\"},\"Options\":null}]"])
        defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let calls = await fixture.script.calls
        #expect(calls[1].arguments == ["start", "--profile", "chunky", "--activate=false"])
        #expect(calls.count == 6)
    }

    @Test func stoppedOwnedContainerReusesVolumeWithoutCreation() async throws {
        let stopped = String(decoding: try Self.containerData(), as: UTF8.self).replacingOccurrences(of: "\"Running\":true", with: "\"Running\":false")
        let fixture = try RuntimeFixture(owned: true, outputs: [Self.runningProfile, "chunky-qdrant", stopped, "chunky-qdrant-data", "[{\"Driver\":\"local\",\"Labels\":{\"io.chunky.managed\":\"qdrant-v1\"},\"Options\":null}]", "started"])
        defer { fixture.cleanup() }
        try await fixture.runtime.start()
        let calls = await fixture.script.calls
        #expect(calls.count == 6)
        #expect(calls.last?.arguments == ["--host", fixture.runtime.socket, "container", "start", "chunky-qdrant"])
        #expect(!calls.flatMap(\.arguments).contains("create"))
        #expect(!calls.flatMap(\.arguments).contains("run"))
    }

    @Test func restartRefusesAnUnexpectedStorageVolume() async throws {
        let fixture = try RuntimeFixture(owned: true, outputs: [Self.runningProfile, "chunky-qdrant", String(decoding: Self.containerData(), as: UTF8.self), "chunky-qdrant-data", "[{\"Driver\":\"local\",\"Labels\":{},\"Options\":null}]"])
        defer { fixture.cleanup() }
        await #expect(throws: LocalRuntimeError.self) { try await fixture.runtime.start() }
        #expect(await fixture.script.calls.count == 5)
    }

    @Test func failedCommandRetainsTheFinalDiagnosticAfterLargeProgressOutput() async throws {
        let command = RuntimeCommand(executable: "/bin/sh", arguments: ["-c", "printf '%1100000d' 0; printf '\\nport-already-in-use\\n'; exit 7"], environment: [:], timeout: 5)
        let result = try await LocalRuntimeProcess.run(command)
        #expect(result.status == 7)
        #expect(result.output.hasSuffix("port-already-in-use\n"))
        #expect(result.output.utf8.count <= 1_048_576)
        let tail = LocalQdrantRuntime.diagnosticTail(result.output + " https://user:password@registry.example failed fixture-token", environment: ["HF_TOKEN": "fixture-token"])
        #expect(tail.contains("port-already-in-use"))
        #expect(tail.count <= 2000)
        #expect(!tail.contains("user:password"))
        #expect(!tail.contains("fixture-token"))
    }

    @Test func existingUnownedProfileIsNeverAdopted() async throws {
        let fixture = try RuntimeFixture(owned: false, outputs: [Self.runningProfile])
        defer { fixture.cleanup() }
        await #expect(throws: LocalRuntimeError.self) { try await fixture.runtime.start() }
        #expect(!fixture.runtime.ownsProfile)
        #expect(await fixture.script.calls.count == 1)
    }

    @Test func probeFailureDoesNotCreateAnything() async throws {
        let fixture = try RuntimeFixture(owned: false, outputs: [], failure: true)
        defer { fixture.cleanup() }
        await #expect(throws: LocalRuntimeError.self) { try await fixture.runtime.start() }
        #expect(!fixture.runtime.ownsProfile)
        #expect(await fixture.script.calls.count == 1)
    }

    @Test func unexpectedContainerConfigurationFailsClosed() throws {
        let safe = try Self.containerData()
        #expect(try LocalQdrantRuntime.validateContainer(safe))
        for field in ["label", "port", "image", "mount", "privileged"] {
            #expect(throws: LocalRuntimeError.self) { try LocalQdrantRuntime.validateContainer(Self.containerData(unsafe: field)) }
        }
    }

    @Test func stopVMRefusesUnrelatedContainers() async throws {
        let fixture = try RuntimeFixture(owned: true, outputs: [Self.runningProfile, "other-container", "other-container"])
        defer { fixture.cleanup() }
        await #expect(throws: LocalRuntimeError.self) { try await fixture.runtime.stopProfile() }
        #expect(await fixture.script.calls.count == 3)
        #expect(await fixture.script.calls.allSatisfy { !$0.arguments.contains("stop") })
    }

    @Test func stopOnlyTargetsValidatedOwnedContainer() async throws {
        let fixture = try RuntimeFixture(owned: true, outputs: [Self.runningProfile, "chunky-qdrant", String(decoding: Self.containerData(), as: UTF8.self), "stopped"])
        defer { fixture.cleanup() }
        try await fixture.runtime.stopContainer()
        let last = try #require(await fixture.script.calls.last)
        #expect(last.arguments == ["--host", fixture.runtime.socket, "container", "stop", "--time", "30", "chunky-qdrant"])
    }

    @Test func existingUnownedVolumeIsNeverUsed() async throws {
        let fixture = try RuntimeFixture(owned: true, outputs: [Self.runningProfile, "", "chunky-qdrant-data", "[{\"Driver\":\"local\",\"Labels\":{},\"Options\":null}]"])
        defer { fixture.cleanup() }
        await #expect(throws: LocalRuntimeError.self) { try await fixture.runtime.start() }
        #expect(await fixture.script.calls.count == 4)
    }

    @Test func cancelledStartDoesNotMutateResources() async throws {
        let fixture = try RuntimeFixture(owned: false, outputs: [])
        defer { fixture.cleanup() }
        let task = Task { try await fixture.runtime.start() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.script.calls.isEmpty)
        #expect(!fixture.runtime.ownsProfile)
    }

    @Test @concurrent nonisolated func processCancellationTerminatesAndReapsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let command = Self.sleepCommand(pidFile: pidFile, timeout: 10)
        let task = Task { try await LocalRuntimeProcess.run(command) }
        do {
            let pid = try await Self.waitForPID(at: pidFile)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(kill(pid, 0) == -1)
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }

    @Test @concurrent nonisolated func processReadinessWaitsForCompletePID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        try "12".write(to: pidFile, atomically: true, encoding: .utf8)
        let writer = Task {
            try await Task.sleep(for: .milliseconds(100))
            try "12345\n".write(to: pidFile, atomically: true, encoding: .utf8)
        }
        defer { writer.cancel() }
        #expect(try await Self.waitForPID(at: pidFile) == 12345)
        try await writer.value
    }

    @Test @concurrent nonisolated func processReadinessHasABoundedFailure() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: LocalRuntimeError.self) {
            try await Self.waitForPID(at: missing, timeout: .milliseconds(50))
        }
    }

    @concurrent private nonisolated static func waitForPID(at file: URL, timeout: Duration = .seconds(3)) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               contents.hasSuffix("\n"),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        throw LocalRuntimeError.unavailable("Test child did not publish a complete PID before the readiness deadline")
    }

    @Test @concurrent nonisolated func processTimeoutTerminatesAndReapsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        await #expect(throws: LocalRuntimeError.self) {
            try await LocalRuntimeProcess.run(Self.sleepCommand(pidFile: pidFile, timeout: 0.5))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    private nonisolated static func sleepCommand(pidFile: URL, timeout: TimeInterval) -> RuntimeCommand {
        RuntimeCommand(executable: "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", pidFile.path], environment: [:], timeout: timeout)
    }

    private static let runningProfile = "{\"name\":\"chunky\",\"status\":\"Running\",\"runtime\":\"docker\"}"

    private static func containerData(unsafe: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "Config": ["Image": unsafe == "image" ? "qdrant/qdrant:latest" : LocalQdrantRuntime.image,
                       "Labels": [LocalQdrantRuntime.ownerKey: unsafe == "label" ? "other" : LocalQdrantRuntime.ownerValue]],
            "HostConfig": ["Privileged": unsafe == "privileged", "NetworkMode": "bridge", "PortBindings": [
                "6333/tcp": [["HostIp": unsafe == "port" ? "0.0.0.0" : "127.0.0.1", "HostPort": "6333"]],
                "6334/tcp": [["HostIp": "127.0.0.1", "HostPort": "6334"]]]],
            "Mounts": [["Type": "volume", "Name": unsafe == "mount" ? "other" : LocalQdrantRuntime.volume, "Destination": "/qdrant/storage", "RW": true]],
            "State": ["Running": true]
        ]])
    }
}

private actor RuntimeScript {
    var calls: [RuntimeCommand] = []
    var outputs: [String]
    let failure: Bool
    init(outputs: [String], failure: Bool) { self.outputs = outputs; self.failure = failure }
    func run(_ command: RuntimeCommand) throws -> RuntimeCommandResult {
        calls.append(command)
        if failure { return RuntimeCommandResult(status: 1, output: "fixture command failure") }
        guard !outputs.isEmpty else { throw LocalRuntimeError.unavailable("Unexpected command in test") }
        return RuntimeCommandResult(status: 0, output: outputs.removeFirst())
    }
}

@MainActor
private struct RuntimeFixture {
    let directory: URL
    let script: RuntimeScript
    let runtime: LocalQdrantRuntime
    init(owned: Bool, outputs: [String], failure: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("marker")
        if owned { try "chunky-v1\n".write(to: marker, atomically: true, encoding: .utf8) }
        let script = RuntimeScript(outputs: outputs, failure: failure)
        self.script = script
        runtime = LocalQdrantRuntime(home: directory, marker: marker, colima: "/fixture/colima", docker: "/fixture/docker", environment: ["DOCKER_HOST": "tcp://production"], run: { try await script.run($0) })
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
