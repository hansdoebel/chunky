import SwiftUI
import Combine

protocol SettingsSecretStore: AnyObject {
    func value(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

final class KeychainSecretStore: SettingsSecretStore {
    func value(for key: String) -> String? {
        KeychainService.get(key: key)
    }

    func set(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            try? KeychainService.save(key: key, value: value)
        } else {
            KeychainService.delete(key: key)
        }
    }
}

final class MemorySecretStore: SettingsSecretStore {
    private var values: [String: String] = [:]

    func value(for key: String) -> String? {
        values[key]
    }

    func set(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            values[key] = value
        } else {
            values[key] = nil
        }
    }
}

class AppSettings: ObservableObject {
    let defaults: UserDefaults
    private let secrets: SettingsSecretStore
    private let prefix = "chunky."

    var ollamaURL: String {
        get { secret(KeychainService.ollamaURLKey, default: "http://localhost:11434") }
        set { setSecret(KeychainService.ollamaURLKey, newValue) }
    }
    @Published var embeddingBackend: String {
        didSet { defaults.set(embeddingBackend, forKey: prefix + "embeddingBackend") }
    }
    @Published var embeddingAPIURL: String {
        didSet { defaults.set(embeddingAPIURL, forKey: prefix + "embeddingAPIURL") }
    }
    @Published var embeddingModel: String {
        didSet { defaults.set(embeddingModel, forKey: prefix + "embeddingModel") }
    }
    @Published var embeddingDimensions: Int {
        didSet { defaults.set(embeddingDimensions, forKey: prefix + "embeddingDimensions") }
    }
    @Published var embeddingBatchSize: Int {
        didSet { defaults.set(embeddingBatchSize, forKey: prefix + "embeddingBatchSize") }
    }
    @Published var embeddingConcurrency: Int {
        didSet { defaults.set(embeddingConcurrency, forKey: prefix + "embeddingConcurrency") }
    }

    var qdrantURL: String {
        get { secret(KeychainService.qdrantURLKey, default: "http://localhost:6334") }
        set { setSecret(KeychainService.qdrantURLKey, newValue) }
    }
    @Published var defaultCollection: String {
        didSet { defaults.set(defaultCollection, forKey: prefix + "defaultCollection") }
    }
    @Published var qdrantBatchSize: Int {
        didSet { defaults.set(qdrantBatchSize, forKey: prefix + "qdrantBatchSize") }
    }
    @Published var qdrantTimeout: Int {
        didSet { defaults.set(qdrantTimeout, forKey: prefix + "qdrantTimeout") }
    }
    @Published var qdrantDistanceMetric: String {
        didSet { defaults.set(qdrantDistanceMetric, forKey: prefix + "qdrantDistanceMetric") }
    }
    @Published var hybridSearch: Bool {
        didSet { defaults.set(hybridSearch, forKey: prefix + "hybridSearch") }
    }
    @Published var qdrantCompression: String {
        didSet { defaults.set(qdrantCompression, forKey: prefix + "qdrantCompression") }
    }

