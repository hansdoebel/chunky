import Foundation

enum DoclingModel: String, CaseIterable, Codable {
    case standard = "default"
    case graniteDocling = "granite-docling"
    case smolDocling = "smol-docling"
    case qwen25vl = "qwen2.5-vl"
    case pixtral = "pixtral"

    var displayName: String {
        switch self {
        case .standard: return "Standard (Fast)"
        case .graniteDocling: return "Granite Docling (258M)"
        case .smolDocling: return "SmolDocling (256M)"
        case .qwen25vl: return "Qwen 2.5 VL (3B)"
        case .pixtral: return "Pixtral (12B)"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Default pipeline, no VLM"
        case .graniteDocling: return "IBM document model, good quality"
        case .smolDocling: return "Fast on Apple Silicon"
        case .qwen25vl: return "Higher quality, slower"
        case .pixtral: return "Highest quality, very slow"
        }
    }
}

enum Accelerator: String, CaseIterable, Codable {
    case auto = "auto"
    case cpu = "cpu"
    case mps = "mps"

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .cpu: return "CPU"
        case .mps: return "Apple Silicon (MPS)"
        }
    }
}

enum TableMode: String, CaseIterable, Codable {
    case fast = "fast"
    case accurate = "accurate"

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .accurate: return "Accurate"
        }
    }
}

enum ExportFormat: String, CaseIterable, Codable {
    case none = "none"
    case json = "json"
    case markdown = "markdown"
    case both = "both"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .both: return "Both"
        }
    }
}

enum Compression: String, CaseIterable, Codable {
    case none = "none"
    case gzip = "gzip"
    case zstd = "zstd"
    case lz4 = "lz4"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .gzip: return "Gzip"
        case .zstd: return "Zstd"
        case .lz4: return "LZ4"
        }
    }
}

struct AppSettings: Codable {
    // Ollama
    var ollamaURL: String = "http://localhost:11434"
    var embeddingModel: String = "nomic-embed-text"
    var embeddingBatchSize: Int = 10
    var embeddingConcurrency: Int = 4

    // Qdrant
    var qdrantURL: String = ""
    var qdrantAPIKey: String = ""
    var defaultCollection: String = "documents"
    var qdrantTimeout: Int = 30
    var qdrantPoolSize: Int = 3
    var qdrantBatchSize: Int = 100
    var qdrantCompression: String = "none"

    // Docling
    var doclingModel: String = "default"
    var doclingWorkers: Int = 4
    var doclingAccelerator: String = "cpu"
    var doclingTimeout: Int = 300
    var doclingMaxPages: Int = 0
    var maxTokensPerChunk: Int = 512
    var doTableExtraction: Bool = true
    var tableMode: String = "accurate"
    var doOCR: Bool = false

    // Export
    var exportFormat: String = "none"
    var exportFolder: String = ""

    var embeddingDimensions: Int {
        EmbeddingModelInfo.getDimensions(for: embeddingModel)
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
    }
}
