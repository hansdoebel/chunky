import Foundation
import Testing

@testable import Chunky

struct PiBackendTests {

    @Test func jsonlFramesOnLineFeedOnly() throws {
        let encoded = try PiJSONL.encodeLine(["id": "1", "type": "get_available_models"])
        #expect(encoded.last == 0x0A)
        #expect(!encoded.dropLast().contains(0x0A))
        let roundTrip = try PiJSONL.decodeObject(encoded.dropLast())
        #expect(roundTrip["type"] as? String == "get_available_models")

        var buffer = Data()
        let payload = "{\"type\":\"message_update\",\"delta\":\"line\u{2028}sep\"}\r\n{\"type\":\"agent_settled\"}\n{\"type\":\"partial\""
        buffer.append(contentsOf: payload.utf8)
        let records = PiJSONL.pullRecords(from: &buffer)
        #expect(records.count == 2)
        let first = try PiJSONL.decodeObject(records[0])
        #expect(first["delta"] as? String == "line\u{2028}sep")
        let second = try PiJSONL.decodeObject(records[1])
        #expect(second["type"] as? String == "agent_settled")
        #expect(String(data: buffer, encoding: .utf8) == "{\"type\":\"partial\"")
        buffer.append(contentsOf: "}\n".utf8)
        #expect(PiJSONL.pullRecords(from: &buffer).count == 1)
        #expect(buffer.isEmpty)
    }

    @Test func parsesPiAndNodeVersions() {
        #expect(SemanticVersion.parse("0.78.1") == SemanticVersion(major: 0, minor: 78, patch: 1))
        #expect(SemanticVersion.parse("pi 0.78.1\n") == SemanticVersion(major: 0, minor: 78, patch: 1))
        #expect(SemanticVersion.parse("v22.19.0") == SemanticVersion(major: 22, minor: 19, patch: 0))
        #expect(SemanticVersion.parse("v22.19") == SemanticVersion(major: 22, minor: 19, patch: 0))
        #expect(SemanticVersion.parse("not a version") == nil)
        #expect(SemanticVersion(major: 22, minor: 19, patch: 0) >= .minimumNode)
        #expect(SemanticVersion(major: 22, minor: 18, patch: 9) < .minimumNode)
        #expect(SemanticVersion(major: 23, minor: 0, patch: 0) > .minimumNode)
    }

    @Test func detectsPathHomebrewNpmAndLocalBin() {
        let home = "/Users/ada"
        let fs = VirtualFS()
        fs.executable("/custom/bin/pi", "/custom/bin/node")
        fs.executable("/opt/homebrew/bin/pi", "/opt/homebrew/bin/node")
        fs.version("/custom/bin/pi", "0.78.1")
        fs.version("/custom/bin/node", "v22.21.0")
        fs.version("/opt/homebrew/bin/pi", "0.1.0")
        fs.version("/opt/homebrew/bin/node", "v22.21.0")
        let onPath = PiLocator.assess(fs.context(home: home, path: "/custom/bin:/usr/bin"))
        #expect(onPath.readiness == .ready)
        #expect(onPath.executablePath == "/custom/bin/pi")
        #expect(onPath.piVersion?.description == "0.78.1")
        #expect(onPath.nodeVersion?.description == "22.21.0")
        #expect(!fs.commands.contains { $0.1.contains("npm") })

        let local = VirtualFS()
        local.executable(home + "/.local/bin/pi", home + "/.local/bin/node")
        local.version(home + "/.local/bin/pi", "1.2.3")
        local.version(home + "/.local/bin/node", "v22.19.0")
        let fromLocal = PiLocator.assess(local.context(home: home, path: "/usr/bin"))
        #expect(fromLocal.readiness == .ready)
        #expect(fromLocal.executablePath == home + "/.local/bin/pi")
        #expect(fromLocal.nodeVersion == .minimumNode)

        let npm = VirtualFS()
        npm.outputs["npm-prefix"] = home + "/.npm-prefix\n"
        npm.executable(home + "/.npm-prefix/bin/pi", home + "/.npm-prefix/bin/node")
        npm.version(home + "/.npm-prefix/bin/pi", "9.0.0")
        npm.version(home + "/.npm-prefix/bin/node", "v23.1.0")
        let fromNpm = PiLocator.assess(npm.context(home: home, path: "/usr/bin"))
        #expect(fromNpm.readiness == .ready)
        #expect(fromNpm.executablePath == home + "/.npm-prefix/bin/pi")
        #expect(npm.commands.contains { $0.0 == "/usr/bin/env" && $0.1 == ["npm", "prefix", "-g"] })
    }

