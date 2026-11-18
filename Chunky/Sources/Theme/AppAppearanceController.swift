import AppKit
import Combine

@MainActor
final class AppAppearanceController: ObservableObject {
    private var observation: AnyCancellable?

    init(settings: AppSettings, apply: ((NSAppearance.Name?) -> Void)? = nil) {
        let applyAppearance = apply ?? Self.apply
        observation = settings.$appearance
            .removeDuplicates()
            .sink { appearance in
                applyAppearance(appearance.appearanceName)
            }
    }

    static func apply(_ name: NSAppearance.Name?) {
        NSApplication.shared.appearance = name.flatMap { NSAppearance(named: $0) }
    }
}
