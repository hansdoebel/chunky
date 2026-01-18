import Foundation

@MainActor
final class DocumentProcessor: ObservableObject {
    func process(job: ProcessingJob, settings: AppSettings, mode: ProcessingMode) async {
        do {
            switch mode {
            case .chunkOnly:
                try await processChunkOnly(job: job, settings: settings)
            case .ingestOnly:
                try await processUploadOnly(job: job, settings: settings)
            case .full:
                try await processFull(job: job, settings: settings)
            case .batch:
                break
            }
            job.complete()
        } catch {
            job.setError(error.localizedDescription)
        }
    }

    func processBatch(jobs: [ProcessingJob], settings: AppSettings, cancellationCheck: () -> Bool)
        async
    {
        var allChunksWithJobs: [(job: ProcessingJob, chunks: [Chunk])] = []
        let chunkingService = ChunkingService()
        let chunkingOptions = ChunkingService.Options(
            maxTokens: settings.maxTokensPerChunk,
            model: settings.doclingModel,
            workers: settings.doclingWorkers,
            accelerator: settings.doclingAccelerator,
            timeout: settings.doclingTimeout,
            maxPages: settings.doclingMaxPages,
            doTableExtraction: settings.doTableExtraction,
            tableMode: settings.tableMode,
            doOCR: settings.doOCR,
            exportFormat: settings.exportFormat,
            exportFolder: settings.exportFolder
        )

        for (index, job) in jobs.enumerated() {
            if cancellationCheck() { return }

            let chunks: [Chunk]
            if job.isFromJSON, let preloaded = job.preloadedChunks {
                chunks = preloaded
                job.chunksCount = chunks.count
                job.status = .chunking
                job.updateProgress(1.0, message: "Loaded \(chunks.count) chunks")
            } else if job.hasEmbeddings, let embedded = job.preloadedEmbeddings {
                job.status = .uploading
                job.chunksCount = embedded.count
                job.embeddedCount = embedded.count
                let embeddedChunks = embedded.map { e in
                    Chunk(
                        id: e.id,
                        text: e.payload.text,
                        metadata: ChunkMetadata(
                            chunkIndex: 0,
                            source: e.payload.source,
                            headings: e.payload.headings,
                            page: e.payload.page
                        )
                    )
                }
                allChunksWithJobs.append((job, embeddedChunks))
                continue
            } else {
                job.status = .chunking
                let progress = Double(index) / Double(jobs.count) * 0.3
                job.updateProgress(progress, message: "Chunking...")

                do {
                    chunks = try await chunkingService.chunk(
                        documentURL: job.sourceURL, options: chunkingOptions)
                    job.chunksCount = chunks.count
                    job.updateProgress(progress + 0.05, message: "Chunked \(chunks.count) pieces")
                } catch {
                    job.setError(error.localizedDescription)
                    continue
                }
            }

            if chunks.isEmpty {
                job.setError("Document produced no chunks")
                continue
            }

            allChunksWithJobs.append((job, chunks))
        }

        if cancellationCheck() { return }

        let allChunks = allChunksWithJobs.flatMap { $0.chunks }
        if allChunks.isEmpty {
            for (job, _) in allChunksWithJobs {
                job.setError("No chunks to process")
            }
            return
        }

        for (job, _) in allChunksWithJobs {
            job.status = .embedding
            job.updateProgress(0.3, message: "Embedding all chunks...")
        }

        let embeddingService: EmbeddingService
        let detectedDimensions: Int
        do {
            embeddingService = try EmbeddingService(
                baseURL: settings.ollamaURL,
                model: settings.embeddingModel,
                batchSize: settings.embeddingBatchSize,
                concurrency: settings.embeddingConcurrency
            )
            detectedDimensions = try await embeddingService.detectDimensions()
            print("[Chunky] Batch: Detected embedding dimensions: \(detectedDimensions)")
        } catch {
            for (job, _) in allChunksWithJobs {
                job.setError("Embedding service error: \(error.localizedDescription)")
            }
            return
        }

        if cancellationCheck() { return }

        let allTexts = allChunks.map { $0.text }
        let allEmbeddings: [[Float]]
        do {
            allEmbeddings = try await embeddingService.embed(texts: allTexts) { completed, total in
                await MainActor.run {
                    let progress = 0.3 + (Double(completed) / Double(total)) * 0.4
                    for (job, _) in allChunksWithJobs {
                        job.updateProgress(
                            progress, message: "Embedding batch \(completed)/\(total)...")
                    }
                }
            }
        } catch {
            for (job, _) in allChunksWithJobs {
                job.setError("Embedding error: \(error.localizedDescription)")
            }
            return
        }

        if cancellationCheck() { return }

        var embeddingIndex = 0
        var allChunksWithEmbeddings: [ChunkWithEmbedding] = []
        for (job, chunks) in allChunksWithJobs {
            job.embeddedCount = chunks.count
            for chunk in chunks {
                let vector = allEmbeddings[embeddingIndex]
                allChunksWithEmbeddings.append(
                    ChunkWithEmbedding(
                        id: chunk.id,
                        vector: vector,
                        payload: ChunkPayload(
                            text: chunk.text,
                            source: chunk.metadata.source,
                            page: chunk.metadata.page,
                            headings: chunk.metadata.headings
                        )
                    ))
                embeddingIndex += 1
            }
        }

        for (job, _) in allChunksWithJobs {
            job.status = .uploading
            job.updateProgress(0.7, message: "Uploading to Qdrant...")
        }

        let qdrantService = QdrantService(
            qdrantURL: settings.qdrantURL,
            apiKey: settings.qdrantAPIKey,
            timeout: settings.qdrantTimeout,
            poolSize: settings.qdrantPoolSize,
            batchSize: settings.qdrantBatchSize,
            compression: settings.qdrantCompression,
            dimensions: detectedDimensions
        )

        do {
            try await qdrantService.upload(
                chunks: allChunksWithEmbeddings,
                collection: settings.defaultCollection
            ) { completed, total in
                await MainActor.run {
                    let progress = 0.7 + (Double(completed) / Double(total)) * 0.3
                    for (job, _) in allChunksWithJobs {
                        job.updateProgress(
                            progress, message: "Uploading batch \(completed)/\(total)...")
                    }
                }
            }

            for (job, _) in allChunksWithJobs {
                job.complete()
            }
        } catch {
            for (job, _) in allChunksWithJobs {
                job.setError("Upload error: \(error.localizedDescription)")
            }
        }
    }