    @Published var metadataIncludeFilename: Bool {
        didSet { defaults.set(metadataIncludeFilename, forKey: prefix + "metadataIncludeFilename") }
    }
    @Published var metadataIncludePageNumber: Bool {
        didSet { defaults.set(metadataIncludePageNumber, forKey: prefix + "metadataIncludePageNumber") }
    }
    @Published var metadataIncludeHeadings: Bool {
        didSet { defaults.set(metadataIncludeHeadings, forKey: prefix + "metadataIncludeHeadings") }
    }
    @Published var metadataIncludeTimestamp: Bool {
        didSet { defaults.set(metadataIncludeTimestamp, forKey: prefix + "metadataIncludeTimestamp") }
    }
    @Published var metadataIncludeDocTitle: Bool {
        didSet { defaults.set(metadataIncludeDocTitle, forKey: prefix + "metadataIncludeDocTitle") }
    }
    @Published var metadataIncludeAuthors: Bool {
        didSet { defaults.set(metadataIncludeAuthors, forKey: prefix + "metadataIncludeAuthors") }
    }
    @Published var metadataIncludeChunkIndex: Bool {
        didSet { defaults.set(metadataIncludeChunkIndex, forKey: prefix + "metadataIncludeChunkIndex") }
    }
    @Published var metadataIncludeContentType: Bool {
        didSet { defaults.set(metadataIncludeContentType, forKey: prefix + "metadataIncludeContentType") }
    }
    @Published var metadataIncludeSection: Bool {
        didSet { defaults.set(metadataIncludeSection, forKey: prefix + "metadataIncludeSection") }
    }
    @Published var metadataIncludeDOI: Bool {
        didSet { defaults.set(metadataIncludeDOI, forKey: prefix + "metadataIncludeDOI") }
    }
    @Published var metadataIncludeDocumentId: Bool {
        didSet { defaults.set(metadataIncludeDocumentId, forKey: prefix + "metadataIncludeDocumentId") }
    }
    @Published var metadataIncludeURL: Bool {
        didSet { defaults.set(metadataIncludeURL, forKey: prefix + "metadataIncludeURL") }
    }
    @Published var metadataIncludeYear: Bool {
        didSet { defaults.set(metadataIncludeYear, forKey: prefix + "metadataIncludeYear") }
    }
    @Published var metadataIncludeLanguage: Bool {
        didSet { defaults.set(metadataIncludeLanguage, forKey: prefix + "metadataIncludeLanguage") }
    }

    @Published var doTextCleanup: Bool {
        didSet { defaults.set(doTextCleanup, forKey: prefix + "doTextCleanup") }
    }

    @Published var useDaemonMode: Bool {
        didSet { defaults.set(useDaemonMode, forKey: prefix + "useDaemonMode") }
    }
    @Published var streamingPipeline: Bool {
        didSet { defaults.set(streamingPipeline, forKey: prefix + "streamingPipeline") }
    }
    @Published var enableEmbeddingCache: Bool {
        didSet { defaults.set(enableEmbeddingCache, forKey: prefix + "enableEmbeddingCache") }
    }
    @Published var maxParallelJobs: Int {
        didSet { defaults.set(maxParallelJobs, forKey: prefix + "maxParallelJobs") }
    }

    @Published var processingHost: ProcessingHost {
        didSet { defaults.set(processingHost.rawValue, forKey: prefix + "processingHost") }
    }
    @Published var doclingModel: String {
        didSet { defaults.set(doclingModel, forKey: prefix + "doclingModel") }
    }
    @Published var layoutModel: String {
        didSet { defaults.set(layoutModel, forKey: prefix + "layoutModel") }
    }
    @Published var doclingWorkers: Int {
        didSet { defaults.set(doclingWorkers, forKey: prefix + "doclingWorkers") }
    }
    @Published var ocrBatchSize: Int {
        didSet { defaults.set(ocrBatchSize, forKey: prefix + "ocrBatchSize") }
    }
    @Published var layoutBatchSize: Int {
        didSet { defaults.set(layoutBatchSize, forKey: prefix + "layoutBatchSize") }
    }
    @Published var tableBatchSize: Int {
        didSet { defaults.set(tableBatchSize, forKey: prefix + "tableBatchSize") }
    }
    @Published var doclingAccelerator: String {
        didSet { defaults.set(doclingAccelerator, forKey: prefix + "doclingAccelerator") }
    }
    @Published var doclingTimeout: Int {
        didSet { defaults.set(doclingTimeout, forKey: prefix + "doclingTimeout") }
    }
    @Published var doclingMaxPages: Int {
        didSet { defaults.set(doclingMaxPages, forKey: prefix + "doclingMaxPages") }
    }
    @Published var maxTokensPerChunk: Int {
        didSet { defaults.set(maxTokensPerChunk, forKey: prefix + "maxTokensPerChunk") }
    }
    @Published var chunkOverlap: Int {
        didSet { defaults.set(chunkOverlap, forKey: prefix + "chunkOverlap") }
    }
    @Published var chunkMergePeers: Bool {
        didSet { defaults.set(chunkMergePeers, forKey: prefix + "chunkMergePeers") }
    }
    @Published var chunkTokenizer: String {
        didSet { defaults.set(chunkTokenizer, forKey: prefix + "chunkTokenizer") }
    }
    @Published var recordedDoclingVersion: String {
        didSet { defaults.set(recordedDoclingVersion, forKey: prefix + "recordedDoclingVersion") }
    }
    @Published var chunkCacheLimitMB: Int {
        didSet { defaults.set(chunkCacheLimitMB, forKey: prefix + "chunkCacheLimitMB") }
    }

