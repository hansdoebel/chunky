import Foundation

nonisolated struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    static let minimumNode = SemanticVersion(major: 22, minor: 19, patch: 0)

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func parse(_ text: String) -> SemanticVersion? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)(?:\.(\d+))?"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]) else {
            return nil
        }
        let patch: Int
        if match.range(at: 3).location != NSNotFound,
           let patchRange = Range(match.range(at: 3), in: text),
           let value = Int(text[patchRange]) {
            patch = value
        } else {
            patch = 0
        }
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }
}

nonisolated struct PiProbeContext: Sendable {
    var home: String
    var pathEnvironment: String
    var overridePath: String
    var baseEnvironment: [String: String]
    var fileExists: @Sendable (String) -> Bool
    var isExecutable: @Sendable (String) -> Bool
    var shebang: @Sendable (String) -> String?
    var commandOutput: @Sendable (String, [String], [String: String]) -> String?
}

nonisolated struct PiInstallReport: Equatable, Sendable {
    enum Readiness: Equatable, Sendable {
        case unknown
        case ready
        case notInstalled
        case overrideMissing
        case piVersionUnreadable
        case nodeMissing
        case nodeVersionUnreadable
        case nodeTooOld(SemanticVersion)
    }

    var readiness: Readiness
    var executablePath: String?
    var piVersion: SemanticVersion?
    var nodePath: String?
    var nodeVersion: SemanticVersion?

    var installHint: String? {
        PiInstallCopy.hint(for: self)
    }

    static let unknown = PiInstallReport(readiness: .unknown, executablePath: nil, piVersion: nil, nodePath: nil, nodeVersion: nil)
    static let notInstalled = PiInstallReport(readiness: .notInstalled, executablePath: nil, piVersion: nil, nodePath: nil, nodeVersion: nil)
}

nonisolated enum PiInstallCopy {
    static let package = "@earendil-works/pi-coding-agent"
    static let installCommand = "npm install -g @earendil-works/pi-coding-agent"
    static let nodeRequirement = "Node.js 22.19 or newer"

    static func hint(for report: PiInstallReport) -> String? {
        switch report.readiness {
        case .unknown, .ready:
            return nil
        case .notInstalled:
            return "pi is not installed. Install it with \(installCommand). pi needs \(nodeRequirement). Chunky uses the models and sign-in already stored in ~/.pi/agent and does not ask for a pi key."
        case .overrideMissing:
            return "The pi path in settings was not found or is not executable. Clear it to search PATH, Homebrew, npm global, and ~/.local/bin, or install pi with \(installCommand)."
        case .piVersionUnreadable:
            return "pi at \(report.executablePath ?? "the configured path") did not report a version. Reinstall it with \(installCommand)."
        case .nodeMissing:
            return "pi was found at \(report.executablePath ?? "the configured path"), but Node.js is not available. pi needs \(nodeRequirement)."
        case .nodeVersionUnreadable:
            return "pi was found at \(report.executablePath ?? "the configured path"), but Node.js did not report a version. pi needs \(nodeRequirement)."
        case .nodeTooOld(let version):
            return "pi was found at \(report.executablePath ?? "the configured path"), but Node.js \(version.description) is older than \(nodeRequirement)."
        }
    }
}

nonisolated enum PiToolMode: Equatable, Sendable {
    case none
    case allow([String])
}

nonisolated enum PiLaunch {
    static let codingTools = ["bash", "edit", "write", "read"]

    static func arguments(toolMode: PiToolMode = .none) -> [String] {
        var args = ["--mode", "rpc", "--no-session"]
        switch toolMode {
        case .none:
            args.append("--no-tools")
        case .allow(let names):
            args.append("--tools")
            args.append(names.joined(separator: ","))
            let excluded = codingTools + ["grep", "find", "ls", "powershell"]
            args.append("--exclude-tools")
            args.append(excluded.joined(separator: ","))
        }
        return args
    }

    static func codingToolsDisabled(in arguments: [String]) -> Bool {
        if arguments.contains("--no-tools") {
            return true
        }
        guard let index = arguments.firstIndex(of: "--exclude-tools"), arguments.indices.contains(index + 1) else {
            return false
        }
        let listed = Set(arguments[index + 1].split(separator: ",").map(String.init))
        return codingTools.allSatisfy { listed.contains($0) }
    }

    static func environment(executable: String, nodePath: String?, base: [String: String]) -> [String: String] {
        var env = base
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var prefixes = [(executable as NSString).deletingLastPathComponent]
        if let nodePath {
            prefixes.append((nodePath as NSString).deletingLastPathComponent)
        }
        prefixes.append("/opt/homebrew/bin")
        prefixes.append("/usr/local/bin")
        if let home = env["HOME"] {
            prefixes.append(home + "/.local/bin")
            prefixes.append(home + "/.npm-global/bin")
        }
        for prefix in prefixes.reversed() where !paths.contains(prefix) {
            paths.insert(prefix, at: 0)
        }
        env["PATH"] = paths.joined(separator: ":")
        return env
    }
}

nonisolated enum PiModelSelection {
    static func parse(_ value: String) -> (provider: String, modelId: String)? {
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let provider = String(value[..<slash])
        let modelId = String(value[value.index(after: slash)...])
        guard !provider.isEmpty, !modelId.isEmpty else { return nil }
        return (provider, modelId)
    }
}

nonisolated struct PiModel: Identifiable, Equatable, Sendable {
    var modelId: String
    var name: String
    var provider: String
    var contextWindow: Int

    var id: String { modelIdentifier }

    var modelIdentifier: String {
        "\(provider)/\(modelId)"
    }

    var displayName: String {
        if name.isEmpty || name == modelId {
            return modelIdentifier
        }
        return "\(name) (\(provider))"
    }
}

