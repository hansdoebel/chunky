import SwiftUI

struct AppearancePicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Picker("Appearance", selection: $settings.appearance) {
            ForEach(AppAppearance.allCases) { appearance in
                Text(appearance.displayName).tag(appearance)
            }
        }
        .pickerStyle(.segmented)
        .help("System follows your Mac’s appearance. Light and Dark apply to all Chunky windows.")
    }
}
