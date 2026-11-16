import SwiftUI

enum ViewMode: String, CaseIterable {
    case queue = "Queue"
    case collections = "Collections"
    case retrieval = "Retrieval"
    case eval = "Eval"
    case analytics = "Analytics"
    case benchmark = "Benchmark"
    case verification = "Verification"
}

enum ProcessingMode: String, CaseIterable {
    case chunkOnly = "Chunk Only"
    case full = "Chunk & Ingest"
}

enum ProcessingHost: String, CaseIterable, Identifiable {
    case localMac = "Local Mac"
    case devbox = "Devbox"

    var id: String { rawValue }

    var defaultAccelerator: Accelerator {
        switch self {
        case .localMac: return .mps
        case .devbox: return .cuda
        }
    }
}

enum DevboxIngestTarget: String, CaseIterable, Identifiable {
    case localDocker = "Local Docker"
    case qdrantCloud = "Qdrant Cloud"

    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable {
    case docling = "docling"
    case doctags = "doctags"
    case html = "html"
    case json = "json"
    case none = "none"
    case text = "text"

    var displayName: String {
        switch self {
        case .docling: return "Markdown"
        case .doctags: return "DocTags"
        case .html: return "HTML"
        case .json: return "JSON"
        case .none: return "None"
        case .text: return "Plain Text"
        }
    }

    var description: String {
        switch self {
        case .docling: return "Native docling layout (image mode from settings)"
        case .doctags: return "Structural markup with document layout tags"
        case .html: return "HTML document with styling"
        case .json: return "Structured data with all metadata"
        case .none: return "No file export"
        case .text: return "Plain text, minimal formatting"
        }
    }
}

enum JobStatus {
    case pending, chunking, embedding, uploading, completed, failed
}

enum JobType {
    case pdf, chunkedJSON, embeddedJSON, markdown
}

enum Accelerator: String, CaseIterable {
    case auto, cpu, mps, cuda
    var displayName: String { rawValue.uppercased() }
}

enum TableMode: String, CaseIterable {
    case fast, accurate
    var displayName: String { rawValue.capitalized }
}

enum DistanceMetric: String, CaseIterable {
    case cosine = "Cosine"
    case dot = "Dot"
    case euclidean = "Euclid"

    var displayName: String {
        switch self {
        case .cosine: return "Cosine"
        case .dot: return "Dot Product"
        case .euclidean: return "Euclidean"
        }
    }

    var description: String {
        switch self {
        case .cosine: return "Best for text search (default)"
        case .dot: return "Faster, use if model recommends"
        case .euclidean: return "For geometric similarity"
        }
    }
}

enum Compression: String, CaseIterable {
    case none = "None"
    case scalar = "Scalar"
    case binary = "Binary"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .scalar: return "Scalar (Int8)"
        case .binary: return "Binary"
        }
    }

    var description: String {
        switch self {
        case .none: return "No quantization"
        case .scalar: return "~4x memory reduction, minimal accuracy loss"
        case .binary: return "~32x memory reduction, higher accuracy loss"
        }
    }
}

enum DoclingModel: String, CaseIterable {
    case standard = "standard"
    case smoldoclingMLX = "smoldocling-mlx"
    case smoldoclingTransformers = "smoldocling-transformers"
    case graniteDoclingMLX = "granite-docling-mlx"
    case graniteDoclingTransformers = "granite-docling-transformers"

    var displayName: String {
        switch self {
        case .standard: return "Standard (no VLM)"
        case .smoldoclingMLX: return "SmolDocling 256M (MLX)"
        case .smoldoclingTransformers: return "SmolDocling 256M (Transformers)"
        case .graniteDoclingMLX: return "Granite-Docling 258M (MLX)"
        case .graniteDoclingTransformers: return "Granite-Docling 258M (Transformers)"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Standard pipeline with layout analysis"
        case .smoldoclingMLX: return "DocTags output, fast on Apple Silicon (~6s/page)"
        case .smoldoclingTransformers: return "DocTags output, Transformers backend (~102s/page)"
        case .graniteDoclingMLX: return "DocTags output, MLX on Apple Silicon"
        case .graniteDoclingTransformers: return "DocTags output, Transformers backend"
        }
    }

    var isLocal: Bool { self != .standard }

    var isMLX: Bool { rawValue.hasSuffix("-mlx") }

    var devboxModel: DoclingModel {
        switch self {
        case .graniteDoclingMLX: return .graniteDoclingTransformers
        case .smoldoclingMLX: return .smoldoclingTransformers
        default: return self
        }
    }

    static func models(for host: ProcessingHost) -> [DoclingModel] {
        switch host {
        case .localMac: return allCases
        case .devbox: return allCases.filter { !$0.isMLX }
        }
    }

    static func workerModelID(_ raw: String) -> String {
        guard let model = DoclingModel(rawValue: raw) else {
            if raw.hasSuffix("-mlx") {
                return String(raw.dropLast(4)) + "-transformers"
            }
            return raw
        }
        return model.devboxModel.rawValue
    }
}

enum PictureDescriptionPreset: String, CaseIterable, Identifiable {
    case smolvlm
    case graniteVision = "granite_vision"
    case qwen
    case api

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smolvlm: return "SmolVLM"
        case .graniteVision: return "Granite Vision 3.3-2B"
        case .qwen: return "Qwen2.5-VL-3B"
        case .api: return "OpenAI-compatible API"
        }
    }

    static func hostDefault(_ host: ProcessingHost) -> PictureDescriptionPreset {
        host == .devbox ? .graniteVision : .smolvlm
    }
}

enum EmbeddingBackendKind: String, CaseIterable, Identifiable {
    case ollama
    case openai
    case fastembed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openai: return "OpenAI-compatible"
        case .fastembed: return "FastEmbed (local CPU)"
        }
    }
}

enum QdrantProfile: String, CaseIterable, Identifiable {
    case standard
    case quality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .quality: return "Quality"
        }
    }

    var pictureDescription: Bool { self == .quality }
    var pictureClassification: Bool { self == .quality }
}

enum LayoutModel: String, CaseIterable {
    case standard = "default"
    case heron = "heron"
    case egretMedium = "egret-medium"
    case egretLarge = "egret-large"
    case egretXlarge = "egret-xlarge"

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .heron: return "Heron (Fast)"
        case .egretMedium: return "Egret Medium"
        case .egretLarge: return "Egret Large"
        case .egretXlarge: return "Egret XLarge"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Default docling layout analysis"
        case .heron: return "Faster layout analysis model"
        case .egretMedium: return "Medium accuracy object detection"
        case .egretLarge: return "High accuracy object detection"
        case .egretXlarge: return "Highest accuracy, slower processing"
        }
    }
}

enum ImageExportMode: String, CaseIterable {
    case embedded = "embedded"
    case placeholder = "placeholder"
    case referenced = "referenced"

    var displayName: String {
        rawValue.capitalized
    }

    var description: String {
        switch self {
        case .embedded: return "Base64 images embedded in markdown"
        case .placeholder: return "Image placeholders only"
        case .referenced: return "Images saved as separate files"
        }
    }
}

enum OCRLanguage: String, CaseIterable {

    case english = "en"
    case french = "fr"
    case german = "de"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .german: return "German"
        }
    }
}