    var chunkCacheLimitBytes: Int {
        chunkCacheLimitMB <= 0 ? 0 : chunkCacheLimitMB * 1024 * 1024
    }
    @Published var doTableExtraction: Bool {
        didSet { defaults.set(doTableExtraction, forKey: prefix + "doTableExtraction") }
    }
    @Published var tableMode: String {
        didSet { defaults.set(tableMode, forKey: prefix + "tableMode") }
    }
    @Published var doOCR: Bool {
        didSet { defaults.set(doOCR, forKey: prefix + "doOCR") }
    }
    @Published var ocrLanguage: String {
        didSet { defaults.set(ocrLanguage, forKey: prefix + "ocrLanguage") }
    }

    @Published var imageExportMode: String {
        didSet { defaults.set(imageExportMode, forKey: prefix + "imageExportMode") }
    }
    @Published var doFormulaEnrichment: Bool {
        didSet { defaults.set(doFormulaEnrichment, forKey: prefix + "doFormulaEnrichment") }
    }
    @Published var doCodeEnrichment: Bool {
        didSet { defaults.set(doCodeEnrichment, forKey: prefix + "doCodeEnrichment") }
    }
    @Published var doChartExtraction: Bool {
        didSet { defaults.set(doChartExtraction, forKey: prefix + "doChartExtraction") }
    }
    @Published var doPictureDescription: Bool {
        didSet { defaults.set(doPictureDescription, forKey: prefix + "doPictureDescription") }
    }
    @Published var doPictureClassification: Bool {
        didSet { defaults.set(doPictureClassification, forKey: prefix + "doPictureClassification") }
    }
    @Published var pictureDescriptionPreset: String {
        didSet { defaults.set(pictureDescriptionPreset, forKey: prefix + "pictureDescriptionPreset") }
    }
    @Published var vlmServerURL: String {
        didSet { defaults.set(vlmServerURL, forKey: prefix + "vlmServerURL") }
    }
    @Published var qdrantProfile: QdrantProfile {
        didSet { defaults.set(qdrantProfile.rawValue, forKey: prefix + "qdrantProfile") }
    }

    var resolvedPictureDescriptionPreset: String {
        if pictureDescriptionPreset.isEmpty {
            return PictureDescriptionPreset.hostDefault(processingHost).rawValue
        }
        return pictureDescriptionPreset
    }

    @Published var doStructuredExtraction: Bool {
        didSet { defaults.set(doStructuredExtraction, forKey: prefix + "doStructuredExtraction") }
    }
    @Published var extractionSchemaPath: String {
        didSet { defaults.set(extractionSchemaPath, forKey: prefix + "extractionSchemaPath") }
    }

    @Published var exportFolder: String {
        didSet { defaults.set(exportFolder, forKey: prefix + "exportFolder") }
    }
    @Published var exportFormat: String {
        didSet { defaults.set(exportFormat, forKey: prefix + "exportFormat") }
    }
    @Published var devboxWorkerURL: String {
        didSet { defaults.set(devboxWorkerURL, forKey: prefix + "devboxWorkerURL") }
    }
    @Published var devboxIngestTarget: DevboxIngestTarget {
        didSet { defaults.set(devboxIngestTarget.rawValue, forKey: prefix + "devboxIngestTarget") }
    }