    @Test func overrideBeatsSearchAndMissingOverrideDoesNotFallThrough() {
        let home = "/Users/ada"
        let fs = VirtualFS()
        fs.executable("/opt/homebrew/bin/pi", "/opt/homebrew/bin/node", home + "/bin/pi", home + "/bin/node")
        fs.version("/opt/homebrew/bin/pi", "0.1.0")
        fs.version("/opt/homebrew/bin/node", "v22.21.0")
        fs.version(home + "/bin/pi", "2.0.0")
        fs.version(home + "/bin/node", "v22.21.0")
        let overridden = PiLocator.assess(fs.context(home: home, path: "/usr/bin", override: "~/bin/pi"))
        #expect(overridden.executablePath == home + "/bin/pi")
        #expect(overridden.piVersion?.description == "2.0.0")

        let missing = PiLocator.assess(fs.context(home: home, path: "/opt/homebrew/bin", override: "/missing/pi"))
        #expect(missing.readiness == .overrideMissing)
        #expect(missing.installHint?.contains("not found") == true)
        #expect(missing.executablePath == "/missing/pi")
    }

    @Test func nodeFloorAndUnreadableVersions() {
        let home = "/Users/ada"
        let old = VirtualFS()
        old.executable("/opt/homebrew/bin/pi", "/opt/homebrew/bin/node")
        old.version("/opt/homebrew/bin/pi", "0.78.1")
        old.version("/opt/homebrew/bin/node", "v22.18.9")
        let tooOld = PiLocator.assess(old.context(home: home, path: "/opt/homebrew/bin"))
        #expect(tooOld.readiness == .nodeTooOld(SemanticVersion(major: 22, minor: 18, patch: 9)))
        #expect(tooOld.installHint?.contains("22.18.9") == true)
        #expect(tooOld.installHint?.contains(PiInstallCopy.nodeRequirement) == true)

        let absolute = VirtualFS()
        absolute.executable("/opt/homebrew/bin/pi", "/usr/local/bin/node", "/opt/homebrew/bin/node")
        absolute.shebangs["/opt/homebrew/bin/pi"] = "#!/usr/local/bin/node"
        absolute.version("/opt/homebrew/bin/pi", "0.78.1")
        absolute.version("/usr/local/bin/node", "v20.0.0")
        absolute.version("/opt/homebrew/bin/node", "v23.0.0")
        let pinned = PiLocator.assess(absolute.context(home: home, path: "/opt/homebrew/bin"))
        #expect(pinned.readiness == .nodeTooOld(SemanticVersion(major: 20, minor: 0, patch: 0)))
        #expect(pinned.nodePath == "/usr/local/bin/node")

        let broken = VirtualFS()
        broken.executable("/opt/homebrew/bin/pi", "/opt/homebrew/bin/node")
        broken.version("/opt/homebrew/bin/pi", "not a version")
        broken.version("/opt/homebrew/bin/node", "v22.21.0")
        let unreadable = PiLocator.assess(broken.context(home: home, path: "/opt/homebrew/bin"))
        #expect(unreadable.readiness == .piVersionUnreadable)

        let noNode = VirtualFS()
        noNode.executable("/opt/homebrew/bin/pi")
        noNode.version("/opt/homebrew/bin/pi", "0.78.1")
        let missingNode = PiLocator.assess(noNode.context(home: home, path: "/usr/bin"))
        #expect(missingNode.readiness == .nodeMissing)

        let absent = PiLocator.assess(VirtualFS().context(home: home, path: "/usr/bin"))
        #expect(absent.readiness == .notInstalled)
        let hint = absent.installHint ?? ""
        #expect(hint.contains(PiInstallCopy.installCommand))
        #expect(hint.contains("does not ask for a pi key"))
        #expect(PiInstallReport.readyFixture.installHint == nil)
        #expect(PiInstallReport.unknown.installHint == nil)
    }

