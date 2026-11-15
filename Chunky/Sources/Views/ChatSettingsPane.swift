import SwiftUI

struct ChatSettingsPane: View {
    @Binding var backend: String
    @Binding var piPath: String
    @Binding var chatAPIURL: String
    @Binding var chatModel: String
    @Binding var apiKey: String
    var report: PiInstallReport
    var models: [PiModel]
    var statusMessage: String
    var onCheck: () -> Void
    var onListModels: () -> Void

    private var preference: ChatBackendPreference {
        ChatBackendPreference(rawValue: backend) ?? .automatic
    }

    private var route: ChatRoute {
        ChatRouter.route(preference: preference, report: report)
    }

    var body: some View {
        Form {
            if route.fellBack, let hint = report.installHint {
                Section {
                    Label(hint, systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Text("Chat is using the OpenAI-compatible endpoint below until pi is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if route.checking {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking the local pi install…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Backend", selection: $backend) {
                    ForEach(ChatBackendPreference.allCases) { item in
                        Text(item.displayName).tag(item.rawValue)
                    }
                }
            } header: {
                Text("Chat model")
            } footer: {
                Text("Automatic uses pi when it is installed and falls back to an OpenAI-compatible endpoint.")
            }

            Section {
                TextField("pi path", text: $piPath, prompt: Text("Leave empty to search PATH"))
                    .textFieldStyle(.roundedBorder)

                statusRow

                if route.kind == .pi, !models.isEmpty {
                    Picker("Model", selection: $chatModel) {
                        if chatModel.isEmpty {
                            Text("Select a model").tag("")
                        }
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.modelIdentifier)
                        }
                    }
                } else if route.kind == .pi {
                    TextField("Model", text: $chatModel, prompt: Text("provider/model"))
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("Check again", action: onCheck)
                    Button("List models", action: onListModels)
                        .disabled(report.readiness != .ready)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("pi")
            } footer: {
                Text("Chunky starts pi with bash, edit, write, and read disabled. It does not ask for a pi API key. pi reads ~/.pi/agent.")
            }

            Section {
                TextField("Endpoint", text: $chatAPIURL, prompt: Text("http://127.0.0.1:11434/v1"))
                    .textFieldStyle(.roundedBorder)
                if route.kind != .pi {
                    TextField("Model", text: $chatModel, prompt: Text("qwen3"))
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("API key", text: $apiKey, prompt: Text("Optional, stored in the Keychain"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("OpenAI-compatible fallback")
            } footer: {
                Text("Used for Ollama, llama.cpp, vLLM, and LM Studio. The key stays in the Keychain and is not sent to pi.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch report.readiness {
        case .unknown:
            Label("Not checked yet", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .ready:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Ready · pi \(report.piVersion?.description ?? "") · Node \(report.nodeVersion?.description ?? "")",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                if let path = report.executablePath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        default:
            Label("pi is not ready", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