    @Published var chatBackend: String {
        didSet { defaults.set(chatBackend, forKey: prefix + "chatBackend") }
    }
    @Published var piExecutablePath: String {
        didSet { defaults.set(piExecutablePath, forKey: prefix + "piExecutablePath") }
    }
    @Published var chatAPIURL: String {
        didSet { defaults.set(chatAPIURL, forKey: prefix + "chatAPIURL") }
    }
    @Published var chatModel: String {
        didSet { defaults.set(chatModel, forKey: prefix + "chatModel") }
    }
    @Published var piModel: String {
        didSet { defaults.set(piModel, forKey: prefix + "piModel") }
    }

    var chatAPIKey: String {
        get { secret(KeychainService.chatAPIKeyKey) }
        set { setSecret(KeychainService.chatAPIKeyKey, newValue) }
    }

    var workerToken: String {
        get { secret(KeychainService.workerTokenKey) }
        set { setSecret(KeychainService.workerTokenKey, newValue) }
    }

    func workerEndpoints() -> [WorkerEndpoint] {
        let stored = WorkerEndpointStore.load(defaults: defaults)
        if !stored.isEmpty { return stored }
        var seeded = WorkerEndpoint.starters()
        if !devboxWorkerURL.isEmpty {
            seeded[0].url = devboxWorkerURL
            setWorkerEndpointToken(id: seeded[0].id, workerToken)
            WorkerEndpointStore.setActive(seeded[0].id, defaults: defaults)
        }
        WorkerEndpointStore.save(seeded, defaults: defaults)
        return seeded
    }

    func replaceWorkerEndpoints(_ endpoints: [WorkerEndpoint]) {
        WorkerEndpointStore.save(endpoints, defaults: defaults)
        objectWillChange.send()
    }

    func activeWorkerEndpointID() -> UUID? {
        WorkerEndpointStore.activeID(defaults: defaults)
    }

    func workerEndpointToken(id: UUID) -> String {
        secret(WorkerEndpointStore.tokenKey(id))
    }

    func setWorkerEndpointToken(id: UUID, _ token: String) {
        setSecret(WorkerEndpointStore.tokenKey(id), token)
    }

    func useWorkerEndpoint(_ endpoint: WorkerEndpoint) {
        WorkerEndpointStore.setActive(endpoint.id, defaults: defaults)
        devboxWorkerURL = endpoint.url
        workerToken = workerEndpointToken(id: endpoint.id)
    }

    var qdrantCloudURL: String {
        get { secret(KeychainService.qdrantCloudURLKey) }
        set { setSecret(KeychainService.qdrantCloudURLKey, newValue) }
    }

    var qdrantAPIKey: String {
        get { secret(KeychainService.qdrantAPIKeyKey) }
        set { setSecret(KeychainService.qdrantAPIKeyKey, newValue) }
    }

