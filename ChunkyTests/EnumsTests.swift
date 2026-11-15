import Testing

@testable import Chunky

struct EnumsTests {

    @Test func viewModeValues() {
        #expect(ViewMode.queue.rawValue == "Queue")
        #expect(ViewMode.collections.rawValue == "Collections")
        #expect(ViewMode.retrieval.rawValue == "Retrieval")
        #expect(ViewMode.eval.rawValue == "Eval")
        #expect(ViewMode.analytics.rawValue == "Analytics")
        #expect(ViewMode.benchmark.rawValue == "Benchmark")
        #expect(ViewMode.allCases.count == 6)
    }

    @Test func processingModeValues() {
        #expect(ProcessingMode.chunkOnly.rawValue == "Chunk Only")
        #expect(ProcessingMode.full.rawValue == "Chunk & Ingest")
        #expect(ProcessingMode.allCases.count == 2)
    }

    @Test func exportFormatValues() {
        #expect(ExportFormat.docling.displayName == "Markdown")
        #expect(ExportFormat.html.displayName == "HTML")
        #expect(ExportFormat.json.displayName == "JSON")
        #expect(ExportFormat.none.displayName == "None")
        #expect(ExportFormat.text.displayName == "Plain Text")
        #expect(ExportFormat.allCases.count == 6)
    }

    @Test func exportFormatRawValues() {
        #expect(ExportFormat.docling.rawValue == "docling")
        #expect(ExportFormat.html.rawValue == "html")
        #expect(ExportFormat.json.rawValue == "json")
        #expect(ExportFormat.none.rawValue == "none")
        #expect(ExportFormat.text.rawValue == "text")
    }

    @Test func exportFormatDescriptions() {
        #expect(ExportFormat.docling.description == "Native docling layout (image mode from settings)")
        #expect(ExportFormat.html.description == "HTML document with styling")
        #expect(ExportFormat.json.description == "Structured data with all metadata")
        #expect(ExportFormat.none.description == "No file export")
        #expect(ExportFormat.text.description == "Plain text, minimal formatting")
    }

    @Test func jobStatusAllCases() {
        let statuses: [JobStatus] = [
            .pending, .chunking, .embedding, .uploading, .completed, .failed,
        ]
        #expect(statuses.count == 6)
    }

    @Test func jobTypeAllCases() {
        let types: [JobType] = [.pdf, .chunkedJSON, .embeddedJSON, .markdown]
        #expect(types.count == 4)
    }

    @Test func acceleratorValues() {
        #expect(Accelerator.auto.displayName == "AUTO")
        #expect(Accelerator.cpu.displayName == "CPU")
        #expect(Accelerator.mps.displayName == "MPS")
        #expect(Accelerator.cuda.displayName == "CUDA")
        #expect(Accelerator.allCases.count == 4)
    }

    @Test func tableModeValues() {
        #expect(TableMode.fast.displayName == "Fast")
        #expect(TableMode.accurate.displayName == "Accurate")
        #expect(TableMode.allCases.count == 2)
    }

    @Test func compressionValues() {
        #expect(Compression.none.displayName == "None")
        #expect(Compression.scalar.displayName == "Scalar (Int8)")
        #expect(Compression.binary.displayName == "Binary")
        #expect(Compression.allCases.count == 3)
    }

    @Test func distanceMetricValues() {
        #expect(DistanceMetric.cosine.rawValue == "Cosine")
        #expect(DistanceMetric.dot.rawValue == "Dot")
        #expect(DistanceMetric.euclidean.rawValue == "Euclid")
        #expect(DistanceMetric.allCases.count == 3)
    }

    @Test func distanceMetricDisplayNames() {
        #expect(DistanceMetric.cosine.displayName == "Cosine")
        #expect(DistanceMetric.dot.displayName == "Dot Product")
        #expect(DistanceMetric.euclidean.displayName == "Euclidean")
    }

    @Test func distanceMetricDescriptions() {
        #expect(DistanceMetric.cosine.description == "Best for text search (default)")
        #expect(DistanceMetric.dot.description == "Faster, use if model recommends")
        #expect(DistanceMetric.euclidean.description == "For geometric similarity")
    }

    @Test func doclingModelValues() {
        #expect(DoclingModel.standard.rawValue == "standard")
        #expect(DoclingModel.graniteDoclingMLX.rawValue == "granite-docling-mlx")
        #expect(DoclingModel.allCases.count == 5)
    }

    @Test func doclingModelDescription() {
        for model in DoclingModel.allCases {
            #expect(!model.description.isEmpty)
        }
    }

    @Test func imageExportModeValues() {
        #expect(ImageExportMode.embedded.rawValue == "embedded")
        #expect(ImageExportMode.placeholder.rawValue == "placeholder")
        #expect(ImageExportMode.referenced.rawValue == "referenced")
        #expect(ImageExportMode.allCases.count == 3)
    }

    @Test func imageExportModeDisplayNames() {
        #expect(ImageExportMode.embedded.displayName == "Embedded")
        #expect(ImageExportMode.placeholder.displayName == "Placeholder")
        #expect(ImageExportMode.referenced.displayName == "Referenced")
    }

    @Test func imageExportModeDescriptions() {
        #expect(ImageExportMode.embedded.description == "Base64 images embedded in markdown")
        #expect(ImageExportMode.placeholder.description == "Image placeholders only")
        #expect(ImageExportMode.referenced.description == "Images saved as separate files")
    }

    @Test func ocrLanguageValues() {
        #expect(OCRLanguage.english.rawValue == "en")
        #expect(OCRLanguage.french.rawValue == "fr")
        #expect(OCRLanguage.german.rawValue == "de")
        #expect(OCRLanguage.allCases.count == 3)
    }

    @Test func ocrLanguageDisplayNames() {
        #expect(OCRLanguage.english.displayName == "English")
        #expect(OCRLanguage.french.displayName == "French")
        #expect(OCRLanguage.german.displayName == "German")
    }
}
