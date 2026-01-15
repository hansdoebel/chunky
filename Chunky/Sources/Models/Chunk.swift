import Foundation

struct Chunk: Codable, Identifiable {
    let id: String
    let text: String
    let metadata: ChunkMetadata
}

struct ChunkMetadata: Codable {
    let chunkIndex: Int
    let source: String
    let headings: [String]
    let page: Int?

    enum CodingKeys: String, CodingKey {
        case chunkIndex = "chunk_index"
        case source
        case headings
        case page
    }
}

struct ChunkWithEmbedding: Codable {
    let id: String
    let vector: [Float]
    let payload: ChunkPayload
}

struct ChunkPayload: Codable {
    let text: String
    let source: String
    let page: Int?
    let headings: [String]
}

struct ChunkerOutput: Codable {
    let source: String
    let totalChunks: Int
    let chunks: [Chunk]

    enum CodingKeys: String, CodingKey {
        case source
        case totalChunks = "total_chunks"
        case chunks
    }
}

struct QdrantInput: Codable {
    let points: [ChunkWithEmbedding]
}

// MARK: - DoclingDocument format support

struct DoclingDocument: Codable {
    let schemaName: String
    let name: String
    let origin: DoclingOrigin
    let texts: [DoclingText]

    enum CodingKeys: String, CodingKey {
        case schemaName = "schema_name"
        case name
        case origin
        case texts
    }

    func toChunks() -> [Chunk] {
        let source = origin.filename
        var currentHeadings: [String] = []

        return texts.enumerated().compactMap { index, text in
            if text.label == "section_header" {
                currentHeadings = [text.text]
                return nil
            }

            guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let page = text.prov?.first?.pageNo

            return Chunk(
                id: UUID().uuidString,
                text: text.text,
                metadata: ChunkMetadata(
                    chunkIndex: index,
                    source: source,
                    headings: currentHeadings,
                    page: page
                )
            )
        }
    }
}

struct DoclingOrigin: Codable {
    let filename: String
}

struct DoclingText: Codable {
    let label: String
    let text: String
    let prov: [DoclingProv]?
}

struct DoclingProv: Codable {
    let pageNo: Int

    enum CodingKeys: String, CodingKey {
        case pageNo = "page_no"
    }
}