    init(defaults: UserDefaults = .standard, secrets: SettingsSecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets

        self.embeddingBackend = defaults.string(forKey: prefix + "embeddingBackend") ?? EmbeddingBackendKind.ollama.rawValue
        self.embeddingAPIURL = defaults.string(forKey: prefix + "embeddingAPIURL") ?? ""
        self.embeddingModel = defaults.string(forKey: prefix + "embeddingModel") ?? EmbeddingWidth.defaultModel
        self.embeddingDimensions = defaults.object(forKey: prefix + "embeddingDimensions") as? Int ?? EmbeddingWidth.defaultDimensions
        self.embeddingBatchSize = defaults.object(forKey: prefix + "embeddingBatchSize") as? Int ?? 32
        self.embeddingConcurrency = defaults.object(forKey: prefix + "embeddingConcurrency") as? Int ?? 4

        self.defaultCollection = defaults.string(forKey: prefix + "defaultCollection") ?? "documents"
        self.qdrantBatchSize = defaults.object(forKey: prefix + "qdrantBatchSize") as? Int ?? 250
        self.qdrantTimeout = defaults.object(forKey: prefix + "qdrantTimeout") as? Int ?? 30
        self.qdrantDistanceMetric = defaults.string(forKey: prefix + "qdrantDistanceMetric") ?? DistanceMetric.cosine.rawValue
        self.hybridSearch = defaults.object(forKey: prefix + "hybridSearch") as? Bool ?? false
        self.qdrantCompression = defaults.string(forKey: prefix + "qdrantCompression") ?? Compression.none.rawValue

        self.metadataIncludeFilename = defaults.object(forKey: prefix + "metadataIncludeFilename") as? Bool ?? true
        self.metadataIncludePageNumber = defaults.object(forKey: prefix + "metadataIncludePageNumber") as? Bool ?? true
        self.metadataIncludeHeadings = defaults.object(forKey: prefix + "metadataIncludeHeadings") as? Bool ?? true
        self.metadataIncludeTimestamp = defaults.object(forKey: prefix + "metadataIncludeTimestamp") as? Bool ?? true
        self.metadataIncludeDocTitle = defaults.object(forKey: prefix + "metadataIncludeDocTitle") as? Bool ?? true
        self.metadataIncludeAuthors = defaults.object(forKey: prefix + "metadataIncludeAuthors") as? Bool ?? true
        self.metadataIncludeChunkIndex = defaults.object(forKey: prefix + "metadataIncludeChunkIndex") as? Bool ?? true
        self.metadataIncludeContentType = defaults.object(forKey: prefix + "metadataIncludeContentType") as? Bool ?? true
        self.metadataIncludeSection = defaults.object(forKey: prefix + "metadataIncludeSection") as? Bool ?? true
        self.metadataIncludeDOI = defaults.object(forKey: prefix + "metadataIncludeDOI") as? Bool ?? true
        self.metadataIncludeDocumentId = defaults.object(forKey: prefix + "metadataIncludeDocumentId") as? Bool ?? true
        self.metadataIncludeURL = defaults.object(forKey: prefix + "metadataIncludeURL") as? Bool ?? true
        self.metadataIncludeYear = defaults.object(forKey: prefix + "metadataIncludeYear") as? Bool ?? true
        self.metadataIncludeLanguage = defaults.object(forKey: prefix + "metadataIncludeLanguage") as? Bool ?? true

        self.processingHost = ProcessingHost(
            rawValue: defaults.string(forKey: prefix + "processingHost") ?? ""
        ) ?? .localMac
        self.doclingModel = defaults.string(forKey: prefix + "doclingModel") ?? DoclingModel.graniteDoclingMLX.rawValue
        self.layoutModel = defaults.string(forKey: prefix + "layoutModel") ?? LayoutModel.heron.rawValue
        self.doclingWorkers = defaults.object(forKey: prefix + "doclingWorkers") as? Int ?? 8
        self.ocrBatchSize = defaults.object(forKey: prefix + "ocrBatchSize") as? Int ?? 0
        self.layoutBatchSize = defaults.object(forKey: prefix + "layoutBatchSize") as? Int ?? 0
        self.tableBatchSize = defaults.object(forKey: prefix + "tableBatchSize") as? Int ?? 0
        self.doclingAccelerator = defaults.string(forKey: prefix + "doclingAccelerator")
            ?? ProcessingHost.localMac.defaultAccelerator.rawValue
        self.doclingTimeout = defaults.object(forKey: prefix + "doclingTimeout") as? Int ?? 120
        self.doclingMaxPages = defaults.object(forKey: prefix + "doclingMaxPages") as? Int ?? 0
        self.maxTokensPerChunk = defaults.object(forKey: prefix + "maxTokensPerChunk") as? Int ?? 512
        self.chunkOverlap = defaults.object(forKey: prefix + "chunkOverlap") as? Int ?? 64
        self.chunkMergePeers = defaults.object(forKey: prefix + "chunkMergePeers") as? Bool ?? true
        self.chunkTokenizer = defaults.string(forKey: prefix + "chunkTokenizer") ?? ""
        self.recordedDoclingVersion = defaults.string(forKey: prefix + "recordedDoclingVersion") ?? ""
        self.chunkCacheLimitMB = defaults.object(forKey: prefix + "chunkCacheLimitMB") as? Int ?? 2048
        self.doTableExtraction = defaults.object(forKey: prefix + "doTableExtraction") as? Bool ?? true
        self.tableMode = defaults.string(forKey: prefix + "tableMode") ?? TableMode.accurate.rawValue
        self.doOCR = defaults.object(forKey: prefix + "doOCR") as? Bool ?? false
        self.ocrLanguage = defaults.string(forKey: prefix + "ocrLanguage") ?? OCRLanguage.german.rawValue

        self.imageExportMode = defaults.string(forKey: prefix + "imageExportMode") ?? ImageExportMode.embedded.rawValue
        self.doFormulaEnrichment = defaults.object(forKey: prefix + "doFormulaEnrichment") as? Bool ?? false
        self.doCodeEnrichment = defaults.object(forKey: prefix + "doCodeEnrichment") as? Bool ?? false
        self.doChartExtraction = defaults.object(forKey: prefix + "doChartExtraction") as? Bool ?? false
        self.doPictureDescription = defaults.object(forKey: prefix + "doPictureDescription") as? Bool ?? false
        self.doPictureClassification = defaults.object(forKey: prefix + "doPictureClassification") as? Bool ?? false
        self.pictureDescriptionPreset = defaults.string(forKey: prefix + "pictureDescriptionPreset") ?? ""
        self.vlmServerURL = defaults.string(forKey: prefix + "vlmServerURL") ?? ""
        self.qdrantProfile = QdrantProfile(
            rawValue: defaults.string(forKey: prefix + "qdrantProfile") ?? ""
        ) ?? .standard

        self.doStructuredExtraction = defaults.object(forKey: prefix + "doStructuredExtraction") as? Bool ?? false
        self.extractionSchemaPath = defaults.string(forKey: prefix + "extractionSchemaPath") ?? ""

        self.doTextCleanup = defaults.object(forKey: prefix + "doTextCleanup") as? Bool ?? false

        self.useDaemonMode = defaults.object(forKey: prefix + "useDaemonMode") as? Bool ?? true
        self.streamingPipeline = defaults.object(forKey: prefix + "streamingPipeline") as? Bool ?? true
        self.enableEmbeddingCache = defaults.object(forKey: prefix + "enableEmbeddingCache") as? Bool ?? true
        self.maxParallelJobs = defaults.object(forKey: prefix + "maxParallelJobs") as? Int ?? 2

        self.exportFolder = defaults.string(forKey: prefix + "exportFolder")
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? ""

        let savedFormat = defaults.string(forKey: prefix + "exportFormat") ?? ExportFormat.docling.rawValue
        self.exportFormat = savedFormat == "docling_images" ? ExportFormat.docling.rawValue : savedFormat
        self.devboxWorkerURL = defaults.string(forKey: prefix + "devboxWorkerURL") ?? ""
        self.devboxIngestTarget = DevboxIngestTarget(
            rawValue: defaults.string(forKey: prefix + "devboxIngestTarget") ?? ""
        ) ?? .localDocker
        self.chatBackend = defaults.string(forKey: prefix + "chatBackend") ?? ChatBackendPreference.automatic.rawValue
        self.piExecutablePath = defaults.string(forKey: prefix + "piExecutablePath") ?? ""
        self.chatAPIURL = defaults.string(forKey: prefix + "chatAPIURL") ?? "http://127.0.0.1:11434/v1"
        self.chatModel = defaults.string(forKey: prefix + "chatModel") ?? ""
        self.piModel = defaults.string(forKey: prefix + "piModel") ?? ""
    }

    func save() {

        defaults.synchronize()
    }

    private func secret(_ key: String, default fallback: String = "") -> String {
        secrets.value(for: key) ?? fallback
    }

    private func setSecret(_ key: String, _ value: String) {
        secrets.set(value.isEmpty ? nil : value, for: key)
        objectWillChange.send()
    }
}
