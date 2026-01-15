import SwiftUI

enum ProcessingMode: String, CaseIterable {
    case chunkOnly = "Chunk Only"
    case ingestOnly = "Ingest Only"
    case full = "Chunk & Ingest"
    case batch = "Batch Ingest"
}

enum ViewMode: String, CaseIterable {
    case queue = "Queue"
    case collections = "Collections"
}

@MainActor
final class AppState: ObservableObject {
    @Published var jobs: [ProcessingJob] = []
    @Published var settings = AppSettings.load()
    @Published var isProcessing = false
    @Published var isCancellationRequested = false
    @Published var processingMode: ProcessingMode = .full
    @Published var viewMode: ViewMode = .queue
    @Published var availableCollections: [String] = []
    @Published var isLoadingCollections = false

    // Collection browser state
    @Published var browserPoints: [QdrantPoint] = []
    @Published var browserSources: [String] = []
    @Published var isLoadingPoints = false
    @Published var browserPointCount: Int = 0

    var pendingJobs: [ProcessingJob] {
        jobs.filter { $0.status == .pending }
    }

    var completedJobs: [ProcessingJob] {
        jobs.filter { $0.status == .completed }
    }

    var activeJobs: [ProcessingJob] {
        jobs.filter { $0.status == .chunking || $0.status == .embedding || $0.status == .uploading }
    }

    var failedJobs: [ProcessingJob] {
        jobs.filter { $0.status == .failed }
    }