    private func processChunkOnly(job: ProcessingJob, settings: AppSettings) async throws {
        job.status = .chunking
        job.updateProgress(0.1, message: "Chunking PDF...")

        let chunkingService = ChunkingService()
        let chunkingOptions = ChunkingService.Options(
            maxTokens: settings.maxTokensPerChunk,
            model: settings.doclingModel,
            workers: settings.doclingWorkers,
            accelerator: settings.doclingAccelerator,
            timeout: settings.doclingTimeout,
            maxPages: settings.doclingMaxPages,
            doTableExtraction: settings.doTableExtraction,
            tableMode: settings.tableMode,
            doOCR: settings.doOCR,
            exportFormat: settings.exportFormat,
            exportFolder: settings.exportFolder
        )

        let chunks = try await chunkingService.chunk(
            documentURL: job.sourceURL,
            options: chunkingOptions
        )

        job.chunksCount = chunks.count
        job.updateProgress(0.9, message: "Saved \(chunks.count) chunks")

        if chunks.isEmpty {
            throw ProcessingError.noChunksGenerated
        }
    }

    private func processUploadOnly(job: ProcessingJob, settings: AppSettings) async throws {
        let chunksWithEmbeddings: [ChunkWithEmbedding]
        var detectedDimensions: Int?

        if let preloaded = job.preloadedEmbeddings {
            chunksWithEmbeddings = preloaded
            job.chunksCount = chunksWithEmbeddings.count
            job.embeddedCount = chunksWithEmbeddings.count
            detectedDimensions = preloaded.first?.vector.count
        } else if let chunks = job.preloadedChunks {
            job.status = .embedding
            job.chunksCount = chunks.count
            job.updateProgress(0.05, message: "Detecting embedding dimensions...")

            let embeddingService = try EmbeddingService(
                baseURL: settings.ollamaURL,
                model: settings.embeddingModel,
                batchSize: settings.embeddingBatchSize,
                concurrency: settings.embeddingConcurrency
            )

            detectedDimensions = try await embeddingService.detectDimensions()
            print("[Chunky] Detected embedding dimensions: \(detectedDimensions!)")

            job.updateProgress(0.1, message: "Embedding \(chunks.count) chunks...")

            let texts = chunks.map { $0.text }
            let embeddings = try await embeddingService.embed(texts: texts) { completed, total in
                await MainActor.run {
                    job.embeddedCount = completed * settings.embeddingBatchSize
                    let progress = 0.1 + (Double(completed) / Double(total)) * 0.5
                    job.updateProgress(progress, message: "Embedding chunks...")
                }
            }

            job.embeddedCount = chunks.count
            chunksWithEmbeddings = zip(chunks, embeddings).map { chunk, vector in
                ChunkWithEmbedding(
                    id: chunk.id,
                    vector: vector,
                    payload: ChunkPayload(
                        text: chunk.text,
                        source: chunk.metadata.source,
                        page: chunk.metadata.page,
                        headings: chunk.metadata.headings
                    )
                )
            }
        } else {
            throw ProcessingError.invalidSettings("No chunks to upload")
        }

        if chunksWithEmbeddings.isEmpty {
            throw ProcessingError.noChunksGenerated
        }

        let dimensions = detectedDimensions ?? settings.embeddingDimensions

        job.status = .uploading
        job.updateProgress(0.6, message: "Uploading to Qdrant...")

        let qdrantService = QdrantService(
            qdrantURL: settings.qdrantURL,
            apiKey: settings.qdrantAPIKey,
            timeout: settings.qdrantTimeout,
            poolSize: settings.qdrantPoolSize,
            batchSize: settings.qdrantBatchSize,
            compression: settings.qdrantCompression,
            dimensions: dimensions
        )

        try await qdrantService.upload(
            chunks: chunksWithEmbeddings,
            collection: settings.defaultCollection
        ) { completed, total in
            await MainActor.run {
                let progress = 0.6 + (Double(completed) / Double(total)) * 0.4
                job.updateProgress(progress, message: "Uploading batch \(completed)/\(total)...")
            }
        }
    }

