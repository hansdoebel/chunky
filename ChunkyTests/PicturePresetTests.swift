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
        let settings = IsolatedSettings.make()
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