    @Test func versionCheckUsesTheLaunchPathWhenHomebrewIsOffPath() {
        let fs = VirtualFS()
        fs.executable("/opt/homebrew/bin/pi", "/opt/homebrew/bin/node")
        fs.version("/opt/homebrew/bin/pi", "0.78.1")
        fs.version("/opt/homebrew/bin/node", "v22.21.0")
        fs.piVersionRequiresPath = "/opt/homebrew/bin"
        let report = PiLocator.assess(fs.context(home: "/Users/ada", path: "/usr/bin"))
        #expect(report.readiness == .ready)
        #expect(report.executablePath == "/opt/homebrew/bin/pi")
        #expect(report.nodePath == "/opt/homebrew/bin/node")
        #expect(fs.pathUsedForVersion("/opt/homebrew/bin/pi")?.contains("/opt/homebrew/bin") == true)
    }

    @Test func launchDisablesCodingTools() {
        #expect(PiLaunch.arguments() == ["--mode", "rpc", "--no-session", "--no-tools"])
        #expect(PiLaunch.codingToolsDisabled(in: PiLaunch.arguments()))
        #expect(!PiLaunch.arguments().contains("--api-key"))
        let allowed = PiLaunch.arguments(toolMode: .allow(["mcp__chunky__search"]))
        #expect(PiLaunch.codingToolsDisabled(in: allowed))
        #expect(allowed.contains("--tools"))
        #expect(allowed.contains("mcp__chunky__search"))
        #expect(!allowed.contains("--no-tools"))
        let env = PiLaunch.environment(
            executable: "/opt/homebrew/bin/pi",
            nodePath: "/opt/homebrew/bin/node",
            base: ["HOME": "/Users/ada", "PATH": "/usr/bin", "OPENAI_API_KEY": "already-there"]
        )
        #expect(env["OPENAI_API_KEY"] == "already-there")
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(env["CHUNKY_CHAT_API_KEY"] == nil)
    }

    @Test func chatSettingsRoundTripInIsolatedSuite() {
        let name = "chunky-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        #expect(settings.chatBackend == ChatBackendPreference.automatic.rawValue)
        #expect(settings.piExecutablePath.isEmpty)
        #expect(settings.chatAPIURL == "http://127.0.0.1:11434/v1")
        #expect(settings.chatModel.isEmpty)
        #expect(settings.piModel.isEmpty)
        #expect(settings.chatAPIKey.isEmpty)
        settings.chatBackend = ChatBackendPreference.pi.rawValue
        settings.piExecutablePath = "/custom/pi"
        settings.chatAPIURL = "http://127.0.0.1:8080/v1"
        settings.piModel = "ollama/qwen3"
        settings.chatModel = "qwen3"
        settings.chatAPIKey = "chunky-secret"
        let again = AppSettings(defaults: defaults, secrets: secrets)
        #expect(again.chatBackend == "pi")
        #expect(again.piExecutablePath == "/custom/pi")
        #expect(again.chatAPIURL == "http://127.0.0.1:8080/v1")
        #expect(again.piModel == "ollama/qwen3")
        #expect(again.chatModel == "qwen3")
        #expect(again.chatAPIKey == "chunky-secret")
        again.chatAPIKey = ""
        #expect(secrets.value(for: KeychainService.chatAPIKeyKey) == nil)
    }

