import AppKit
import SwiftUI

enum PreferenceFieldKind {
    case endpoint
    case identifier
    case secret
    case integer(ClosedRange<Int>)
}

struct ValidatedPreferenceField: View {
    let title: String
    @Binding var value: String
    var kind: PreferenceFieldKind = .identifier
    var allowEmpty = false
    var actionTitle = "Apply"
    var browserAddress: String? = nil
    var onApply: () -> Void = {}
    @State private var draft = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack {
                    entry
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(apply)
                    Button(actionTitle, action: apply)
                }
            }
            if case .endpoint = kind {
                Button("Open server in browser", systemImage: "safari") {
                    if let url = PreferenceBrowserAddress.url(browserAddress ?? value) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(PreferenceBrowserAddress.url(browserAddress ?? value) == nil)
                .help("Open the saved server address in your default browser. Apply edits first. Credentials and query parameters are omitted.")
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.body).textSelection(.enabled)
            } else if loaded && draft != value {
                Text("Not applied yet. Press Return or \(actionTitle.lowercased()).")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !loaded else { return }
            draft = value
            loaded = true
        }
        .onChange(of: value) { old, new in
            if draft == old { draft = new; error = nil }
        }
    }

    @ViewBuilder
    private var entry: some View {
        switch kind {
        case .secret: SecureField(title, text: $draft)
        default: TextField(title, text: $draft)
        }
    }

    private func apply() {
        do {
            let normalized: String
            switch kind {
            case .endpoint:
                normalized = try PreferenceInput.endpoint(draft, allowEmpty: allowEmpty)
            case .identifier:
                normalized = try PreferenceInput.identifier(draft, label: title, allowEmpty: allowEmpty)
            case .secret:
                normalized = try PreferenceInput.identifier(draft, label: title, allowEmpty: allowEmpty)
                guard !normalized.contains(where: \.isWhitespace) else {
                    error = "\(title) must not contain whitespace."
                    return
                }
            case .integer(let range):
                normalized = String(try PreferenceInput.integer(draft, range: range, label: title))
            }
            value = normalized
            draft = normalized
            error = nil
            onApply()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
