import SwiftUI

// MARK: - View Mode

enum ViewMode: String, CaseIterable {
    case queue = "Queue"
    case collections = "Collections"
}

// MARK: - Processing Mode

enum ProcessingMode: String, CaseIterable {
    case chunkOnly = "Chunk Only"
    case full = "Chunk & Ingest"
}

/// Where document conversion runs. The devbox has no MLX.
enum ProcessingHost: String, CaseIterable, Identifiable {
    case localMac = "Local Mac"
    case devbox = "Devbox"

    var id: String { rawValue }

    /// Standard-pipeline accelerator. ROCm reports the GPU as CUDA.
    var defaultAccelerator: Accelerator {
        switch self {
        case .localMac: return .mps
        case .devbox: return .cuda
        }
    }
}

// MARK: - Export Format (for chunk export)

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

// MARK: - Job Status

enum JobStatus {
    case pending, chunking, embedding, uploading, completed, failed
}

// MARK: - Job Type

enum JobType {
    case pdf, chunkedJSON, embeddedJSON, markdown
}

// MARK: - Accelerator

enum Accelerator: String, CaseIterable {
    case auto, cpu, mps, cuda
    var displayName: String { rawValue.uppercased() }
}

// MARK: - Table Mode

enum TableMode: String, CaseIterable {
    case fast, accurate
    var displayName: String { rawValue.capitalized }
}

// MARK: - Distance Metric

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

// MARK: - Compression

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

// MARK: - Docling Model

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

    /// Whether this model runs locally (not via Ollama)
    var isLocal: Bool { self != .standard }

    var isMLX: Bool { rawValue.hasSuffix("-mlx") }

    /// Transformers id the worker can run. MLX models map to that equivalent.
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

    /// Model id to send to the worker. MLX ids are rewritten.
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

// MARK: - XML Document Format

enum XMLDocumentFormat: String, CaseIterable {
    case auto = "auto"
    case uspto = "xml_uspto"
    case jats = "xml_jats"
    case xbrl = "xbrl"

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .uspto: return "USPTO Patent"
        case .jats: return "JATS Article"
        case .xbrl: return "XBRL Financial"
        }
    }
}

// MARK: - Layout Model

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

// MARK: - Image Export Mode

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

// MARK: - OCR Language

enum OCRLanguage: String, CaseIterable {
    // Alphabetically sorted by display name
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
