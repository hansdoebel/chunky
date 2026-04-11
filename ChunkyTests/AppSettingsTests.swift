import Foundation
import Testing

@testable import Chunky

struct AppSettingsTests {

    // MARK: - Initialization Tests
    // Note: These tests verify that settings can be created and have reasonable values.
    // Exact defaults may vary based on UserDefaults state from previous app runs.

    @Test func settingsCanBeCreated() {
        let settings = AppSettings()

        // Verify embedding settings exist and have valid ranges
        #expect(!settings.embeddingModel.isEmpty)
        #expect(settings.embeddingDimensions > 0)
        #expect(settings.embeddingBatchSize >= 1 && settings.embeddingBatchSize <= 32)
        #expect(settings.embeddingConcurrency >= 1 && settings.embeddingConcurrency <= 4)
    }

    @Test func qdrantSettingsHaveValidRanges() {
        let settings = AppSettings()

        #expect(!settings.defaultCollection.isEmpty)
        #expect(settings.qdrantBatchSize >= 10 && settings.qdrantBatchSize <= 500)
        #expect(settings.qdrantTimeout >= 10 && settings.qdrantTimeout <= 120)
        #expect(Compression.allCases.map { $0.rawValue }.contains(settings.qdrantCompression))
        #expect(DistanceMetric.allCases.map { $0.rawValue }.contains(settings.qdrantDistanceMetric))
    }

    @Test func metadataSettingsAreBooleans() {
        let settings = AppSettings()

        // These should be booleans - verify they can be read without error
        _ = settings.metadataIncludeFilename
        _ = settings.metadataIncludePageNumber
        _ = settings.metadataIncludeHeadings
        _ = settings.metadataIncludeTimestamp
    }

    @Test func doclingSettingsHaveValidRanges() {
        let settings = AppSettings()

        // Model should be a valid value
        #expect(!settings.doclingModel.isEmpty)
        #expect(settings.doclingWorkers >= 1 && settings.doclingWorkers <= 6)
        #expect(settings.doclingTimeout >= 60 && settings.doclingTimeout <= 600)
        #expect(settings.doclingMaxPages >= 0)  // 0 means unlimited
        #expect(settings.maxTokensPerChunk >= 128 && settings.maxTokensPerChunk <= 2048)
        #expect(settings.chunkOverlap >= 0 && settings.chunkOverlap <= 256)
        #expect(TableMode.allCases.map { $0.rawValue }.contains(settings.tableMode))
    }

    @Test func exportSettingsExist() {
        let settings = AppSettings()

        // Export format should be a valid enum value
        #expect(ExportFormat.allCases.map { $0.rawValue }.contains(settings.exportFormat))
    }

    // MARK: - Settings Modification Tests

    @Test func embeddingModelCanBeChanged() {
        let settings = AppSettings()

        settings.embeddingModel = "nomic-embed-text"
        #expect(settings.embeddingModel == "nomic-embed-text")
    }

    @Test func embeddingDimensionsCanBeChanged() {
        let settings = AppSettings()

        settings.embeddingDimensions = 768
        #expect(settings.embeddingDimensions == 768)
    }

    @Test func embeddingBatchSizeRange() {
        let settings = AppSettings()

        // Test valid range (1-32 according to UI)
        settings.embeddingBatchSize = 1
        #expect(settings.embeddingBatchSize == 1)

        settings.embeddingBatchSize = 16
        #expect(settings.embeddingBatchSize == 16)
    }

    @Test func qdrantBatchSizeCanBeChanged() {
        let settings = AppSettings()

        settings.qdrantBatchSize = 200
        #expect(settings.qdrantBatchSize == 200)
    }

    @Test func metadataOptionsCanBeToggled() {
        let settings = AppSettings()

        settings.metadataIncludeFilename = false
        #expect(settings.metadataIncludeFilename == false)

        settings.metadataIncludePageNumber = false
        #expect(settings.metadataIncludePageNumber == false)

        settings.metadataIncludeHeadings = false
        #expect(settings.metadataIncludeHeadings == false)

        settings.metadataIncludeTimestamp = false
        #expect(settings.metadataIncludeTimestamp == false)
    }

    @Test func doclingSettingsCanBeChanged() {
        let settings = AppSettings()

        settings.doclingWorkers = 4
        #expect(settings.doclingWorkers == 4)

        settings.doclingTimeout = 300
        #expect(settings.doclingTimeout == 300)

        settings.doclingMaxPages = 100
        #expect(settings.doclingMaxPages == 100)

        settings.doOCR = true
        #expect(settings.doOCR == true)

        settings.doTableExtraction = false
        #expect(settings.doTableExtraction == false)
    }

    @Test func chunkingSettingsCanBeChanged() {
        let settings = AppSettings()

        settings.maxTokensPerChunk = 1024
        #expect(settings.maxTokensPerChunk == 1024)

        settings.chunkOverlap = 100
        #expect(settings.chunkOverlap == 100)
    }

    @Test func exportSettingsCanBeChanged() {
        let settings = AppSettings()

        settings.exportFormat = ExportFormat.docling.rawValue
        #expect(settings.exportFormat == ExportFormat.docling.rawValue)

        settings.exportFormat = ExportFormat.html.rawValue
        #expect(settings.exportFormat == ExportFormat.html.rawValue)

        settings.exportFormat = ExportFormat.json.rawValue
        #expect(settings.exportFormat == ExportFormat.json.rawValue)

        settings.exportFormat = ExportFormat.text.rawValue
        #expect(settings.exportFormat == ExportFormat.text.rawValue)

        settings.exportFolder = "/tmp/exports"
        #expect(settings.exportFolder == "/tmp/exports")
    }

    @Test func compressionCanBeChanged() {
        let settings = AppSettings()

        for compression in Compression.allCases {
            settings.qdrantCompression = compression.rawValue
            #expect(settings.qdrantCompression == compression.rawValue)
        }
    }

    @Test func distanceMetricCanBeChanged() {
        let settings = AppSettings()

        for metric in DistanceMetric.allCases {
            settings.qdrantDistanceMetric = metric.rawValue
            #expect(settings.qdrantDistanceMetric == metric.rawValue)
        }
    }

    @Test func tableModeCanBeChanged() {
        let settings = AppSettings()

        settings.tableMode = TableMode.accurate.rawValue
        #expect(settings.tableMode == TableMode.accurate.rawValue)

        settings.tableMode = TableMode.fast.rawValue
        #expect(settings.tableMode == TableMode.fast.rawValue)
    }
}
