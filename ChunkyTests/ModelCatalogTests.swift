import Foundation
import Testing

@testable import Chunky

struct ModelCatalogTests {
    @Test func ollamaTagsKeepDigestSizeAndQuantization() throws {
        let json = """
        {"models":[{"name":"qwen3-embedding:latest","digest":"abc123","size":4096,"details":{"parameter_size":"0.6B","quantization_level":"Q8_0"}}]}
        """.data(using: .utf8)!
        let models = try ModelCatalog.ollamaModels(from: json)
        #expect(models.count == 1)
        #expect(models[0].name == "qwen3-embedding:latest")
        #expect(models[0].digest == "abc123")
        #expect(models[0].size == 4096)
        #expect(models[0].parameterSize == "0.6B")
        #expect(models[0].quantization == "Q8_0")
        #expect(models[0].state == .installed)
    }

    @Test func pullLineDecodesPercent() {
        let progress = ModelCatalog.pullProgress(line: "{\"status\":\"pulling\",\"completed\":50,\"total\":100}\n")
        #expect(progress?.status == "pulling")
        #expect(progress?.percent == 50)
        #expect(ModelCatalog.pullProgress(line: "  ") == nil)
    }

    @Test func devboxHidesMLXAndMarksInstalledModels() {
        let mac = ModelCatalog.recommended(host: .localMac)
        #expect(mac.map(\.name) == ["granite-docling-mlx"])
        #expect(mac[0].mlx)
        let devbox = ModelCatalog.visible(ModelCatalog.recommended(host: .localMac) + ModelCatalog.recommended(host: .devbox), host: .devbox)
        #expect(devbox.allSatisfy { !$0.mlx })
        let inventory = [
            ManagedModel(name: "qwen3-embedding:latest", state: .installed, size: 4096, digest: "abc", quantization: "Q8_0", parameterSize: "0.6B", source: "ollama", mlx: false)
        ]
        let marked = ModelCatalog.marking(devbox, inventory: inventory, downloading: ["ibm-granite/granite-docling-258M"])
        #expect(marked.first { $0.name == "qwen3-embedding" }?.state == .installed)
        #expect(marked.first { $0.name == "qwen3-embedding" }?.size == 4096)
        #expect(marked.first { $0.name == "qwen3-embedding" }?.downloadKind == "ollama")
        #expect(marked.first { $0.name == "ibm-granite/granite-docling-258M" }?.downloadKind == "huggingface")
        #expect(marked.first { $0.name == "ibm-granite/granite-docling-258M" }?.state == .downloading)
        #expect(marked.first { $0.name == "ibm-granite/granite-vision-3.3-2b" }?.state == .missing)
    }
}
