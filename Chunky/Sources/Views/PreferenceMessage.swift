import AppKit
import SwiftUI

struct PreferenceMessage: View {
    var context: String
    var message: String
    var secrets: [String] = []
    var isError = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(context, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(isError ? Color.red : Color.secondary)
            Text(PreferenceDiagnostic.message(message, secrets: secrets))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy details", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(
                    PreferenceDiagnostic.report(context: context, message: message, secrets: secrets), forType: .string
                )
            }
            .onChange(of: message) { _, _ in copied = false }
        }
        .padding(.vertical, 4)
    }
}
