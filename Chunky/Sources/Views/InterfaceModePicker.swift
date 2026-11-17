import SwiftUI

struct InterfaceModePicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Picker("Interface mode", selection: $settings.interfaceMode) {
            ForEach(InterfaceMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Simple shows everyday controls. Advanced shows all tools. Saved settings remain active in both modes.")
        .accessibilityIdentifier("interface-mode")
    }
}