extension PiModel {
    init?(json: [String: Any]) {
        guard let modelId = json["id"] as? String, let provider = json["provider"] as? String else {
            return nil
        }
        if let type = json["type"] as? String, type != "chat" {
            return nil
        }
        self.init(
            modelId: modelId,
            name: (json["name"] as? String) ?? modelId,
            provider: provider,
            contextWindow: json["contextWindow"] as? Int ?? 0
        )
    }

    static func list(from data: Any?) -> [PiModel] {
        if let wrapped = PiJSONL.dictionary(data), wrapped["models"] != nil {
            return PiJSONL.dictionaries(wrapped["models"]).compactMap(PiModel.init(json:))
        }
        return PiJSONL.dictionaries(data).compactMap(PiModel.init(json:))
    }
}

nonisolated enum PiLocator {
    static func live(overridePath: String) -> PiInstallReport {
        let home = NSHomeDirectory()
        let context = PiProbeContext(
            home: home,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "",
            overridePath: overridePath,
            baseEnvironment: ProcessInfo.processInfo.environment,
            fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            isExecutable: { path in
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return exists && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            },
            shebang: { path in
                guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
                defer { try? handle.close() }
                let data: Data
                do {
                    data = try handle.read(upToCount: 256) ?? Data()
                } catch {
                    return nil
                }
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                return text.split(whereSeparator: \.isNewline).first.map(String.init)
            },
            commandOutput: { executable, arguments, environment in
                PiCommandRunner.output(executable: executable, arguments: arguments, environment: environment)
            }
        )
        return assess(context)
    }

    static func assess(_ context: PiProbeContext) -> PiInstallReport {
        let override = expand(context.overridePath, home: context.home)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: String
        if !override.isEmpty {
            guard context.isExecutable(override) else {
                return PiInstallReport(
                    readiness: .overrideMissing,
                    executablePath: override,
                    piVersion: nil,
                    nodePath: nil,
                    nodeVersion: nil
                )
            }
            executable = override
        } else if let found = findExecutable(context) {
            executable = found
        } else {
            return .notInstalled
        }

        guard let node = resolveNode(executable: executable, context: context) else {
            return PiInstallReport(
                readiness: .nodeMissing,
                executablePath: executable,
                piVersion: nil,
                nodePath: nil,
                nodeVersion: nil
            )
        }

        let launchEnvironment = PiLaunch.environment(
            executable: executable,
            nodePath: node,
            base: baseEnvironment(context)
        )
        guard let piText = context.commandOutput(executable, ["--version"], launchEnvironment),
              let piVersion = SemanticVersion.parse(piText) else {
            return PiInstallReport(
                readiness: .piVersionUnreadable,
                executablePath: executable,
                piVersion: nil,
                nodePath: node,
                nodeVersion: nil
            )
        }

        guard let nodeText = context.commandOutput(node, ["--version"], launchEnvironment),
              let nodeVersion = SemanticVersion.parse(nodeText) else {
            return PiInstallReport(
                readiness: .nodeVersionUnreadable,
                executablePath: executable,
                piVersion: piVersion,
                nodePath: node,
                nodeVersion: nil
            )
        }

        if nodeVersion < .minimumNode {
            return PiInstallReport(
                readiness: .nodeTooOld(nodeVersion),
                executablePath: executable,
                piVersion: piVersion,
                nodePath: node,
                nodeVersion: nodeVersion
            )
        }

        return PiInstallReport(
            readiness: .ready,
            executablePath: executable,
            piVersion: piVersion,
            nodePath: node,
            nodeVersion: nodeVersion
        )
    }

    static func searchDirectories(_ context: PiProbeContext) -> [String] {
        var directories: [String] = []
        for entry in context.pathEnvironment.split(separator: ":") {
            let path = String(entry)
            if !path.isEmpty {
                directories.append(path)
            }
        }
        directories.append("/opt/homebrew/bin")
        directories.append("/usr/local/bin")
        directories.append(context.home + "/.local/bin")
        directories.append(context.home + "/.npm-global/bin")
        return directories
    }

    static func findExecutable(_ context: PiProbeContext) -> String? {
        for directory in searchDirectories(context) {
            let candidate = (directory as NSString).appendingPathComponent("pi")
            if context.isExecutable(candidate) {
                return candidate
            }
        }
        if let prefix = context.commandOutput("/usr/bin/env", ["npm", "prefix", "-g"], baseEnvironment(context))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !prefix.isEmpty {
            let candidate = prefix + "/bin/pi"
            if context.isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func resolveNode(executable: String, context: PiProbeContext) -> String? {
        if let shebang = context.shebang(executable) {
            let line = shebang.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#!") {
                let parts = line.dropFirst(2).split(separator: " ").map(String.init)
                if let first = parts.first,
                   first.hasPrefix("/"),
                   (first as NSString).lastPathComponent == "node",
                   context.isExecutable(first) {
                    return first
                }
            }
        }
        let path = PiLaunch.environment(
            executable: executable,
            nodePath: nil,
            base: ["PATH": context.pathEnvironment, "HOME": context.home]
        )["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent("node")
            if context.isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func baseEnvironment(_ context: PiProbeContext) -> [String: String] {
        var base = context.baseEnvironment
        if (base["PATH"] ?? "").isEmpty {
            base["PATH"] = context.pathEnvironment
        }
        if (base["HOME"] ?? "").isEmpty {
            base["HOME"] = context.home
        }
        return base
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }
}

nonisolated enum PiCommandRunner {
    static func output(executable: String, arguments: [String], environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            var inherited = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                inherited[key] = value
            }
            process.environment = inherited
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