    @Test func routesPiOrFallsBack() {
        let ready = ChatRouter.route(preference: .automatic, report: .readyFixture)
        #expect(ready.kind == .pi)
        #expect(!ready.fellBack)
        let missing = ChatRouter.route(preference: .automatic, report: .notInstalled)
        #expect(missing.kind == .openAICompatible)
        #expect(missing.fellBack)
        let forced = ChatRouter.route(preference: .pi, report: .notInstalled)
        #expect(forced.fellBack)
        #expect(forced.kind == .openAICompatible)
        let chosen = ChatRouter.route(preference: .openAICompatible, report: .readyFixture)
        #expect(chosen.kind == .openAICompatible)
        #expect(!chosen.fellBack)
        let checking = ChatRouter.route(preference: .automatic, report: .unknown)
        #expect(checking.checking)
        #expect(!checking.fellBack)
        #expect(PiModelSelection.parse("ollama/qwen3")?.provider == "ollama")
        #expect(PiModelSelection.parse("ollama/qwen3")?.modelId == "qwen3")
        #expect(PiModelSelection.parse("qwen3") == nil)
    }

    @Test func fakePiListsSelectsAndStreams() async throws {
        let factory = TransportFactory()
        factory.splitResponses = true
        let session = factory.session(report: .readyFixture)
        let models = try await session.availableModels()
        #expect(models.map(\.modelIdentifier) == ["ollama/qwen3", "anthropic/sonnet"])
        #expect(models.map(\.name) == ["Qwen3", "Sonnet"])
        let selected = try await session.selectModel(provider: "ollama", modelId: "qwen3")
        #expect(selected.modelIdentifier == "ollama/qwen3")
        let commands = factory.commands
        let list = commands.first { $0["type"] as? String == "get_available_models" }
        let select = commands.first { $0["type"] as? String == "set_model" }
        #expect((list?["id"] as? String)?.isEmpty == false)
        #expect(select?["provider"] as? String == "ollama")
        #expect(select?["modelId"] as? String == "qwen3")
        #expect(factory.launchCount == 1)
        let launch = factory.launches[0]
        #expect(launch.executable == "/opt/homebrew/bin/pi")
        #expect(launch.arguments == PiLaunch.arguments())
        #expect(!launch.environment.values.contains("chunky-secret"))
        #expect(launch.environment["OPENAI_API_KEY"] == "already-there")

        let http = ScriptedChatHTTP()
        let backend = ChatBackendFactory.make(
            preference: .pi,
            report: .readyFixture,
            piModel: "ollama/qwen3",
            chatModel: "qwen3",
            apiURL: "http://127.0.0.1:11434/v1",
            apiKey: "chunky-secret",
            overridePath: "/opt/homebrew/bin/pi",
            session: session,
            http: http
        )
        var text = ""
        for try await delta in backend.stream(user: "Hello") {
            text += delta
        }
        #expect(text == "Hello world")
        #expect(http.requests.isEmpty)
        #expect(factory.commands.contains { $0["type"] as? String == "prompt" && $0["message"] as? String == "Hello" })
        #expect(factory.launchCount == 1)
    }

    @Test func restartsAfterCrashAndStopsOnQuit() async throws {
        let factory = TransportFactory()
        let session = factory.session(report: .readyFixture)
        _ = try await session.availableModels()
        factory.crashLatest()
        _ = try await session.availableModels()
        #expect(factory.launchCount == 2)
        session.terminate()
        do {
            _ = try await session.availableModels()
            Issue.record("terminated pi should refuse new commands")
        } catch let error as PiSessionError {
            #expect(error == .terminated)
        } catch {
            Issue.record("unexpected error")
        }
    }