    private func processFull(job: ProcessingJob, settings: AppSettings) async throws {
        let chunks: [Chunk]

        if job.isFromJSON, let preloaded = job.preloadedChunks {
            chunks = preloaded
            job.chunksCount = chunks.count
            job.updateProgress(0.3, message: "Loaded \(chunks.count) chunks from JSON")
        } else if job.hasEmbeddings, let embedded = job.preloadedEmbeddings {
            job.status = .uploading
            job.chunksCount = embedded.count
            job.embeddedCount = embedded.count
            job.updateProgress(0.7, message: "Uploading to Qdrant...")

            let dimensions = embedded.first?.vector.count ?? settings.embeddingDimensions

            let qdrantService = QdrantService(
                qdrantURL: settings.qdrantURL,
                apiKey: settings.qdrantAPIKey,
                timeout: settings.qdrantTimeout,
                poolSize: settings.qdrantPoolSize,
                batchSize: settings.qdrantBatchSize,
                compression: settings.qdrantCompression,
                dimensions: dimensions
            )

            try await qdrantService.upload(
                chunks: embedded,
                collection: settings.defaultCollection
            ) { completed, total in
                await MainActor.run {
                    let progress = 0.7 + (Double(completed) / Double(total)) * 0.3
                    job.updateProgress(
                        progress, message: "Uploading batch \(completed)/\(total)...")
                }
            }
            return
        } else {
            job.status = .chunking
            job.updateProgress(0.1, message: "Chunking PDF...")

            let chunkingService = ChunkingService()
            let chunkingOptions = ChunkingService.Options(
                maxTokens: settings.maxTokensPerChunk,
                model: settings.doclingModel,
                workers: settings.doclingWorkers,
                accelerator: settings.doclingAccelerator,
                timeout: settings.doclingTimeout,
                maxPages: settings.doclingMaxPages,
                doTableExtraction: settings.doTableExtraction,
                tableMode: settings.tableMode,
                doOCR: settings.doOCR,
                exportFormat: settings.exportFormat,
                exportFolder: settings.exportFolder
            )

            chunks = try await chunkingService.chunk(
                documentURL: job.sourceURL,
                options: chunkingOptions
            )

            job.chunksCount = chunks.count
            job.updateProgress(0.3, message: "Chunked into \(chunks.count) pieces")
        }

        if chunks.isEmpty {
            throw ProcessingError.noChunksGenerated
        }

        job.status = .embedding
        job.updateProgress(0.25, message: "Detecting embedding dimensions...")

        let embeddingService = try EmbeddingService(
            baseURL: settings.ollamaURL,
            model: settings.embeddingModel,
            batchSize: settings.embeddingBatchSize,
            concurrency: settings.embeddingConcurrency
        )

        let detectedDimensions = try await embeddingService.detectDimensions()
        print("[Chunky] Detected embedding dimensions: \(detectedDimensions)")

        let texts = chunks.map { $0.text }
        let embeddings = try await embeddingService.embed(texts: texts) { completed, total in
            await MainActor.run {
                job.embeddedCount = completed * settings.embeddingBatchSize
                let progress = 0.3 + (Double(completed) / Double(total)) * 0.4
                job.updateProgress(progress, message: "Embedding chunks...")
            }
        }

        job.embeddedCount = chunks.count
        job.updateProgress(0.7, message: "Uploading to Qdrant...")

        let chunksWithEmbeddings = zip(chunks, embeddings).map { chunk, vector in
            ChunkWithEmbedding(
                id: chunk.id,
                vector: vector,
                payload: ChunkPayload(
                    text: chunk.text,
                    source: chunk.metadata.source,
                    page: chunk.metadata.page,
                    headings: chunk.metadata.headings
                )
            )
        }

        job.status = .uploading
        let qdrantService = QdrantService(
            qdrantURL: settings.qdrantURL,
            apiKey: settings.qdrantAPIKey,
            timeout: settings.qdrantTimeout,
            poolSize: settings.qdrantPoolSize,
            batchSize: settings.qdrantBatchSize,
            compression: settings.qdrantCompression,
            dimensions: detectedDimensions
        )

        try await qdrantService.upload(
            chunks: chunksWithEmbeddings,
            collection: settings.defaultCollection
        ) { completed, total in
            await MainActor.run {
                let progress = 0.7 + (Double(completed) / Double(total)) * 0.3
                job.updateProgress(progress, message: "Uploading batch \(completed)/\(total)...")
            }
        }
    }
}

enum ProcessingError: Error, LocalizedError {
    case noChunksGenerated
    case invalidSettings(String)

    var errorDescription: String? {
        switch self {
        case .noChunksGenerated:
            return "Document produced no chunks. It may be empty or unsupported."
        case .invalidSettings(let detail):
            return "Invalid settings: \(detail)"
        }
    }
}