    var hasJobsToProcess: Bool {
        !pendingJobs.isEmpty && !isProcessing
    }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0.0) { $0 + $1.progress }
        return total / Double(jobs.count)
    }

    private static let doclingExtensions: Set<String> = [
        "pdf", "docx", "pptx", "xlsx", "html", "htm", "xhtml",
        "png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp",
        "csv", "adoc", "asciidoc"
    ]

    func addFiles(_ urls: [URL]) {
        for url in urls {
            guard !jobs.contains(where: { $0.sourceURL == url }) else { continue }

            let ext = url.pathExtension.lowercased()

            if Self.doclingExtensions.contains(ext) {
                let job = ProcessingJob(sourceURL: url)
                jobs.append(job)
            } else if ext == "json" {
                addJSONFiles([url])
            } else if ext == "md" || ext == "markdown" {
                addMarkdownFiles([url])
            }
        }
    }

    func addJSONFiles(_ urls: [URL]) {
        print("[Chunky] addJSONFiles called with \(urls.count) URLs")
        for url in urls {
            print("[Chunky] Processing: \(url.path)")
            guard url.pathExtension.lowercased() == "json" else {
                print("[Chunky] Skipping non-JSON: \(url.lastPathComponent)")
                continue
            }
            guard !jobs.contains(where: { $0.sourceURL == url }) else {
                print("[Chunky] Skipping duplicate: \(url.lastPathComponent)")
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                print("[Chunky] Read \(data.count) bytes from \(url.lastPathComponent)")

                let decoder = JSONDecoder()

                do {
                    let output = try decoder.decode(ChunkerOutput.self, from: data)
                    print("[Chunky] Decoded as ChunkerOutput with \(output.chunks.count) chunks")
                    let job = ProcessingJob(sourceURL: url, chunks: output.chunks)
                    jobs.append(job)
                    continue
                } catch {
                    print("[Chunky] Not ChunkerOutput: \(error)")
                }

                do {
                    let input = try decoder.decode(QdrantInput.self, from: data)
                    print("[Chunky] Decoded as QdrantInput with \(input.points.count) points")
                    let job = ProcessingJob(sourceURL: url, embeddedChunks: input.points)
                    jobs.append(job)
                    continue
                } catch {
                    print("[Chunky] Not QdrantInput: \(error)")
                }

                do {
                    let chunks = try decoder.decode([Chunk].self, from: data)
                    print("[Chunky] Decoded as [Chunk] with \(chunks.count) chunks")
                    let job = ProcessingJob(sourceURL: url, chunks: chunks)
                    jobs.append(job)
                    continue
                } catch {
                    print("[Chunky] Not [Chunk]: \(error)")
                }

                do {
                    let embedded = try decoder.decode([ChunkWithEmbedding].self, from: data)
                    print("[Chunky] Decoded as [ChunkWithEmbedding] with \(embedded.count) points")
                    let job = ProcessingJob(sourceURL: url, embeddedChunks: embedded)
                    jobs.append(job)
                    continue
                } catch {
                    print("[Chunky] Not [ChunkWithEmbedding]: \(error)")
                }

                do {
                    let docling = try decoder.decode(DoclingDocument.self, from: data)
                    let chunks = docling.toChunks()
                    print("[Chunky] Decoded as DoclingDocument with \(chunks.count) text chunks")
                    let job = ProcessingJob(sourceURL: url, chunks: chunks)
                    jobs.append(job)
                    continue
                } catch {
                    print("[Chunky] Not DoclingDocument: \(error)")
                }

                print("[Chunky] ERROR: No decoder matched for \(url.lastPathComponent)")
                if let jsonString = String(data: data.prefix(500), encoding: .utf8) {
                    print("[Chunky] First 500 chars: \(jsonString)")
                }
            } catch {
                print("[Chunky] ERROR loading \(url.lastPathComponent): \(error)")
            }
        }
    }

    func addMarkdownFiles(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            guard !jobs.contains(where: { $0.sourceURL == url }) else { continue }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let chunk = Chunk(
                    id: UUID().uuidString,
                    text: content,
                    metadata: ChunkMetadata(
                        chunkIndex: 0,
                        source: url.lastPathComponent,
                        headings: [],
                        page: nil
                    )
                )
                let job = ProcessingJob(sourceURL: url, chunks: [chunk])
                jobs.append(job)
            } catch {
                print("[Chunky] ERROR loading markdown \(url.lastPathComponent): \(error)")
            }
        }
    }

    func removeJob(_ job: ProcessingJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearCompleted() {
        jobs.removeAll { $0.status == .completed }
    }

    func clearAll() {
        jobs.removeAll { $0.status != .chunking && $0.status != .embedding && $0.status != .uploading }
    }

    func requestCancellation() {
        isCancellationRequested = true
    }

    func resetCancellation() {
        isCancellationRequested = false
    }

    func fetchCollections() async {
        guard !settings.qdrantURL.isEmpty, !settings.qdrantAPIKey.isEmpty else {
            availableCollections = []
            return
        }

        isLoadingCollections = true
        defer { isLoadingCollections = false }

        var urlString = settings.qdrantURL
        if !urlString.contains(":6333") && !urlString.contains(":6334") {
            urlString = urlString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            urlString += ":6333"
        }

        guard let baseURL = URL(string: urlString) else { return }
        let collectionsURL = baseURL.appendingPathComponent("collections")

        do {
            var request = URLRequest(url: collectionsURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue(settings.qdrantAPIKey, forHTTPHeaderField: "api-key")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   let collections = result["collections"] as? [[String: Any]] {
                    availableCollections = collections.compactMap { $0["name"] as? String }.sorted()

                    if !availableCollections.contains(settings.defaultCollection) && !settings.defaultCollection.isEmpty {
                        availableCollections.insert(settings.defaultCollection, at: 0)
                    }
                }
            }
        } catch {
            print("[Chunky] Failed to fetch collections: \(error)")
        }
    }

    func loadBrowserPoints() async {
        guard !settings.qdrantURL.isEmpty, !settings.qdrantAPIKey.isEmpty, !settings.defaultCollection.isEmpty else {
            browserPoints = []
            browserSources = []
            browserPointCount = 0
            return
        }

        isLoadingPoints = true
        defer { isLoadingPoints = false }

        var urlString = settings.qdrantURL
        if !urlString.contains(":6333") && !urlString.contains(":6334") {
            urlString = urlString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            urlString += ":6333"
        }

        guard let baseURL = URL(string: urlString) else { return }

        // Get collection info for point count
        let infoURL = baseURL.appendingPathComponent("collections/\(settings.defaultCollection)")
        do {
            var request = URLRequest(url: infoURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue(settings.qdrantAPIKey, forHTTPHeaderField: "api-key")

            let (data, _) = try await URLSession.shared.data(for: request)
            if let info = try? JSONDecoder().decode(QdrantCollectionInfo.self, from: data) {
                browserPointCount = info.result?.pointsCount ?? 0
            }
        } catch {
            print("[Chunky] Failed to get collection info: \(error)")
        }

        // Scroll points
        let scrollURL = baseURL.appendingPathComponent("collections/\(settings.defaultCollection)/points/scroll")
        do {
            var request = URLRequest(url: scrollURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue(settings.qdrantAPIKey, forHTTPHeaderField: "api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "limit": 100,
                "with_payload": true,
                "with_vector": false
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            if let response = try? JSONDecoder().decode(QdrantScrollResponse.self, from: data),
               let result = response.result {
                browserPoints = result.points.map { QdrantPoint(from: $0) }
                browserSources = Array(Set(browserPoints.map { $0.source })).sorted()
            }
        } catch {
            print("[Chunky] Failed to scroll points: \(error)")
        }
    }

    func deletePoints(ids: [String]) async {
        guard !settings.qdrantURL.isEmpty, !settings.qdrantAPIKey.isEmpty, !settings.defaultCollection.isEmpty else {
            return
        }

        var urlString = settings.qdrantURL
        if !urlString.contains(":6333") && !urlString.contains(":6334") {
            urlString = urlString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            urlString += ":6333"
        }

        guard let baseURL = URL(string: urlString) else { return }
        let deleteURL = baseURL.appendingPathComponent("collections/\(settings.defaultCollection)/points/delete")

        do {
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue(settings.qdrantAPIKey, forHTTPHeaderField: "api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = ["points": ids]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                browserPoints.removeAll { ids.contains($0.id) }
                browserPointCount -= ids.count
            }
        } catch {
            print("[Chunky] Failed to delete points: \(error)")
        }
    }
}