    @Test func changingThePiPathStartsThatExecutable() async throws {
        let box = ReportBox(report: .readyFixture)
        let factory = TransportFactory()
        let session = PiChatSession(
            locate: { box.report },
            transportFactory: { factory.make() },
            environment: { ["HOME": "/Users/ada", "PATH": "/usr/bin"] }
        )
        _ = try await session.availableModels()
        let replacement = PiInstallReport(
            readiness: .ready,
            executablePath: "/Users/ada/.local/bin/pi",
            piVersion: SemanticVersion(major: 0, minor: 78, patch: 1),
            nodePath: "/Users/ada/.local/bin/node",
            nodeVersion: SemanticVersion(major: 22, minor: 21, patch: 0)
        )
        box.report = replacement
        session.setOverridePath("/Users/ada/.local/bin/pi")
        _ = try await session.availableModels()
        #expect(factory.launchCount == 2)
        #expect(factory.launches.last?.executable == "/Users/ada/.local/bin/pi")
    }

    @Test func abortStopsTheFakePiStream() async throws {
        let factory = TransportFactory()
        factory.settlePrompts = false
        let session = factory.session(report: .readyFixture)
        let box = TextBox()
        let task = Task {
            for try await delta in session.stream(user: "Hi") {
                await box.add(delta)
            }
        }
        let sawDelta = await waitUntil { await box.value == "Hello" }
        #expect(sawDelta)
        await session.abort()
        try await task.value
        #expect(await box.value == "Hello")
        #expect(factory.commands.contains { $0["type"] as? String == "abort" })
    }

