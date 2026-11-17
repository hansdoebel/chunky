import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

nonisolated struct RuntimeCommand: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
}

nonisolated struct RuntimeCommandResult: Sendable {
    let status: Int32
    let output: String
}

nonisolated enum LocalRuntimeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

nonisolated enum LocalRuntimeState: Sendable, Equatable {
    case unknown, running, stopped, absent, unavailable

    init(_ status: String) {
        switch status.lowercased() {
        case "running": self = .running
        case "stopped", "vm stopped": self = .stopped
        case "not created": self = .absent
        case "unavailable": self = .unavailable
        default: self = .unknown
        }
    }
}

nonisolated struct LocalQdrantSnapshot: Sendable, Equatable {
    var profile = "Not checked"
    var container = "Not checked"
    var running = false
    var cpus: Int?
    var memoryBytes: Int64?
    var diskBytes: Int64?
    var configurationURL: URL?

    var profileState: LocalRuntimeState { LocalRuntimeState(profile) }
    var containerState: LocalRuntimeState { running ? .running : LocalRuntimeState(container) }
}

nonisolated final class LocalRuntimeProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(_ child: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try child.run()
            process = child
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func finish() {
        let child = lock.withLock { process }
        guard let child else { return }
        if child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(1)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
    }
}

nonisolated enum LocalRuntimeProcess {
    static func run(_ command: RuntimeCommand) async throws -> RuntimeCommandResult {
        let control = LocalRuntimeProcessControl()
        let worker = Task.detached { try runSynchronously(command, control: control) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            control.cancel()
            worker.cancel()
        }
    }

    private static func runSynchronously(_ command: RuntimeCommand, control: LocalRuntimeProcessControl) throws -> RuntimeCommandResult {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        defer { control.finish() }
        try control.start(process)
        let deadline = Date().addingTimeInterval(command.timeout)
        while process.isRunning && Date() < deadline {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        try Task.checkCancellation()
        guard !process.isRunning else {
            throw LocalRuntimeError.unavailable("The local runtime command timed out. Refresh status before retrying; Colima may still be starting.")
        }
        process.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let size = try reader.seekToEnd()
        try reader.seek(toOffset: process.terminationStatus != 0 && size > 1_048_576 ? size - 1_048_576 : 0)
        let bytes = try reader.read(upToCount: 1_048_576) ?? Data()
        return RuntimeCommandResult(status: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self))
    }
}

