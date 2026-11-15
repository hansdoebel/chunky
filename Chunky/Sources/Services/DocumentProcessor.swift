import SwiftUI
import Combine
import CryptoKit
import QdrantCore

// MARK: - DocumentProcessor

class DocumentProcessor: ObservableObject {
    @Published var isProcessing: Bool = false

    weak var appState: AppState?

    private let doclingService = DoclingService()
    private let chunkingService = ChunkingService()
    private var ollamaService: OllamaService?
    private var ollamaServiceURL: String?
    private var currentTask: Task<Void, Never>?
    private var devboxService = DevboxWorkerService()
    private var activeDevboxJobID: String?
    private var devboxBaseURL = ""
    private var devboxToken = ""

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        let jobID = activeDevboxJobID
        let baseURL = devboxBaseURL
        let token = devboxToken
        Task {
            await doclingService.cancel()
            if let jobID, !baseURL.isEmpty {
                await devboxService.cancel(jobID: jobID, baseURL: baseURL, token: token)
            }
        }
    }

    func getOllamaService(baseURL: String) throws -> OllamaService {
        if let service = ollamaService, ollamaServiceURL == baseURL {
            return service
        }
        // Drop the previous client. A call that already holds it can finish;
        // later work uses the new URL instead of the stale host.
        let service = try OllamaService(baseURL: baseURL)
        ollamaService = service
        ollamaServiceURL = baseURL
        return service
    }

    @MainActor
    func process(job: ProcessingJob, settings: AppSettings, mode: ProcessingMode) async {
        if settings.processingHost == .devbox {
            await processOnDevbox(job: job, settings: settings, mode: mode)
            return
        }
        job.status = .chunking
        job.statusMessage = "Converting document with docling..."
        job.error = nil
        job.startTime = Date()
        let jobStart = CFAbsoluteTimeGetCurrent()

        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunky_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            var doclingOptions = DoclingService.ConversionOptions()
            doclingOptions.outputDir = tempDir
            doclingOptions.format = .json
            doclingOptions.maxPages = settings.doclingMaxPages > 0 ? settings.doclingMaxPages : nil
            doclingOptions.enableOCR = settings.doOCR
            doclingOptions.ocrLanguage = settings.ocrLanguage
            doclingOptions.doTableExtraction = settings.doTableExtraction
            doclingOptions.tableMode = settings.tableMode == "accurate" ? .accurate : .fast
            // Map accelerator setting - default to CPU to avoid Metal/GPU crashes
            doclingOptions.accelerator = DoclingService.Accelerator(rawValue: settings.doclingAccelerator) ?? .cpu
            doclingOptions.vlmModel = settings.doclingModel
            doclingOptions.ollamaURL = settings.ollamaURL
            // Enrichment options
            doclingOptions.imageExportMode = DoclingService.ImageExportMode(rawValue: settings.imageExportMode) ?? .embedded
            doclingOptions.doFormulaEnrichment = settings.doFormulaEnrichment
            doclingOptions.doCodeEnrichment = settings.doCodeEnrichment
            doclingOptions.doChartExtraction = settings.doChartExtraction
            doclingOptions.doPictureDescription = settings.doPictureDescription
            doclingOptions.doPictureClassification = settings.doPictureClassification
            doclingOptions.pictureDescriptionPreset = settings.resolvedPictureDescriptionPreset
            doclingOptions.vlmServerURL = settings.vlmServerURL
            doclingOptions.layoutModel = settings.layoutModel
            doclingOptions.workers = settings.doclingWorkers
            doclingOptions.ocrBatchSize = settings.ocrBatchSize
            doclingOptions.layoutBatchSize = settings.layoutBatchSize
            doclingOptions.tableBatchSize = settings.tableBatchSize
            doclingOptions.timeout = settings.doclingTimeout
            if settings.doStructuredExtraction && !settings.extractionSchemaPath.isEmpty {
                doclingOptions.extractionSchemaPath = settings.extractionSchemaPath
            }

            doclingOptions.enableChunking = true
            doclingOptions.chunkMaxTokens = settings.maxTokensPerChunk
            doclingOptions.chunkMergePeers = settings.chunkMergePeers
            doclingOptions.chunkTokenizer = settings.chunkTokenizer
            doclingOptions.useDaemon = settings.useDaemonMode

            let convertStart = CFAbsoluteTimeGetCurrent()
            let result = try await doclingService.convert(
                inputURL: job.sourceURL,
                options: doclingOptions
            ) { [weak job] message, percent in
                Task { @MainActor in
                    job?.statusMessage = message
                    if let percent = percent {
                        job?.progress = percent / 100.0
                    }
                }
            }
            job.conversionTime = CFAbsoluteTimeGetCurrent() - convertStart
            try Task.checkCancellation()

            guard let outputPath = result.outputFile else {
                throw QdrantError.operationFailed("Docling did not produce output file")
            }

            let chunkStart = CFAbsoluteTimeGetCurrent()
            job.statusMessage = "Chunking document..."

            var chunks: [ChunkingService.DocumentChunk]

            if let pythonChunks = result.chunks, !pythonChunks.isEmpty {
                let documentId = UUID().uuidString
                chunks = pythonChunks.map { pc in
                    ChunkingService.DocumentChunk(
                        text: pc.text,
                        source: job.fileName,
                        page: pc.page,
                        headings: pc.headings ?? [],
                        tokenCount: pc.tokenCount,
                        formattedContent: pc.embeddingText,
                        chunkIndex: pc.chunkIndex,
                        contentType: pc.contentType ?? "text",
                        section: (pc.headings ?? []).last,
                        docTitle: result.docTitle,
                        authors: result.authors,
                        doi: result.doi,
                        documentId: documentId,
                        url: result.docURL,
                        year: result.year,
                        language: result.language,
                        embeddingText: pc.embeddingText,
                        pictureDescription: pc.pictureDescription,
                        pictureClass: pc.pictureClass,
                        tableMarkdown: pc.tableMarkdown
                    )
                }
            } else {
                var chunkOptions = ChunkingService.ChunkingOptions()
                chunkOptions.maxTokensPerChunk = settings.maxTokensPerChunk
                chunkOptions.overlapTokens = settings.chunkOverlap
                let isVLMMode = settings.doclingModel != "standard"
                chunkOptions.includeTableContent = settings.doTableExtraction || isVLMMode

                chunks = try await chunkingService.chunkDoclingJSON(
                    fileURL: URL(fileURLWithPath: outputPath),
                    source: job.fileName,
                    options: chunkOptions
                )
            }

            if settings.doTextCleanup {
                let cleanupService = CleanupService()
                chunks = cleanupService.cleanup(chunks)
            }

            job.chunkingTime = CFAbsoluteTimeGetCurrent() - chunkStart
            job.chunksCount = chunks.count
            try Task.checkCancellation()

            if mode == .chunkOnly {
                // Export chunks to the user's selected export folder
                let format = ExportFormat(rawValue: settings.exportFormat) ?? .json

                // Skip export if format is none
                if format == .none {
                    try? FileManager.default.removeItem(at: tempDir)
                    job.status = .completed
                    job.statusMessage = "Chunked \(chunks.count) chunks (no export)"
                    return
                }

                job.statusMessage = "Exporting chunks..."

                let exportDir: URL
                if !settings.exportFolder.isEmpty {
                    exportDir = URL(fileURLWithPath: settings.exportFolder)
                } else {
                    // Fallback to Desktop if no export folder set
                    exportDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? tempDir
                }

                // Ensure export directory exists
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

                // Export in the selected format, respecting metadata settings
                let fileExtension: String
                let exportData: Data
                let timestamp = ISO8601DateFormatter().string(from: Date())

                switch format {
                case .none:
                    // Already handled above, but needed for exhaustive switch
                    fatalError("Unreachable")

                case .docling:
                    fileExtension = "md"
                    let imageMode = ImageExportMode(rawValue: settings.imageExportMode) ?? .embedded
                    let includeImages = imageMode != .placeholder
                    job.statusMessage = "Exporting Markdown..."

                    var mdOptions = DoclingService.ConversionOptions()
                    mdOptions.outputDir = tempDir
                    mdOptions.format = includeImages ? .markdownWithImages : .markdownNoImages
                    mdOptions.maxPages = settings.doclingMaxPages > 0 ? settings.doclingMaxPages : nil
                    mdOptions.enableOCR = settings.doOCR
                    mdOptions.ocrLanguage = settings.ocrLanguage
                    mdOptions.doTableExtraction = settings.doTableExtraction
                    mdOptions.tableMode = settings.tableMode == "accurate" ? .accurate : .fast
                    mdOptions.accelerator = DoclingService.Accelerator(rawValue: settings.doclingAccelerator) ?? .cpu
                    mdOptions.vlmModel = settings.doclingModel
                    mdOptions.ollamaURL = settings.ollamaURL
                    mdOptions.generateImages = includeImages
                    mdOptions.imageExportMode = DoclingService.ImageExportMode(rawValue: settings.imageExportMode) ?? .embedded
                    mdOptions.doFormulaEnrichment = settings.doFormulaEnrichment
                    mdOptions.doCodeEnrichment = settings.doCodeEnrichment
                    mdOptions.doChartExtraction = settings.doChartExtraction
                    mdOptions.doPictureDescription = settings.doPictureDescription
                    mdOptions.doPictureClassification = settings.doPictureClassification
                    mdOptions.useDaemon = settings.useDaemonMode

                    let mdResult = try await doclingService.convert(
                        inputURL: job.sourceURL,
                        options: mdOptions,
                        onProgress: nil
                    )

                    guard let mdOutputPath = mdResult.outputFile else {
                        throw QdrantError.operationFailed("Markdown export failed")
                    }

                    var mdData = try Data(contentsOf: URL(fileURLWithPath: mdOutputPath))
                    if settings.doTextCleanup, let mdString = String(data: mdData, encoding: .utf8) {
                        let cleaned = CleanupService().cleanText(mdString)
                        mdData = cleaned.data(using: .utf8) ?? mdData
                    }
                    exportData = mdData

                case .json:
                    fileExtension = "json"
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    exportData = try encoder.encode(chunks.map { ChunkExport(chunk: $0, settings: settings) })

                case .text:
                    fileExtension = "txt"
                    var header = "\(job.fileName)\n"
                    header += "Chunks: \(chunks.count)\n"
                    if settings.metadataIncludeTimestamp {
                        header += "Generated: \(timestamp)\n"
                    }
                    header += String(repeating: "=", count: 40) + "\n\n"

                    let text = chunks.enumerated().map { index, chunk in
                        var txt = "=== Chunk \(index + 1) ===\n"
                        if settings.metadataIncludeHeadings && !chunk.headings.isEmpty {
                            txt += "Headings: \(chunk.headings.joined(separator: " > "))\n"
                        }
                        if settings.metadataIncludePageNumber, let page = chunk.page {
                            txt += "Page: \(page)\n"
                        }
                        txt += "\n\(chunk.text)\n"
                        return txt
                    }.joined(separator: "\n\n")
                    exportData = (header + text).data(using: .utf8) ?? Data()

                case .doctags:
                    fileExtension = "doctags"
                    job.statusMessage = "Exporting DocTags..."

                    var dtOptions = DoclingService.ConversionOptions()
                    dtOptions.outputDir = tempDir
                    dtOptions.format = .doctags
                    dtOptions.maxPages = settings.doclingMaxPages > 0 ? settings.doclingMaxPages : nil
                    dtOptions.enableOCR = settings.doOCR
                    dtOptions.ocrLanguage = settings.ocrLanguage
                    dtOptions.doTableExtraction = settings.doTableExtraction
                    dtOptions.tableMode = settings.tableMode == "accurate" ? .accurate : .fast
                    dtOptions.accelerator = DoclingService.Accelerator(rawValue: settings.doclingAccelerator) ?? .cpu
                    dtOptions.vlmModel = settings.doclingModel
                    dtOptions.ollamaURL = settings.ollamaURL
                    dtOptions.doFormulaEnrichment = settings.doFormulaEnrichment
                    dtOptions.doCodeEnrichment = settings.doCodeEnrichment
                    dtOptions.doChartExtraction = settings.doChartExtraction
                    dtOptions.doPictureDescription = settings.doPictureDescription
                    dtOptions.doPictureClassification = settings.doPictureClassification
                    dtOptions.useDaemon = settings.useDaemonMode

                    let dtResult = try await doclingService.convert(
                        inputURL: job.sourceURL,
                        options: dtOptions,
                        onProgress: nil
                    )

                    guard let dtOutputPath = dtResult.outputFile else {
                        throw QdrantError.operationFailed("DocTags export failed")
                    }

                    exportData = try Data(contentsOf: URL(fileURLWithPath: dtOutputPath))

                case .html:
                    fileExtension = "html"
                    job.statusMessage = "Exporting HTML..."

                    var htmlOptions = DoclingService.ConversionOptions()
                    htmlOptions.outputDir = tempDir
                    htmlOptions.format = .html
                    htmlOptions.maxPages = settings.doclingMaxPages > 0 ? settings.doclingMaxPages : nil
                    htmlOptions.enableOCR = settings.doOCR
                    htmlOptions.ocrLanguage = settings.ocrLanguage
                    htmlOptions.doTableExtraction = settings.doTableExtraction
                    htmlOptions.tableMode = settings.tableMode == "accurate" ? .accurate : .fast
                    htmlOptions.accelerator = DoclingService.Accelerator(rawValue: settings.doclingAccelerator) ?? .cpu
                    htmlOptions.vlmModel = settings.doclingModel
                    htmlOptions.ollamaURL = settings.ollamaURL
                    htmlOptions.doFormulaEnrichment = settings.doFormulaEnrichment
                    htmlOptions.doCodeEnrichment = settings.doCodeEnrichment
                    htmlOptions.doChartExtraction = settings.doChartExtraction
                    htmlOptions.doPictureDescription = settings.doPictureDescription
                    htmlOptions.doPictureClassification = settings.doPictureClassification
                    htmlOptions.useDaemon = settings.useDaemonMode

                    let htmlResult = try await doclingService.convert(
                        inputURL: job.sourceURL,
                        options: htmlOptions,
                        onProgress: nil
                    )

                    guard let htmlOutputPath = htmlResult.outputFile else {
                        throw QdrantError.operationFailed("HTML export failed")
                    }

                    exportData = try Data(contentsOf: URL(fileURLWithPath: htmlOutputPath))
                }

                let exportURL = exportDir.appendingPathComponent("\(job.fileName)_chunks.\(fileExtension)")
                try exportData.write(to: exportURL)

                // Cleanup temp directory
                try? FileManager.default.removeItem(at: tempDir)

                job.status = .completed
                job.statusMessage = "Exported \(chunks.count) chunks to \(exportDir.lastPathComponent)"
                return
            }

            // Step 3+4: Embed and upload
            job.status = .embedding
            job.statusMessage = "Generating embeddings..."

            let ollama = try getOllamaService(baseURL: settings.ollamaURL)

            let isAvailable = await ollama.isAvailable()
            if !isAvailable {
                throw QdrantError.operationFailed("Ollama is not running at \(settings.ollamaURL)")
            }

            let distance: Distance
            switch settings.qdrantDistanceMetric {
            case "Dot": distance = .dot
            case "Euclid": distance = .euclid
            default: distance = .cosine
            }

            let quantizationConfig: QuantizationConfig?
            switch settings.qdrantCompression {
            case "Scalar": quantizationConfig = .scalar(quantile: nil, alwaysRam: true)
            case "Binary": quantizationConfig = .binary(alwaysRam: true)
            default: quantizationConfig = nil
            }

            let ingestedAt = ISO8601DateFormatter().string(from: Date())
            let embedStart = CFAbsoluteTimeGetCurrent()

            if settings.streamingPipeline {
                try await processStreaming(
                    job: job,
                    chunks: chunks,
                    settings: settings,
                    ollama: ollama,
                    distance: distance,
                    quantizationConfig: quantizationConfig,
                    ingestedAt: ingestedAt
                )
            } else {
                try await processSequential(
                    job: job,
                    chunks: chunks,
                    settings: settings,
                    ollama: ollama,
                    distance: distance,
                    quantizationConfig: quantizationConfig,
                    ingestedAt: ingestedAt
                )
            }

            let embedUploadTime = CFAbsoluteTimeGetCurrent() - embedStart
            job.embeddingTime = embedUploadTime
            job.totalTime = CFAbsoluteTimeGetCurrent() - jobStart

            try? FileManager.default.removeItem(at: tempDir)

            let timing = job.timingSummary ?? ""
            job.statusMessage = "\(chunks.count) chunks | \(timing)"
            job.status = .completed

        } catch is CancellationError {
            job.status = .failed
            job.error = "Cancelled"
            job.statusMessage = "Cancelled"
        } catch {
            job.status = .failed
            job.error = error.localizedDescription
            job.statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func contentHash(text: String, model: String) -> String {
        let input = text + "|" + model
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func buildPoints(
        chunks: [ChunkingService.DocumentChunk],
        embeddings: [[Float]],
        sparseVectors: [SparseVector?],
        settings: AppSettings,
        ingestedAt: String
    ) -> [ChunkPoint] {
        zip(chunks, zip(embeddings, sparseVectors)).map { chunk, pair in
            let (embedding, sparse) = pair
            var metadata: [String: String] = [:]
            if settings.metadataIncludeChunkIndex { metadata["chunk_index"] = String(chunk.chunkIndex) }
            if settings.metadataIncludeContentType { metadata["content_type"] = chunk.contentType }
            if settings.metadataIncludeSection, let s = chunk.section { metadata["section"] = s }
            if settings.metadataIncludeDocTitle, let t = chunk.docTitle { metadata["doc_title"] = t }
            if settings.metadataIncludeAuthors, let a = chunk.authors, !a.isEmpty { metadata["authors"] = a.joined(separator: "; ") }
            if settings.metadataIncludeDOI, let d = chunk.doi { metadata["doi"] = d }
            if settings.metadataIncludeDocumentId, let d = chunk.documentId { metadata["document_id"] = d }
            if settings.metadataIncludeURL, let u = chunk.url { metadata["url"] = u }
            if settings.metadataIncludeLanguage, let l = chunk.language { metadata["language"] = l }
            if settings.metadataIncludeTimestamp { metadata["ingested_at"] = ingestedAt }
            if settings.enableEmbeddingCache {
                metadata["content_hash"] = contentHash(text: chunk.embeddingText ?? chunk.text, model: settings.embeddingModel)
            }
            if let embeddingText = chunk.embeddingText, !embeddingText.isEmpty {
                metadata["embedding_text"] = embeddingText
            }
            if let pictureDescription = chunk.pictureDescription, !pictureDescription.isEmpty {
                metadata["picture_description"] = pictureDescription
            }
            if let pictureClass = chunk.pictureClass, !pictureClass.isEmpty {
                metadata["picture_class"] = pictureClass
            }
            if let tableMarkdown = chunk.tableMarkdown, !tableMarkdown.isEmpty {
                metadata["table_markdown"] = tableMarkdown
            }
            let storedText = (chunk.embeddingText?.isEmpty == false) ? chunk.embeddingText! : chunk.text
            return ChunkPoint(
                id: chunk.id,
                vector: embedding,
                sparseVector: sparse,
                text: storedText,
                source: chunk.source,
                page: chunk.page,
                headings: chunk.headings,
                year: settings.metadataIncludeYear ? chunk.year : nil,
                metadata: metadata
            )
        }
    }

    @MainActor
    private func processSequential(
        job: ProcessingJob,
        chunks: [ChunkingService.DocumentChunk],
        settings: AppSettings,
        ollama: OllamaService,
        distance: Distance,
        quantizationConfig: QuantizationConfig?,
        ingestedAt: String
    ) async throws {
        var chunksToEmbed = chunks
        var cachedPoints: [ChunkPoint] = []
        var cachedHashes: Set<String>? = nil

        if settings.enableEmbeddingCache, let appState = appState, let qdrant = appState.qdrantService {
            let collectionName = settings.defaultCollection
            let exists = try? await qdrant.collectionExists(collectionName)
            if exists == true {
                job.statusMessage = "Checking embedding cache..."
                let existingPoints = try await qdrant.loadPointsBySource(
                    collectionName: collectionName,
                    source: job.fileName
                )

                var hashToPoint: [String: QdrantPoint] = [:]
                for point in existingPoints {
                    if let hash = point.metadata["content_hash"] {
                        hashToPoint[hash] = point
                    }
                }

                if !hashToPoint.isEmpty {
                    var needsEmbedding: [ChunkingService.DocumentChunk] = []
                    var skippedHashes = Set<String>()

                    for chunk in chunks {
                        let hash = contentHash(text: chunk.embeddingText ?? chunk.text, model: settings.embeddingModel)
                        if let existingPoint = hashToPoint[hash] {
                            cachedPoints.append(ChunkPoint(
                                id: existingPoint.id,
                                vector: [],
                                text: existingPoint.text,
                                source: existingPoint.source,
                                page: existingPoint.page,
                                headings: existingPoint.headings,
                                metadata: existingPoint.metadata
                            ))
                            skippedHashes.insert(hash)
                        } else {
                            needsEmbedding.append(chunk)
                        }
                    }

                    if !skippedHashes.isEmpty {
                        job.statusMessage = "Cache hit: \(skippedHashes.count) chunks, embedding \(needsEmbedding.count) new..."
                        cachedHashes = skippedHashes
                        chunksToEmbed = needsEmbedding
                    }
                }
            }
        }

        var allPoints: [ChunkPoint] = []

        if !chunksToEmbed.isEmpty {
            let vectorSize = try await probedVectorSize(settings: settings, ollama: ollama)
            let texts = chunksToEmbed.map { $0.embeddingText ?? $0.text }

            let embeddings = try await ollama.embedWithProgress(
                texts: texts,
                model: settings.embeddingModel,
                batchSize: settings.embeddingBatchSize,
                concurrency: settings.embeddingConcurrency
            ) { [weak job] completed, total in
                Task { @MainActor in
                    job?.progress = Double(completed) / Double(total)
                    job?.statusMessage = "Embedding batch \(completed)/\(total)..."
                }
            }

            if let actual = embeddings.first?.count, actual != vectorSize {
                throw EmbeddingDimensionError.batchMismatch(
                    model: settings.embeddingModel,
                    probed: vectorSize,
                    actual: actual
                )
            }

            let sparseVectors: [SparseVector?]
            if settings.hybridSearch {
                sparseVectors = SparseVectorService.generateSparseVectors(texts: chunksToEmbed.map { $0.text }).map { Optional($0) }
            } else {
                sparseVectors = Array(repeating: nil, count: chunksToEmbed.count)
            }

            let newPoints = buildPoints(chunks: chunksToEmbed, embeddings: embeddings, sparseVectors: sparseVectors, settings: settings, ingestedAt: ingestedAt)
            allPoints = newPoints

            job.status = .uploading
            job.statusMessage = "Uploading to Qdrant..."

            let dedupSource: String? = cachedHashes != nil ? nil : job.fileName
            try await uploadToQdrant(
                points: newPoints,
                collectionName: settings.defaultCollection,
                vectorSize: vectorSize,
                batchSize: settings.qdrantBatchSize,
                hybrid: settings.hybridSearch,
                distance: distance,
                quantizationConfig: quantizationConfig,
                dedupSource: dedupSource
            ) { progress in
                Task { @MainActor in
                    job.progress = progress.fraction
                    job.statusMessage = "Uploading batch \(progress.currentBatch)/\(progress.totalBatches)..."
                }
            }
        } else {
            job.statusMessage = "All chunks cached, skipping embedding"
        }

        if let hashes = cachedHashes, let appState = appState, let qdrant = appState.qdrantService {
            let existingPoints = try await qdrant.loadPointsBySource(
                collectionName: settings.defaultCollection,
                source: job.fileName
            )
            let staleIds = existingPoints
                .filter { point in
                    guard let hash = point.metadata["content_hash"] else { return true }
                    return !hashes.contains(hash) && !chunksToEmbed.contains(where: {
                        contentHash(text: $0.embeddingText ?? $0.text, model: settings.embeddingModel) == hash
                    })
                }
                .map { $0.id }

            if !staleIds.isEmpty {
                try await qdrant.deletePoints(collectionName: settings.defaultCollection, ids: staleIds)
            }
        }

        job.embeddedCount = allPoints.count + cachedPoints.count
    }

    @MainActor
    private func processStreaming(
        job: ProcessingJob,
        chunks: [ChunkingService.DocumentChunk],
        settings: AppSettings,
        ollama: OllamaService,
        distance: Distance,
        quantizationConfig: QuantizationConfig?,
        ingestedAt: String
    ) async throws {
        guard let appState = appState else { throw QdrantError.notConnected }
        try await appState.ensureQdrantConnection()
        guard let qdrant = appState.qdrantService else { throw QdrantError.notConnected }

        let batchSize = settings.embeddingBatchSize
        let totalBatches = (chunks.count + batchSize - 1) / batchSize

        let vectorSize = try await probedVectorSize(settings: settings, ollama: ollama)
        let firstBatchTexts = Array(chunks.prefix(batchSize)).map { $0.embeddingText ?? $0.text }
        let firstEmbeddings = try await ollama.embedBatch(texts: firstBatchTexts, model: settings.embeddingModel)
        if let actual = firstEmbeddings.first?.count, actual != vectorSize {
            throw EmbeddingDimensionError.batchMismatch(
                model: settings.embeddingModel,
                probed: vectorSize,
                actual: actual
            )
        }

        var createHybrid = settings.hybridSearch
        var createDistance = distance
        if let saved = CollectionPlanStore.load(name: settings.defaultCollection) {
            if saved.vectorSize != vectorSize {
                job.statusMessage = "Collection \(saved.name) was saved with vector size \(saved.vectorSize), but \(settings.embeddingModel) probes \(vectorSize)."
            } else if let warning = saved.mismatch(existingVectorSize: nil, existingHybrid: settings.hybridSearch) {
                job.statusMessage = warning
            }
            createHybrid = saved.hybrid
            switch saved.distance {
            case .cosine: createDistance = .cosine
            case .dot: createDistance = .dot
            case .euclid: createDistance = .euclid
            }
        }
        try await qdrant.createCollectionIfNeeded(
            name: settings.defaultCollection,
            vectorSize: vectorSize,
            hybrid: createHybrid,
            distance: createDistance,
            quantizationConfig: quantizationConfig
        )

        try await qdrant.deleteBySource(
            collectionName: settings.defaultCollection,
            source: job.fileName
        )

        let firstChunkBatch = Array(chunks.prefix(batchSize))
        let firstSparse: [SparseVector?]
        if settings.hybridSearch {
            firstSparse = SparseVectorService.generateSparseVectors(texts: firstChunkBatch.map { $0.text }).map { Optional($0) }
        } else {
            firstSparse = Array(repeating: nil, count: firstChunkBatch.count)
        }
        let firstPoints = buildPoints(chunks: firstChunkBatch, embeddings: firstEmbeddings, sparseVectors: firstSparse, settings: settings, ingestedAt: ingestedAt)
        try await qdrant.upsertPoints(collectionName: settings.defaultCollection, points: firstPoints, batchSize: settings.qdrantBatchSize)

        var embeddedSoFar = firstChunkBatch.count
        job.statusMessage = "Embedding & uploading batch 1/\(totalBatches)..."
        job.progress = 1.0 / Double(totalBatches)

        for batchIndex in 1..<totalBatches {
            try Task.checkCancellation()
            let start = batchIndex * batchSize
            let end = min(start + batchSize, chunks.count)
            let batchChunks = Array(chunks[start..<end])
            let batchTexts = batchChunks.map { $0.embeddingText ?? $0.text }

            let batchEmbeddings = try await ollama.embedBatch(texts: batchTexts, model: settings.embeddingModel)

            let batchSparse: [SparseVector?]
            if settings.hybridSearch {
                batchSparse = SparseVectorService.generateSparseVectors(texts: batchChunks.map { $0.text }).map { Optional($0) }
            } else {
                batchSparse = Array(repeating: nil, count: batchChunks.count)
            }

            let batchPoints = buildPoints(chunks: batchChunks, embeddings: batchEmbeddings, sparseVectors: batchSparse, settings: settings, ingestedAt: ingestedAt)
            try await qdrant.upsertPoints(collectionName: settings.defaultCollection, points: batchPoints, batchSize: settings.qdrantBatchSize)

            embeddedSoFar += batchChunks.count
            job.progress = Double(batchIndex + 1) / Double(totalBatches)
            job.statusMessage = "Embedding & uploading batch \(batchIndex + 1)/\(totalBatches)..."
        }

        job.embeddedCount = embeddedSoFar
    }

    func processBatch(
        jobs: [ProcessingJob],
        settings: AppSettings,
        mode: ProcessingMode,
        cancellationCheck: () -> Bool
    ) async {
        for job in jobs {
            if cancellationCheck() { break }
            await process(job: job, settings: settings, mode: mode)
        }
    }

    @MainActor
    private func processOnDevbox(job: ProcessingJob, settings: AppSettings, mode: ProcessingMode) async {
        job.status = .chunking
        job.statusMessage = "Uploading to devbox..."
        job.error = nil
        job.startTime = Date()
        let started = CFAbsoluteTimeGetCurrent()
        devboxBaseURL = settings.devboxWorkerURL
        devboxToken = settings.workerToken
        devboxService = DevboxWorkerService()
        let payload = DevboxJobPayload.settings(from: settings, mode: mode)
        do {
            let parsed = try await devboxService.run(
                fileURL: job.sourceURL,
                settings: payload,
                baseURL: settings.devboxWorkerURL,
                token: settings.workerToken,
                onCreated: { [weak self] id in
                    Task { @MainActor in self?.activeDevboxJobID = id }
                },
                onEvent: { [weak job] event in
                    Task { @MainActor in
                        if let message = event.message { job?.statusMessage = message }
                        if let percent = event.percent { job?.progress = min(1, max(0, percent / 100)) }
                    }
                }
            )
            if parsed.status == "failed" {
                if parsed.errorType == "dimension_mismatch" {
                    throw DevboxClientError.dimensionMismatch(
                        url: settings.devboxWorkerURL,
                        detail: parsed.error ?? "The embedding width does not match the collection."
                    )
                }
                throw DevboxClientError.http(url: settings.devboxWorkerURL, status: 200, detail: parsed.error ?? "Job failed")
            }
            if parsed.status == "canceled" {
                job.status = .failed
                job.error = "Cancelled"
                job.statusMessage = "Cancelled"
                return
            }
            job.chunksCount = parsed.chunks.count
            switch payload["ingest_target"] as? String {
            case "qdrant_cloud":
                let count = parsed.ingestUpserted ?? parsed.chunks.count
                job.embeddedCount = count
                job.statusMessage = "Upserted \(count) points to \(parsed.ingestCollection ?? settings.defaultCollection)"
            case "return_vectors":
                try await ingestReturnedVectors(job: job, settings: settings, parsed: parsed)
            default:
                job.statusMessage = "\(parsed.chunks.count) chunks from devbox"
            }
            job.totalTime = CFAbsoluteTimeGetCurrent() - started
            job.status = .completed
        } catch is CancellationError {
            job.status = .failed
            job.error = "Cancelled"
            job.statusMessage = "Cancelled"
        } catch {
            job.status = .failed
            job.error = error.localizedDescription
            job.statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func ingestReturnedVectors(job: ProcessingJob, settings: AppSettings, parsed: ParsedWorkerJob) async throws {
        guard parsed.embeddings.count == parsed.chunks.count, !parsed.embeddings.isEmpty else {
            throw DevboxClientError.http(
                url: settings.devboxWorkerURL,
                status: 200,
                detail: "Worker did not return one vector per chunk."
            )
        }
        let vectorSize = parsed.embeddingDim ?? parsed.embeddings[0].count
        guard let appState else { throw QdrantError.notConnected }
        try await appState.ensureQdrantConnection()
        guard let qdrant = appState.qdrantService else { throw QdrantError.notConnected }
        if try await qdrant.collectionExists(settings.defaultCollection) {
            let info = try await qdrant.getCollectionInfo(settings.defaultCollection)
            try EmbeddingDimensionError.validate(
                existing: info.vectorSize,
                probed: vectorSize,
                collection: settings.defaultCollection,
                model: settings.embeddingModel
            )
        }
        let documentChunks: [ChunkingService.DocumentChunk] = parsed.chunks.enumerated().map { index, raw in
            ChunkingService.DocumentChunk(
                text: raw["text"] as? String ?? "",
                source: raw["source"] as? String ?? job.fileName,
                page: (raw["page"] as? NSNumber)?.intValue,
                headings: (raw["headings"] as? [Any])?.compactMap { $0 as? String } ?? [],
                chunkIndex: (raw["chunk_index"] as? NSNumber)?.intValue ?? index,
                contentType: raw["content_type"] as? String ?? "text",
                embeddingText: raw["embedding_text"] as? String,
                pictureDescription: raw["picture_description"] as? String,
                pictureClass: raw["picture_class"] as? String,
                tableMarkdown: raw["table_markdown"] as? String
            )
        }
        let points = buildPoints(
            chunks: documentChunks,
            embeddings: parsed.embeddings,
            sparseVectors: Array(repeating: nil, count: documentChunks.count),
            settings: settings,
            ingestedAt: ISO8601DateFormatter().string(from: Date())
        )
        let distance: Distance
        switch settings.qdrantDistanceMetric {
        case "Dot": distance = .dot
        case "Euclid": distance = .euclid
        default: distance = .cosine
        }
        try await uploadToQdrant(
            points: points,
            collectionName: settings.defaultCollection,
            vectorSize: vectorSize,
            batchSize: settings.qdrantBatchSize,
            hybrid: false,
            distance: distance,
            dedupSource: job.fileName
        ) { progress in
            Task { @MainActor in
                job.progress = progress.fraction
                job.statusMessage = "Uploading batch \(progress.currentBatch)/\(progress.totalBatches)..."
            }
        }
        job.embeddedCount = points.count
        job.statusMessage = "\(points.count) chunks written to local Qdrant"
    }

    /// Probe the embedding model once and refuse a collection whose width differs.
    @MainActor
    private func probedVectorSize(settings: AppSettings, ollama: OllamaService) async throws -> Int {
        let probed = try await ollama.probeDimension(model: settings.embeddingModel)
        guard let appState else { return probed }
        try await appState.ensureQdrantConnection()
        guard let qdrant = appState.qdrantService else { return probed }
        if try await qdrant.collectionExists(settings.defaultCollection) {
            let info = try await qdrant.getCollectionInfo(settings.defaultCollection)
            try EmbeddingDimensionError.validate(
                existing: info.vectorSize,
                probed: probed,
                collection: settings.defaultCollection,
                model: settings.embeddingModel
            )
        }
        return probed
    }

    /// Upload embedded chunks to Qdrant
    @MainActor
    func uploadToQdrant(
        points: [ChunkPoint],
        collectionName: String,
        vectorSize: Int,
        batchSize: Int,
        hybrid: Bool = false,
        distance: Distance = .cosine,
        quantizationConfig: QuantizationConfig? = nil,
        dedupSource: String? = nil,
        onProgress: @escaping (UploadProgress) -> Void
    ) async throws {
        guard let appState = appState else {
            throw QdrantError.notConnected
        }

        try await appState.ensureQdrantConnection()

        guard let service = appState.qdrantService else {
            throw QdrantError.notConnected
        }

        try await service.createCollectionIfNeeded(
            name: collectionName,
            vectorSize: vectorSize,
            hybrid: hybrid,
            distance: distance,
            quantizationConfig: quantizationConfig
        )

        if let source = dedupSource {
            try await service.deleteBySource(
                collectionName: collectionName,
                source: source
            )
        }

        try await service.upsertPoints(
            collectionName: collectionName,
            points: points,
            batchSize: batchSize,
            onProgress: onProgress
        )
    }
}

// MARK: - ChunkExport

struct ChunkExport: Codable {
    let id: String
    let text: String
    let source: String?
    let page: Int?
    let headings: [String]?
    let tokenCount: Int
    let timestamp: String?
    let chunkIndex: Int?
    let contentType: String?
    let section: String?
    let docTitle: String?
    let authors: [String]?
    let doi: String?
    let documentId: String?
    let url: String?
    let year: Int?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case id, text, source, page, headings, tokenCount, timestamp
        case chunkIndex = "chunk_index"
        case contentType = "content_type"
        case section
        case docTitle = "doc_title"
        case authors, doi
        case documentId = "document_id"
        case url, year, language
    }

    init(chunk: ChunkingService.DocumentChunk, settings: AppSettings) {
        self.id = chunk.id
        self.text = chunk.text
        self.source = settings.metadataIncludeFilename ? chunk.source : nil
        self.page = settings.metadataIncludePageNumber ? chunk.page : nil
        self.headings = settings.metadataIncludeHeadings ? (chunk.headings.isEmpty ? nil : chunk.headings) : nil
        self.tokenCount = chunk.tokenCount
        self.timestamp = settings.metadataIncludeTimestamp ? ISO8601DateFormatter().string(from: Date()) : nil
        self.chunkIndex = settings.metadataIncludeChunkIndex ? chunk.chunkIndex : nil
        self.contentType = settings.metadataIncludeContentType ? chunk.contentType : nil
        self.section = settings.metadataIncludeSection ? chunk.section : nil
        self.docTitle = settings.metadataIncludeDocTitle ? chunk.docTitle : nil
        self.authors = settings.metadataIncludeAuthors ? chunk.authors : nil
        self.doi = settings.metadataIncludeDOI ? chunk.doi : nil
        self.documentId = settings.metadataIncludeDocumentId ? chunk.documentId : nil
        self.url = settings.metadataIncludeURL ? chunk.url : nil
        self.year = settings.metadataIncludeYear ? chunk.year : nil
        self.language = settings.metadataIncludeLanguage ? chunk.language : nil
    }
}
