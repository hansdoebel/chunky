import Foundation

enum PreferenceBrowserAddress {
    static func url(_ address: String) -> URL? {
        guard let normalized = try? PreferenceInput.endpoint(address),
              var components = URLComponents(string: normalized) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