nonisolated struct LocalQdrantRuntime: Sendable {
    static let image = "qdrant/qdrant:v1.20.2"
    static let profile = "chunky"
    static let container = "chunky-qdrant"
    static let volume = "chunky-qdrant-data"
    static let ownerKey = "io.chunky.managed"
    static let ownerValue = "qdrant-v1"
    let home: URL
    let marker: URL
    let colima: String?
    let docker: String?
    let environment: [String: String]
    let run: @Sendable (RuntimeCommand) async throws -> RuntimeCommandResult

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         marker: URL? = nil,
         colima: String? = LocalQdrantRuntime.find("colima"),
         docker: String? = LocalQdrantRuntime.find("docker"),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         run: @escaping @Sendable (RuntimeCommand) async throws -> RuntimeCommandResult = { try await LocalRuntimeProcess.run($0) }) {
        self.home = home
        self.marker = marker ?? home.appendingPathComponent("Library/Application Support/Chunky/colima-profile-v1")
        self.colima = colima
        self.docker = docker
        self.environment = Self.cleanEnvironment(environment)
        self.run = run
    }

    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func cleanEnvironment(_ source: [String: String]) -> [String: String] {
        var result = source.filter { !$0.key.hasPrefix("DOCKER_") && !$0.key.hasPrefix("COLIMA_") && !$0.key.hasPrefix("LIMA_") }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (result["PATH"] ?? "")
        return result
    }

    static func diagnosticTail(_ output: String, environment: [String: String]) -> String {
        var safe = output
        for (key, value) in environment where !value.isEmpty && ["TOKEN", "PASSWORD", "SECRET", "API_KEY"].contains(where: key.uppercased().contains) {
            safe = safe.replacingOccurrences(of: value, with: "[redacted]")
        }
        safe = safe.replacingOccurrences(of: #"(?i)(https?://)[^/\s@]+@"#, with: "$1[redacted]@", options: .regularExpression)
        return String(safe.suffix(2000))
    }

    var socket: String { "unix://" + home.appendingPathComponent(".colima/chunky/docker.sock").path }
    var ownsProfile: Bool { (try? String(contentsOf: marker, encoding: .utf8)) == "chunky-v1\n" }

    private func execute(_ executable: String?, _ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        try Task.checkCancellation()
        guard let executable else {
            throw LocalRuntimeError.unavailable("Install Colima and the Docker CLI with brew install colima docker, then reopen Preferences. Nothing is installed automatically.")
        }
        let result = try await run(RuntimeCommand(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw LocalRuntimeError.unavailable("Local runtime command failed (\(result.status)): \(Self.diagnosticTail(result.output, environment: environment))")
        }
        return result.output
    }

    private func dockerCommand(_ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        try await execute(docker, ["--host", socket] + arguments, timeout: timeout)
    }

    func existingConfigurationURL() -> URL? {
        guard ownsProfile else { return nil }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalHome.appendingPathComponent(".colima/chunky/colima.yaml")
        guard candidate.resolvingSymlinksInPath().standardizedFileURL == candidate,
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return candidate
    }

    private struct Profile: Decodable {
        let name: String
        let status: String
        let runtime: String?
        let cpus: Int?
        let memory: Int64?
        let disk: Int64?
    }
    private func currentProfile() async throws -> Profile? {
        let output = try await execute(colima, ["list", "--json"])
        let profiles = try output.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(Profile.self, from: Data($0.utf8)) }
        return profiles.first { $0.name == Self.profile }
    }

    private func requireOwnership(_ profile: Profile?) throws {
        if profile != nil && !ownsProfile {
            throw LocalRuntimeError.unavailable("A Colima profile named chunky already exists and is not owned by this app. Manage it manually; Chunky will not adopt or stop it.")
        }
        if let profile, profile.runtime != "docker" {
            throw LocalRuntimeError.unavailable("The chunky profile does not use Docker. Manage the profile manually.")
        }
    }

    func refresh() async throws -> LocalQdrantSnapshot {
        guard docker != nil else { throw LocalRuntimeError.unavailable("Docker CLI is missing. Run brew install colima docker and reopen Preferences.") }
        let profile = try await currentProfile()
        try requireOwnership(profile)
        guard let profile else { return LocalQdrantSnapshot(profile: "Not created", container: "Not created") }
        var snapshot = LocalQdrantSnapshot(
            profile: profile.status, container: profile.status.lowercased() == "stopped" ? "VM stopped" : "Not checked",
            cpus: profile.cpus.flatMap { $0 > 0 ? $0 : nil },
            memoryBytes: profile.memory.flatMap { $0 > 0 ? $0 : nil },
            diskBytes: profile.disk.flatMap { $0 > 0 ? $0 : nil },
            configurationURL: existingConfigurationURL()
        )
        guard profile.status.lowercased() == "running" else { return snapshot }
        let existing = try await ownedContainer()
        snapshot.profile = "Running"
        snapshot.container = existing.map { $0 ? "Running" : "Stopped" } ?? "Not created"
        snapshot.running = existing == true
        return snapshot
    }

    func start() async throws {
        guard docker != nil else { throw LocalRuntimeError.unavailable("Docker CLI is missing. Run brew install colima docker and reopen Preferences.") }
        let profile = try await currentProfile()
        try requireOwnership(profile)
        if profile == nil {
            if FileManager.default.fileExists(atPath: marker.path) && !ownsProfile {
                throw LocalRuntimeError.unavailable("The Colima ownership marker has unexpected contents. It will not be overwritten.")
            }
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "chunky-v1\n".write(to: marker, atomically: true, encoding: .utf8)
        }
        if profile?.status.lowercased() != "running" {
            var arguments = ["start", "--profile", Self.profile, "--activate=false"]
            if profile == nil { arguments += ["--runtime", "docker", "--cpu", "2", "--memory", "4", "--disk", "30"] }
            _ = try await execute(colima, arguments, timeout: 600)
        }
        if let running = try await ownedContainer() {
            try await prepareVolume()
            if !running { _ = try await dockerCommand(["container", "start", Self.container], timeout: 120) }
            return
        }
        try await prepareVolume()
        _ = try await dockerCommand(["run", "--detach", "--name", Self.container, "--label", Self.ownerKey + "=" + Self.ownerValue,
                                     "--restart", "unless-stopped", "--publish", "127.0.0.1:6333:6333", "--publish", "127.0.0.1:6334:6334",
                                     "--mount", "type=volume,source=" + Self.volume + ",target=/qdrant/storage", Self.image], timeout: 300)
    }

    func stopContainer() async throws {
        let profile = try await currentProfile()
        try requireOwnership(profile)
        guard profile?.status.lowercased() == "running" else { return }
        if try await ownedContainer() == true {
            _ = try await dockerCommand(["container", "stop", "--time", "30", Self.container], timeout: 60)
        }
    }

    func stopProfile() async throws {
        let profile = try await currentProfile()
        try requireOwnership(profile)
        guard profile?.status.lowercased() == "running" else { return }
        _ = try await ownedContainer()
        let names = try await dockerCommand(["container", "ls", "--all", "--format", "{{.Names}}"])
        guard names.split(whereSeparator: \.isNewline).allSatisfy({ $0 == Self.container }) else {
            throw LocalRuntimeError.unavailable("Other containers exist in the chunky profile. Stop the VM manually after checking their workloads.")
        }
        _ = try await execute(colima, ["stop", "--profile", Self.profile], timeout: 120)
    }

    private func prepareVolume() async throws {
        let names = try await dockerCommand(["volume", "ls", "--format", "{{.Name}}"])
        if !names.split(whereSeparator: \.isNewline).contains(Substring(Self.volume)) {
            _ = try await dockerCommand(["volume", "create", "--label", Self.ownerKey + "=" + Self.ownerValue, Self.volume])
        }
        let output = try await dockerCommand(["volume", "inspect", Self.volume])
        let entries = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        guard let item = entries?.first, let labels = item["Labels"] as? [String: String], labels[Self.ownerKey] == Self.ownerValue,
              item["Driver"] as? String == "local", (item["Options"] as? [String: String] ?? [:]).isEmpty else {
            throw LocalRuntimeError.unavailable("The Qdrant data volume is not owned by Chunky or uses unexpected options. It will not be changed.")
        }
    }

    private func ownedContainer() async throws -> Bool? {
        let names = try await dockerCommand(["container", "ls", "--all", "--format", "{{.Names}}"])
        guard names.split(whereSeparator: \.isNewline).contains(Substring(Self.container)) else { return nil }
        let output = try await dockerCommand(["container", "inspect", Self.container])
        return try Self.validateContainer(Data(output.utf8))
    }

    static func validateContainer(_ data: Data) throws -> Bool {
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        guard let item = entries?.first, let config = item["Config"] as? [String: Any],
              let labels = config["Labels"] as? [String: String], labels[ownerKey] == ownerValue,
              config["Image"] as? String == image,
              let host = item["HostConfig"] as? [String: Any], host["Privileged"] as? Bool == false,
              ["default", "bridge"].contains(host["NetworkMode"] as? String ?? ""),
              let ports = host["PortBindings"] as? [String: [[String: String]]], ports.count == 2,
              ports["6333/tcp"] == [["HostIp": "127.0.0.1", "HostPort": "6333"]],
              ports["6334/tcp"] == [["HostIp": "127.0.0.1", "HostPort": "6334"]],
              let mounts = item["Mounts"] as? [[String: Any]], mounts.count == 1,
              mounts[0]["Type"] as? String == "volume", mounts[0]["Name"] as? String == volume,
              mounts[0]["Destination"] as? String == "/qdrant/storage", mounts[0]["RW"] as? Bool == true,
              let state = item["State"] as? [String: Any], let running = state["Running"] as? Bool else {
            throw LocalRuntimeError.unavailable("The chunky-qdrant container has unexpected ownership, image, ports or storage. Manage it manually; Chunky will not change it.")
        }
        return running
    }
}
