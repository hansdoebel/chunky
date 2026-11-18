import Foundation

enum PreferenceBrowserAddress {
    static func cloudDashboard(cloudAddress: String, nativeAddress: String) -> URL? {
        let configuredCloud = url(cloudAddress) != nil
        let nativeHost = url(nativeAddress)?.host?.lowercased() ?? ""
        guard configuredCloud || nativeHost.hasSuffix(".cloud.qdrant.io") else { return nil }
        return URL(string: "https://cloud.qdrant.io")
    }

    static func url(_ address: String) -> URL? {
        guard let normalized = try? PreferenceInput.endpoint(address),
              var components = URLComponents(string: normalized) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