    @Test func missingPiFallsBackToOpenAIAndRedactsTheKey() async throws {
        let factory = TransportFactory()
        let session = factory.session(report: .notInstalled)
        let http = ScriptedChatHTTP()
        let payload = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\ndata: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\ndata: [DONE]\n".utf8)
        http.chunks = [Data(payload.prefix(24)), Data(payload.dropFirst(24))]
        let backend = ChatBackendFactory.make(
            preference: .automatic,
            report: .notInstalled,
            piModel: "ollama/qwen3",
            chatModel: "qwen3",
            apiURL: "http://127.0.0.1:11434/v1/",
            apiKey: "super-secret-token",
            overridePath: "",
            session: session,
            http: http
        )
        var text = ""
        for try await delta in backend.stream(user: "hello") {
            text += delta
        }
        #expect(text == "Hi there")
        #expect(factory.launchCount == 0)
        let request = http.requests[0]
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer super-secret-token")
        #expect(request.url?.absoluteString.contains("super-secret-token") == false)
        let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        #expect(PiJSONL.dictionary(sent)?["model"] as? String == "qwen3")

        let client = OpenAICompatibleChatClient(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "qwen3",
            apiKey: "super-secret-token",
            http: http
        )
        http.body = Data(#"{"data":[{"id":"qwen3"},{"id":"llama"}]}"#.utf8)
        let models = try await client.listModels()
        #expect(models == ["qwen3", "llama"])

        http.status = 401
        http.chunks = []
        http.body = Data("nope super-secret-token".utf8)
        do {
            for try await _ in client.stream(user: "x") {}
            Issue.record("expected the chat endpoint to fail")
        } catch {
            let description = error.localizedDescription
            #expect(description.contains("401"))
            #expect(description.contains("[redacted]"))
            #expect(!description.contains("super-secret-token"))
        }
    }

    @Test func explicitOpenAIDoesNotLaunchPi() async throws {
        let factory = TransportFactory()
        let session = factory.session(report: .readyFixture)
        let http = ScriptedChatHTTP()
        http.chunks = [Data("data: [DONE]\n".utf8)]
        let backend = ChatBackendFactory.make(
            preference: .openAICompatible,
            report: .readyFixture,
            piModel: "ollama/qwen3",
            chatModel: "qwen3",
            apiURL: "http://127.0.0.1:11434/v1",
            apiKey: "",
            overridePath: "/opt/homebrew/bin/pi",
            session: session,
            http: http
        )
        var count = 0
        for try await _ in backend.stream(user: "hello") {
            count += 1
        }
        #expect(count == 0)
        #expect(factory.launchCount == 0)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }
}

private final class ReportBox: @unchecked Sendable {
    var report: PiInstallReport
    init(report: PiInstallReport) { self.report = report }
}

private final class VirtualFS: @unchecked Sendable {
    var executables: Set<String> = []
    var shebangs: [String: String] = [:]
    var outputs: [String: String] = [:]
    var piVersionRequiresPath: String?
    private(set) var commands: [(String, [String])] = []
    private var versionPATH: [String: String] = [:]
    private let lock = NSLock()

    func pathUsedForVersion(_ executable: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return versionPATH[executable]
    }

    func executable(_ paths: String...) {
        executables.formUnion(paths)
    }

    func version(_ path: String, _ text: String) {
        outputs[path] = text
    }

    func context(home: String, path: String, override: String = "") -> PiProbeContext {
        PiProbeContext(
            home: home,
            pathEnvironment: path,
            overridePath: override,
            baseEnvironment: ["PATH": path, "HOME": home],
            fileExists: { self.executables.contains($0) },
            isExecutable: { self.executables.contains($0) },
            shebang: { path in
                if let shebang = self.shebangs[path] {
                    return shebang
                }
                return path.hasSuffix("/pi") ? "#!/usr/bin/env node" : nil
            },
            commandOutput: { executable, arguments, environment in
                self.lock.lock()
                self.commands.append((executable, arguments))
                if arguments == ["--version"] {
                    self.versionPATH[executable] = environment["PATH"] ?? ""
                }
                let required = self.piVersionRequiresPath
                self.lock.unlock()
                if arguments == ["--version"] {
                    if executable.hasSuffix("/pi"), let required, !(environment["PATH"] ?? "").contains(required) {
                        return nil
                    }
                    return self.outputs[executable]
                }
                if arguments == ["npm", "prefix", "-g"] {
                    return self.outputs["npm-prefix"]
                }
                return nil
            }
        )
    }
}

private final class TransportFactory: @unchecked Sendable {
    var settlePrompts = true
    var splitResponses = false
    private let lock = NSLock()
    private var transports: [FakePiTransport] = []

    func make() -> FakePiTransport {
        let transport = FakePiTransport()
        transport.settlePrompts = settlePrompts
        transport.splitResponses = splitResponses
        lock.lock()
        transports.append(transport)
        lock.unlock()
        return transport
    }

    func session(report: PiInstallReport) -> PiChatSession {
        PiChatSession(
            locate: { report },
            transportFactory: { self.make() },
            environment: { ["HOME": "/Users/ada", "PATH": "/usr/bin", "OPENAI_API_KEY": "already-there"] }
        )
    }

    func crashLatest() {
        lock.lock()
        let latest = transports.last
        lock.unlock()
        latest?.crash()
    }

    var launchCount: Int { launches.count }

    var launches: [(executable: String, arguments: [String], environment: [String: String])] {
        lock.lock()
        let all = transports
        lock.unlock()
        return all.flatMap { $0.snapshotLaunches() }
    }

    var commands: [[String: Any]] {
        lock.lock()
        let all = transports
        lock.unlock()
        return all.flatMap { $0.snapshotCommands() }
    }
}

private final class FakePiTransport: PiByteStream, @unchecked Sendable {
    var settlePrompts = true
    var splitResponses = false
    private let lock = NSLock()
    private var running = false
    private var writeBuffer = Data()
    private var launches: [(executable: String, arguments: [String], environment: [String: String])] = []
    private var commands: [[String: Any]] = []
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    var stdout: AsyncStream<Data> { stream }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    init() {
        var captured: AsyncStream<Data>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func launch(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?) throws {
        _ = currentDirectory
        lock.lock()
        launches.append((executable, arguments, environment))
        running = true
        lock.unlock()
    }

    func write(_ data: Data) throws {
        lock.lock()
        guard running else {
            lock.unlock()
            throw PiTransportError.notRunning
        }
        writeBuffer.append(data)
        let records = PiJSONL.pullRecords(from: &writeBuffer)
        var objects: [[String: Any]] = []
        for record in records {
            if let object = try? PiJSONL.decodeObject(record) {
                commands.append(object)
                objects.append(object)
            }
        }
        let settle = settlePrompts
        lock.unlock()
        for object in objects {
            reply(to: object, settle: settle)
        }
    }

    func terminate() {
        crash()
    }

    func crash() {
        lock.lock()
        running = false
        lock.unlock()
        continuation.finish()
    }

    func snapshotLaunches() -> [(executable: String, arguments: [String], environment: [String: String])] {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }

    func snapshotCommands() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    private func reply(to object: [String: Any], settle: Bool) {
        let id = object["id"] as? String ?? ""
        switch object["type"] as? String {
        case "get_available_models":
            push([
                "id": id,
                "type": "response",
                "command": "get_available_models",
                "success": true,
                "data": [
                    "models": [
                        ["id": "qwen3", "name": "Qwen3", "provider": "ollama", "contextWindow": 32768],
                        ["id": "img", "name": "Img", "provider": "ollama", "type": "image", "contextWindow": 0],
                        ["id": "sonnet", "name": "Sonnet", "provider": "anthropic", "contextWindow": 200000]
                    ]
                ]
            ])
        case "set_model":
            let provider = object["provider"] as? String ?? ""
            let modelId = object["modelId"] as? String ?? ""
            push([
                "id": id,
                "type": "response",
                "command": "set_model",
                "success": true,
                "data": ["id": modelId, "name": modelId, "provider": provider, "contextWindow": 8192]
            ])
        case "prompt":
            push([
                "id": id,
                "type": "response",
                "command": "prompt",
                "success": true,
                "data": ["disposition": "started"]
            ])
            push(update("Hello"))
            if settle {
                push(update(" world"))
                push(["type": "agent_settled", "aborted": false])
            }
        case "abort":
            push(["id": id, "type": "response", "command": "abort", "success": true])
            push(["type": "agent_settled", "aborted": true])
        default:
            push(["id": id, "type": "response", "command": object["type"] as? String ?? "", "success": true])
        }
    }

    private func update(_ delta: String) -> [String: Any] {
        [
            "type": "message_update",
            "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": delta]
        ]
    }

    private func push(_ object: [String: Any]) {
        guard let data = try? PiJSONL.encodeLine(object) else { return }
        if splitResponses && data.count > 1 {
            let mid = data.count / 2
            continuation.yield(Data(data.prefix(mid)))
            continuation.yield(Data(data.suffix(from: mid)))
        } else {
            continuation.yield(data)
        }
    }
}

private actor TextBox {
    var value = ""
    func add(_ text: String) { value += text }
}

private func waitUntil(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private final class ScriptedChatHTTP: ChatHTTPStreaming, @unchecked Sendable {
    var requests: [URLRequest] = []
    var status = 200
    var body = Data()
    var chunks: [Data] = []
    private let lock = NSLock()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let status = status
        let body = body
        lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.lock()
        requests.append(request)
        let status = status
        let chunks = chunks.isEmpty ? [body] : chunks
        lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks where !chunk.isEmpty {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return (response, stream)
    }
}

extension PiInstallReport {
    static let readyFixture = PiInstallReport(
        readiness: .ready,
        executablePath: "/opt/homebrew/bin/pi",
        piVersion: SemanticVersion(major: 0, minor: 78, patch: 1),
        nodePath: "/opt/homebrew/bin/node",
        nodeVersion: SemanticVersion(major: 22, minor: 21, patch: 0)
    )
}
