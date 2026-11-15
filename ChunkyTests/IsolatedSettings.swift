import Foundation

@testable import Chunky

enum IsolatedSettings {
    static func make() -> AppSettings {
        let name = "chunky-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults, secrets: MemorySecretStore())
    }
}
