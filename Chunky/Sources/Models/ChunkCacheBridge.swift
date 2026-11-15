import Foundation

enum ChunkCacheUse: String, Equatable {
    case miss
    case hit
    case vectors
}

enum ChunkCachePolicy {
    static func use(force: Bool, chunkCount: Int, vectorCount: Int?) -> ChunkCacheUse {
        if force || chunkCount == 0 {
            return .miss
        }
        if let vectorCount, vectorCount == chunkCount {
            return .vectors
        }
        return .hit
    }

    static func key(contentSHA256: String, settings: AppSettings) -> ChunkCacheKey {
        ChunkCacheKey(
            contentSHA256: contentSHA256,
            doclingVersion: settings.recordedDoclingVersion,
            pipeline: settings.doclingModel,
            tokenizer: settings.chunkTokenizer,
            maxTokens: settings.maxTokensPerChunk
        )
    }
}

struct ChunkCacheBridge {
    var settings: AppSettings
    var directory: URL
    var remote: WorkerChunkCache?

    func load(digest: String, force: Bool) async -> (chunks: [ChunkCacheChunk], vectors: [[Double]]?)? {
        if force {
            return nil
        }
        let key = ChunkCachePolicy.key(contentSHA256: digest, settings: settings)
        let store = ChunkCacheStore(directory: directory, limitBytes: settings.chunkCacheLimitBytes)
        if let local = try? store.lookup(
            key,
            embeddingModel: settings.embeddingModel,
            embeddingDimension: settings.embeddingDimensions
        ), !local.chunks.isEmpty {
            return (local.chunks, local.vectorHit ? local.vectors : nil)
        }
        guard let remote else { return nil }
        guard let remoteHit = try? await remote.lookup(
            key,
            embeddingModel: settings.embeddingModel,
            embeddingDimension: settings.embeddingDimensions,
            includeDocument: true
        ), !remoteHit.chunks.isEmpty else { return nil }
        let document = remoteHit.document ?? Data("{}".utf8)
        _ = try? store.store(key: key, document: document, chunks: remoteHit.chunks)
        if let vectors = remoteHit.vectors, remoteHit.vectorHit {
            try? store.storeVectors(
                key: key,
                model: settings.embeddingModel,
                dimension: settings.embeddingDimensions,
                vectors: vectors
            )
        }
        return (remoteHit.chunks, remoteHit.vectorHit ? remoteHit.vectors : nil)
    }

    func store(digest: String, document: Data, chunks: [ChunkCacheChunk], vectors: [[Double]]?) throws {
        guard !chunks.isEmpty else { return }
        let key = ChunkCachePolicy.key(contentSHA256: digest, settings: settings)
        let store = ChunkCacheStore(directory: directory, limitBytes: settings.chunkCacheLimitBytes)
        _ = try store.store(key: key, document: document, chunks: chunks)
        if let vectors, vectors.count == chunks.count, settings.embeddingDimensions > 0 {
            try store.storeVectors(
                key: key,
                model: settings.embeddingModel,
                dimension: settings.embeddingDimensions,
                vectors: vectors
            )
        }
    }

    func storeVectors(digest: String, vectors: [[Double]]) throws {
        guard vectors.count > 0, settings.embeddingDimensions > 0 else { return }
        let key = ChunkCachePolicy.key(contentSHA256: digest, settings: settings)
        let store = ChunkCacheStore(directory: directory, limitBytes: settings.chunkCacheLimitBytes)
        try store.storeVectors(
            key: key,
            model: settings.embeddingModel,
            dimension: settings.embeddingDimensions,
            vectors: vectors
        )
    }
}

extension ChunkCacheChunk {
    init(chunk: DoclingService.PythonChunk, source: String, docTitle: String?, authors: [String]?, year: Int?, doi: String?) {
        let boxes = (chunk.bboxes ?? []).map { box in
            ChunkCacheBox(page: box.page, l: box.l, t: box.t, r: box.r, b: box.b, coordOrigin: nil)
        }
        self.init(
            text: chunk.text,
            embeddingText: chunk.embeddingText,
            page: chunk.page,
            pageEnd: chunk.pageEnd ?? chunk.page,
            pages: [chunk.page, chunk.pageEnd].compactMap { $0 }.reduce(into: [Int]()) { pages, page in
                if !pages.contains(page) { pages.append(page) }
            },
            pageLabels: [],
            headings: chunk.headings ?? [],
            bboxes: boxes,
            docTitle: docTitle,
            authors: authors ?? [],
            year: year,
            doi: doi,
            source: source,
            contentType: chunk.contentType ?? "text",
            chunkIndex: chunk.chunkIndex,
            tokenCount: chunk.tokenCount,
            pictureDescription: chunk.pictureDescription,
            pictureClass: chunk.pictureClass,
            tableMarkdown: chunk.tableMarkdown
        )
    }

    func pythonChunk() -> DoclingService.PythonChunk? {
        let boxes: [DoclingService.ProvenanceBox] = bboxes.compactMap { box in
            guard let l = box.l, let t = box.t, let r = box.r, let b = box.b else { return nil }
            return DoclingService.ProvenanceBox(page: box.page, l: l, t: t, r: r, b: b)
        }
        return DoclingService.PythonChunk(
            text: text,
            embeddingText: embeddingText,
            page: page,
            headings: headings,
            contentType: contentType,
            chunkIndex: chunkIndex,
            tokenCount: tokenCount,
            pictureDescription: pictureDescription,
            pictureClass: pictureClass,
            tableMarkdown: tableMarkdown,
            pageEnd: pageEnd,
            bboxes: boxes.isEmpty ? nil : boxes
        )
    }
}
