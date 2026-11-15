import Foundation
import Testing

@testable import Chunky

struct HostVLMTests {

    @Test func devboxHidesMLXModels() {
        let devbox = DoclingModel.models(for: .devbox).map(\.rawValue)
        #expect(!devbox.contains("granite-docling-mlx"))
        #expect(!devbox.contains("smoldocling-mlx"))
        #expect(devbox.contains("granite-docling-transformers"))
        #expect(devbox.contains("standard"))

        let mac = DoclingModel.models(for: .localMac).map(\.rawValue)
        #expect(mac.contains("granite-docling-mlx"))
    }

    @Test func mlxMapsToTransformersForTheWorker() {
        #expect(DoclingModel.workerModelID("granite-docling-mlx") == "granite-docling-transformers")
        #expect(DoclingModel.workerModelID("smoldocling-mlx") == "smoldocling-transformers")
        #expect(DoclingModel.graniteDoclingMLX.devboxModel == .graniteDoclingTransformers)
        #expect(DoclingModel.workerModelID("granite-docling-transformers") == "granite-docling-transformers")
    }

    @Test func acceleratorDefaultsFollowTheHost() {
        #expect(ProcessingHost.localMac.defaultAccelerator == .mps)
        #expect(ProcessingHost.devbox.defaultAccelerator == .cuda)
        #expect(ProcessingHost.localMac.defaultAccelerator.rawValue == "mps")
        #expect(ProcessingHost.devbox.defaultAccelerator.rawValue == "cuda")
    }
}
