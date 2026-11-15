import Foundation
import Testing

@testable import Chunky

struct PicturePresetTests {
    @Test func hostDefaultsAndQualityProfile() {
        #expect(PictureDescriptionPreset.hostDefault(.localMac) == .smolvlm)
        #expect(PictureDescriptionPreset.hostDefault(.devbox) == .graniteVision)
        #expect(PictureDescriptionPreset.graniteVision.displayName == "Granite Vision 3.3-2B")
        #expect(PictureDescriptionPreset.qwen.displayName == "Qwen2.5-VL-3B")
        #expect(QdrantProfile.quality.pictureDescription)
        #expect(QdrantProfile.quality.pictureClassification)
        #expect(!QdrantProfile.standard.pictureDescription)
        #expect(!QdrantProfile.standard.pictureClassification)
    }

    @Test func emptyPresetFollowsTheProcessingHost() {
        let defaults = UserDefaults.standard
        let hostKey = "chunky.processingHost"
        let presetKey = "chunky.pictureDescriptionPreset"
        let urlKey = "chunky.vlmServerURL"
        let savedHost = defaults.string(forKey: hostKey)
        let savedPreset = defaults.string(forKey: presetKey)
        let savedURL = defaults.string(forKey: urlKey)
        defer {
            restore(defaults, hostKey, savedHost)
            restore(defaults, presetKey, savedPreset)
            restore(defaults, urlKey, savedURL)
        }

        let settings = AppSettings()
        settings.pictureDescriptionPreset = ""
        settings.processingHost = .localMac
        #expect(settings.resolvedPictureDescriptionPreset == "smolvlm")
        settings.processingHost = .devbox
        #expect(settings.resolvedPictureDescriptionPreset == "granite_vision")
        settings.pictureDescriptionPreset = "qwen"
        #expect(settings.resolvedPictureDescriptionPreset == "qwen")
        settings.vlmServerURL = "http://127.0.0.1:8001"
        #expect(settings.vlmServerURL == "http://127.0.0.1:8001")
    }
}

private func restore(_ defaults: UserDefaults, _ key: String, _ value: String?) {
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}
