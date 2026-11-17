import Foundation

struct PreferenceSearchItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let tab: Int
    let icon: String
    let keywords: String

    static let all: [PreferenceSearchItem] = [
        .init(id: "embedding", title: "Embedding models", detail: "Provider, endpoint, model and vector dimensions", tab: 0, icon: "cpu", keywords: "ollama openai fastembed cpu download compatibility"),
        .init(id: "performance", title: "Embedding performance", detail: "Batch size, concurrency, streaming and cache", tab: 0, icon: "speedometer", keywords: "reuse embeddings"),
        .init(id: "documents", title: "Document processing", detail: "Local Mac, worker profiles, models and conversion", tab: 1, icon: "doc.text", keywords: "devbox token accelerator timeout pages vlm ocr language table chunk tokenizer"),
        .init(id: "metadata", title: "Document metadata", detail: "Choose fields included with chunks", tab: 1, icon: "list.bullet", keywords: "filename page heading timestamp title authors index content section doi id url year language"),
        .init(id: "database", title: "Database connection", detail: "Qdrant endpoints, credentials and collections", tab: 2, icon: "externaldrive", keywords: "cloud api key server grpc"),
        .init(id: "colima", title: "Local Qdrant", detail: "Colima virtual machine and container controls", tab: 2, icon: "desktopcomputer", keywords: "docker start stop cpu ram disk configuration"),
        .init(id: "upload", title: "Database tuning", detail: "Batch size, timeout, distance, quantization and hybrid search", tab: 2, icon: "slider.horizontal.3", keywords: "qdrant compression upload"),
        .init(id: "export", title: "File export", detail: "Output format and destination folder", tab: 3, icon: "square.and.arrow.up", keywords: "save files markdown html json text export folder"),
        .init(id: "datasets", title: "Dataset downloads", detail: "Open Datasets to choose the download folder and sample size", tab: 6, icon: "arrow.down.circle", keywords: "hugging face huggingface wikipedia download folder"),
        .init(id: "chat", title: "Chat", detail: "pi and OpenAI-compatible chat models", tab: 4, icon: "bubble.left.and.bubble.right", keywords: "api key endpoint fallback node"),
        .init(id: "chunk-cache", title: "Chunk cache", detail: "Size limit, disk usage and Clear cache", tab: 5, icon: "internaldrive", keywords: "chunks storage cached clear limit"),
        .init(id: "about", title: "App and dependencies", detail: "Version, Docling and watched folders", tab: 5, icon: "info.circle", keywords: "update python runtime health installation"),
        .init(id: "appearance", title: "Appearance", detail: "System, Light or Dark", tab: 5, icon: "circle.lefthalf.filled", keywords: "theme color colour")
    ]

    static func matches(_ query: String) -> [PreferenceSearchItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return all.filter { item in
            let text = "\(item.title) \(item.detail) \(item.keywords)"
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
