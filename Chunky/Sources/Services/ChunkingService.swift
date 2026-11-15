import Foundation

/// Service for chunking document content for embedding
actor ChunkingService {

    // MARK: - Errors

    enum ChunkingError: Error, LocalizedError {
        case fileNotFound(URL)
        case invalidJSON(String)
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "File not found: \(url.path)"
            case .invalidJSON(let details):
                return "Invalid JSON format: \(details)"
            case .emptyDocument:
                return "Document contains no content to chunk"
            }
        }
    }

    // MARK: - Types

    struct ChunkingOptions: Sendable {
        var maxTokensPerChunk: Int = 512
        var overlapTokens: Int = 50
        var minChunkSize: Int = 100
        var preserveHeadings: Bool = true
        var includeTableContent: Bool = true
    }

    struct DocumentChunk: Identifiable, Sendable {
        let id: String
        let text: String
        let source: String
        let page: Int?
        let headings: [String]
        let metadata: [String: String]
        let tokenCount: Int
        let formattedContent: String
        let chunkIndex: Int
        let contentType: String
        let section: String?
        let docTitle: String?
        let authors: [String]?
        let doi: String?
        let documentId: String?
        let url: String?
        let year: Int?
        let language: String?
        let embeddingText: String?
        let pictureDescription: String?
        let pictureClass: String?
        let tableMarkdown: String?

        init(
            id: String = UUID().uuidString,
            text: String,
            source: String,
            page: Int? = nil,
            headings: [String] = [],
            metadata: [String: String] = [:],
            tokenCount: Int = 0,
            formattedContent: String? = nil,
            chunkIndex: Int = 0,
            contentType: String = "text",
            section: String? = nil,
            docTitle: String? = nil,
            authors: [String]? = nil,
            doi: String? = nil,
            documentId: String? = nil,
            url: String? = nil,
            year: Int? = nil,
            language: String? = nil,
            embeddingText: String? = nil,
            pictureDescription: String? = nil,
            pictureClass: String? = nil,
            tableMarkdown: String? = nil
        ) {
            self.id = id
            self.text = text
            self.source = source
            self.page = page
            self.headings = headings
            self.metadata = metadata
            self.tokenCount = tokenCount
            self.formattedContent = formattedContent ?? text
            self.chunkIndex = chunkIndex
            self.contentType = contentType
            self.section = section
            self.docTitle = docTitle
            self.authors = authors
            self.doi = doi
            self.documentId = documentId
            self.url = url
            self.year = year
            self.language = language
            self.embeddingText = embeddingText
            self.pictureDescription = pictureDescription
            self.pictureClass = pictureClass
            self.tableMarkdown = tableMarkdown
        }

        func replacing(text: String, formattedContent: String, contentType: String, tokenCount: Int) -> DocumentChunk {
            DocumentChunk(
                id: id,
                text: text,
                source: source,
                page: page,
                headings: headings,
                metadata: metadata,
                tokenCount: tokenCount,
                formattedContent: formattedContent,
                chunkIndex: chunkIndex,
                contentType: contentType,
                section: section,
                docTitle: docTitle,
                authors: authors,
                doi: doi,
                documentId: documentId,
                url: url,
                year: year,
                language: language,
                embeddingText: embeddingText,
                pictureDescription: pictureDescription,
                pictureClass: pictureClass,
                tableMarkdown: tableMarkdown
            )
        }
    }
}

struct CleanupService {
    func cleanup(_ chunks: [ChunkingService.DocumentChunk]) -> [ChunkingService.DocumentChunk] {
        chunks.compactMap { chunk in
            let cleanedText = cleanText(chunk.text)
            let cleanedFormatted = cleanText(chunk.formattedContent)

            if isToCChunk(cleanedText) {
                return chunk.replacing(
                    text: cleanedText,
                    formattedContent: cleanedFormatted,
                    contentType: "toc",
                    tokenCount: max(1, cleanedText.count / 4)
                )
            }

            let trimmed = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }

            return chunk.replacing(
                text: cleanedText,
                formattedContent: cleanedFormatted,
                contentType: chunk.contentType,
                tokenCount: max(1, cleanedText.count / 4)
            )
        }
    }

    func cleanText(_ text: String) -> String {
        var result = text

        result = applyRegex(result, pattern: #"^- -\s*"#, replacement: "- ", options: .anchorsMatchLines)

        result = applyRegex(result, pattern: #"^\s*-\s*$"#, replacement: "", options: .anchorsMatchLines)

        result = applyRegex(result, pattern: #"[ \t]{2,}"#, replacement: " ")

        result = applyRegex(result, pattern: #"(\p{Ll})(\p{Lu})"#, replacement: "$1 $2")

        result = applyRegex(result, pattern: #"(\b\p{Lu})\s(\p{Ll})"#, replacement: "$1$2")

        result = applyRegex(result, pattern: #"(\p{L})(\d)"#, replacement: "$1 $2")

        result = applyRegex(result, pattern: #"(\d)(\p{L})"#, replacement: "$1 $2")

        result = result
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty || $0.isEmpty }
            .joined(separator: "\n")

        result = applyRegex(result, pattern: #"\n{3,}"#, replacement: "\n\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyRegex(_ text: String, pattern: String, replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private func isToCChunk(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("inhaltsverzeichnis") || lower.contains("table of contents") else {
            return false
        }

        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 2 else { return false }

        let tocPattern = try? NSRegularExpression(pattern: #"^\s*(\d+\.?)+\s+.+\s+\d+\s*$"#)
        let tocLineCount = lines.filter { line in
            let range = NSRange(line.startIndex..., in: line)
            return tocPattern?.firstMatch(in: line, range: range) != nil
        }.count

        return Double(tocLineCount) / Double(lines.count) > 0.5
    }
}

extension ChunkingService {
    // MARK: - Docling JSON Structures

    struct DoclingDocument: Codable {
        let name: String?
        let origin: DoclingOrigin?
        let description: DoclingDescription?
        let body: DoclingBody?
        let groups: [DoclingGroup]?
        let texts: [DoclingTextItem]?
        let tables: [DoclingTable]?
        let pages: [String: DoclingPage]?

        enum CodingKeys: String, CodingKey {
            case name, origin, description, body, groups, texts, tables, pages
        }
    }

    struct DoclingDescription: Codable {
        let title: String?
        let authors: [String]?
        let doi: String?
        let url: String?
        let abstract: String?
    }

    struct DoclingBody: Codable {
        let children: [DoclingRef]?
    }

    struct DoclingGroup: Codable {
        let selfRef: String?
        let children: [DoclingRef]?
        let label: String?

        enum CodingKeys: String, CodingKey {
            case selfRef = "self_ref"
            case children
            case label
        }
    }

    struct DoclingRef: Codable {
        let ref: String?

        enum CodingKeys: String, CodingKey {
            case ref = "$ref"
        }
    }

    struct DoclingOrigin: Codable {
        let filename: String?
        let uri: String?
    }

    struct DoclingTextItem: Codable {
        let selfRef: String?
        let text: String?
        let label: String?
        let level: Int?
        let prov: [DoclingProvenance]?

        enum CodingKeys: String, CodingKey {
            case selfRef = "self_ref"
            case text, label, level, prov
        }
    }

    struct DoclingProvenance: Codable {
        let pageNo: Int?
        let bbox: DoclingBBox?

        enum CodingKeys: String, CodingKey {
            case pageNo = "page_no"
            case bbox
        }
    }

    struct DoclingBBox: Codable {
        let l: Double?
        let t: Double?
        let r: Double?
        let b: Double?
    }

    struct DoclingTable: Codable {
        let selfRef: String?
        let label: String?
        let prov: [DoclingProvenance]?
        let data: DoclingTableData?

        enum CodingKeys: String, CodingKey {
            case selfRef = "self_ref"
            case label, prov, data
        }
    }

    struct DoclingTableData: Codable {
        let grid: [[DoclingTableCell]]?
        let numRows: Int?
        let numCols: Int?

        enum CodingKeys: String, CodingKey {
            case grid
            case numRows = "num_rows"
            case numCols = "num_cols"
        }
    }

    struct DoclingTableCell: Codable {
        let text: String?
        let columnHeader: Bool?

        enum CodingKeys: String, CodingKey {
            case text
            case columnHeader = "column_header"
        }
    }

    struct DoclingPage: Codable {
        let size: DoclingPageSize?
        let pageNo: Int?

        enum CodingKeys: String, CodingKey {
            case size
            case pageNo = "page_no"
        }
    }

    struct DoclingPageSize: Codable {
        let width: Double?
        let height: Double?
    }

    // MARK: - Public Methods

    /// Chunk a docling JSON file
    func chunkDoclingJSON(
        fileURL: URL,
        source: String? = nil,
        options: ChunkingOptions = ChunkingOptions()
    ) async throws -> [DocumentChunk] {

        // Validate file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ChunkingError.fileNotFound(fileURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ChunkingError.fileNotFound(fileURL)
        }

        // Validate JSON is not empty
        guard !data.isEmpty else {
            throw ChunkingError.invalidJSON("File is empty")
        }

        // Parse JSON with detailed error handling
        let document: DoclingDocument
        do {
            document = try JSONDecoder().decode(DoclingDocument.self, from: data)
        } catch let decodingError as DecodingError {
            let details: String
            switch decodingError {
            case .keyNotFound(let key, let context):
                details = "Missing key '\(key.stringValue)' at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
            case .typeMismatch(let type, let context):
                details = "Type mismatch for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
            case .valueNotFound(let type, let context):
                details = "Missing value for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
            case .dataCorrupted(let context):
                details = "Corrupted data at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
            @unknown default:
                details = decodingError.localizedDescription
            }
            throw ChunkingError.invalidJSON(details)
        } catch {
            throw ChunkingError.invalidJSON(error.localizedDescription)
        }

        let sourceName = source ?? document.origin?.filename ?? fileURL.lastPathComponent

        let chunks = chunkDocument(document, source: sourceName, options: options)

        // Validate we got some content
        guard !chunks.isEmpty else {
            throw ChunkingError.emptyDocument
        }

        return chunks
    }

    /// Chunk a docling document structure
    func chunkDocument(
        _ document: DoclingDocument,
        source: String,
        options: ChunkingOptions = ChunkingOptions()
    ) -> [DocumentChunk] {

        // Build lookup dictionaries for texts and tables by their self_ref
        var textsById: [String: DoclingTextItem] = [:]
        if let texts = document.texts {
            for item in texts {
                if let ref = item.selfRef {
                    textsById[ref] = item
                }
            }
        }
        var tablesById: [String: DoclingTable] = [:]
        if let tables = document.tables {
            for table in tables {
                if let ref = table.selfRef {
                    tablesById[ref] = table
                }
            }
        }
        var groupsById: [String: DoclingGroup] = [:]
        if let groups = document.groups {
            for group in groups {
                if let ref = group.selfRef {
                    groupsById[ref] = group
                }
            }
        }

        let docTitle = document.description?.title ?? document.name
        let authors = document.description?.authors
        let doi = document.description?.doi
        let docURL = document.description?.url ?? document.origin?.uri
        let documentId = UUID().uuidString

        var chunks: [DocumentChunk] = []
        var currentHeadings: [String] = []
        var currentPage: Int?
        var buffer: [String] = []
        var formattedBuffer: [String] = []
        var bufferTokenCount = 0
        var inList = false
        var overlapText: String?
        var overlapFormatted: String?
        var chunkCounter = 0
        var currentContentType = "text"

        func flushBuffer() {
            guard !buffer.isEmpty else { return }

            let text = buffer.joined(separator: "\n\n")
            let formatted = formattedBuffer.joined(separator: "\n\n")
            let chunk = DocumentChunk(
                text: text,
                source: source,
                page: currentPage,
                headings: currentHeadings,
                tokenCount: bufferTokenCount,
                formattedContent: formatted,
                chunkIndex: chunkCounter,
                contentType: currentContentType,
                section: currentHeadings.last,
                docTitle: docTitle,
                authors: authors,
                doi: doi,
                documentId: documentId,
                url: docURL
            )
            chunks.append(chunk)
            chunkCounter += 1

            if options.overlapTokens > 0 {
                let overlapChars = options.overlapTokens * 4
                overlapText = String(text.suffix(overlapChars))
                overlapFormatted = String(formatted.suffix(overlapChars))
            }

            buffer = []
            formattedBuffer = []
            bufferTokenCount = 0

            if let ot = overlapText, let of = overlapFormatted, !ot.isEmpty {
                buffer.append(ot)
                formattedBuffer.append(of)
                bufferTokenCount = estimateTokenCount(ot)
            }
        }

        func processTextItem(_ item: DoclingTextItem, isListItem: Bool = false) {
            guard let text = item.text, !text.isEmpty else { return }

            let label = item.label ?? ""
            let tokenCount = estimateTokenCount(text)

            // Update current page from provenance
            if let prov = item.prov?.first, let pageNo = prov.pageNo {
                if currentPage != pageNo {
                    flushBuffer()
                    currentPage = pageNo
                }
            }

            if label == "page_header" || label == "page_footer" {
                return
            }

            switch label {
            case "caption": currentContentType = "figure_caption"
            case "abstract": currentContentType = "abstract"
            case "reference": currentContentType = "references"
            case "footnote": currentContentType = "footnote"
            default: currentContentType = "text"
            }

            // Handle headings (docling uses "section_header", "title", or labels containing "heading")
            let isHeading = label == "section_header" || label.lowercased().contains("heading") || label.lowercased().contains("title")
            if isHeading {
                if options.preserveHeadings {
                    flushBuffer()
                    // Determine heading level - use docling's level if available, otherwise infer
                    let headingLevel = item.level ?? inferHeadingLevel(text: text, label: label)
                    switch headingLevel {
                    case 1:
                        currentHeadings = [text]
                    case 2:
                        if let firstHeading = currentHeadings.first {
                            currentHeadings = [firstHeading, text]
                        } else {
                            currentHeadings = [text]
                        }
                    case 3:
                        let parents = Array(currentHeadings.prefix(2))
                        currentHeadings = parents + [text]
                    default:
                        currentHeadings.append(text)
                        if currentHeadings.count > 3 {
                            currentHeadings = Array(currentHeadings.suffix(3))
                        }
                    }
                    // Add heading to formatted buffer with proper markdown syntax
                    let mdPrefix = String(repeating: "#", count: min(headingLevel + 1, 6)) // H2-H6 (H1 reserved for doc title)
                    formattedBuffer.append("\(mdPrefix) \(text)")
                    buffer.append(text)
                    bufferTokenCount += tokenCount
                }
                return
            }

            // Check if adding this would exceed limit
            if bufferTokenCount + tokenCount > options.maxTokensPerChunk {
                flushBuffer()
            }

            // Format list items properly
            let isListItemLabel = label == "list_item" || isListItem
            if isListItemLabel {
                // Clean up the text - docling sometimes includes the bullet/dash
                var cleanText = text
                if cleanText.hasPrefix("-") || cleanText.hasPrefix("•") {
                    cleanText = String(cleanText.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                formattedBuffer.append("- \(cleanText)")
            } else {
                formattedBuffer.append(text)
            }

            buffer.append(text)
            bufferTokenCount += tokenCount
        }

        func processTable(_ table: DoclingTable) {
            let tableText = formatTable(table)
            guard !tableText.isEmpty else { return }
            currentContentType = "table"

            let tokenCount = estimateTokenCount(tableText)

            // Update page from provenance
            if let prov = table.prov?.first, let pageNo = prov.pageNo {
                if currentPage != pageNo {
                    flushBuffer()
                    currentPage = pageNo
                }
            }

            if bufferTokenCount + tokenCount > options.maxTokensPerChunk {
                flushBuffer()
            }

            buffer.append(tableText)
            formattedBuffer.append(tableText)
            bufferTokenCount += tokenCount
        }

        func processRef(_ ref: String, isListItem: Bool = false) {
            if let textItem = textsById[ref] {
                processTextItem(textItem, isListItem: isListItem)
            } else if let table = tablesById[ref] {
                if options.includeTableContent {
                    processTable(table)
                }
            } else if let group = groupsById[ref] {
                // Process group children - check if this is a list
                let isList = group.label == "list"
                if let children = group.children {
                    for child in children {
                        if let childRef = child.ref {
                            processRef(childRef, isListItem: isList)
                        }
                    }
                }
            }
            // pictures and other refs are skipped
        }

        // Process body children in document order if body is available
        if let bodyChildren = document.body?.children, !bodyChildren.isEmpty {
            for child in bodyChildren {
                if let ref = child.ref {
                    processRef(ref)
                }
            }
        } else {
            // Fallback: process texts then tables (old behavior) if no body
            if let texts = document.texts {
                for item in texts {
                    processTextItem(item)
                }
            }
            if options.includeTableContent, let tables = document.tables {
                for table in tables {
                    processTable(table)
                }
            }
        }

        flushBuffer()

        // Filter out chunks that are too small
        return chunks.filter { $0.tokenCount >= options.minChunkSize || $0.text.count >= 50 }
    }

    /// Infer heading level from the section numbering in the text
    private func inferHeadingLevel(text: String, label: String) -> Int {
        // Check label first for explicit levels
        if label.lowercased().contains("title") { return 1 }

        // Infer from section numbering pattern: "1." = level 1, "2.1." = level 2, "2.1.3" = level 3
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Match patterns like "1.", "1.2", "1.2.", "1.2.3", etc. at the start
        let numberPattern = /^(\d+)(\.(\d+))?(\.(\d+))?\.?\s/
        if let match = trimmed.firstMatch(of: numberPattern) {
            if match.5 != nil { return 3 }  // e.g. "1.2.3 ..."
            if match.3 != nil { return 2 }  // e.g. "2.1. ..."
            return 1                          // e.g. "1. ..."
        }

        // Default: treat as level 1
        return 1
    }

    /// Chunk plain text content
    func chunkText(
        _ text: String,
        source: String,
        options: ChunkingOptions = ChunkingOptions()
    ) -> [DocumentChunk] {

        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [DocumentChunk] = []
        var buffer: [String] = []
        var bufferTokenCount = 0
        var overlapText: String?

        func flushBuffer() {
            guard !buffer.isEmpty else { return }

            let text = buffer.joined(separator: "\n\n")
            let chunk = DocumentChunk(
                text: text,
                source: source,
                tokenCount: bufferTokenCount
            )
            chunks.append(chunk)

            if options.overlapTokens > 0 {
                let overlapChars = options.overlapTokens * 4
                overlapText = String(text.suffix(overlapChars))
            }

            buffer = []
            bufferTokenCount = 0

            if let ot = overlapText, !ot.isEmpty {
                buffer.append(ot)
                bufferTokenCount = estimateTokenCount(ot)
            }
        }

        for paragraph in paragraphs {
            let tokenCount = estimateTokenCount(paragraph)

            if bufferTokenCount + tokenCount > options.maxTokensPerChunk && !buffer.isEmpty {
                flushBuffer()
            }

            // Handle very long paragraphs
            if tokenCount > options.maxTokensPerChunk {
                flushBuffer()
                let subChunks = splitLongText(paragraph, maxTokens: options.maxTokensPerChunk)
                for subChunk in subChunks {
                    chunks.append(DocumentChunk(
                        text: subChunk,
                        source: source,
                        tokenCount: estimateTokenCount(subChunk)
                    ))
                }
            } else {
                buffer.append(paragraph)
                bufferTokenCount += tokenCount
            }
        }

        flushBuffer()

        return chunks
    }

    // MARK: - Private Methods

    private func estimateTokenCount(_ text: String) -> Int {
        // Rough estimate: ~4 characters per token for English
        return max(1, text.count / 4)
    }

    private func formatTable(_ table: DoclingTable) -> String {
        guard let data = table.data, let grid = data.grid, !grid.isEmpty else {
            return ""
        }

        // Calculate column widths for alignment
        let numCols = grid.map { $0.count }.max() ?? 0
        guard numCols > 0 else { return "" }

        var colWidths = Array(repeating: 3, count: numCols) // minimum width of 3 for "---"
        for row in grid {
            for (col, cell) in row.enumerated() where col < numCols {
                let cellText = cell.text ?? ""
                colWidths[col] = max(colWidths[col], cellText.count)
            }
        }

        // Determine header row: use column_header metadata from first row
        let firstRowIsHeader = grid[0].contains { $0.columnHeader == true }

        var lines: [String] = []

        for (rowIdx, row) in grid.enumerated() {
            var cells: [String] = []
            for col in 0..<numCols {
                let cellText = col < row.count ? (row[col].text ?? "") : ""
                let padded = cellText.padding(toLength: colWidths[col], withPad: " ", startingAt: 0)
                cells.append(padded)
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")

            // Add separator after header row
            if rowIdx == 0 && firstRowIsHeader {
                let separator = colWidths.map { String(repeating: "-", count: $0) }
                lines.append("| " + separator.joined(separator: " | ") + " |")
            }
        }

        // If no header was detected, still add a separator after the first row
        // to make it a valid markdown table
        if !firstRowIsHeader && lines.count > 1 {
            let separator = colWidths.map { String(repeating: "-", count: $0) }
            lines.insert("| " + separator.joined(separator: " | ") + " |", at: 1)
        }

        return lines.joined(separator: "\n")
    }

    private func splitLongText(_ text: String, maxTokens: Int) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }

        var chunks: [String] = []
        var buffer: [String] = []
        var bufferTokenCount = 0

        for sentence in sentences {
            let tokenCount = estimateTokenCount(sentence)

            if bufferTokenCount + tokenCount > maxTokens && !buffer.isEmpty {
                chunks.append(buffer.joined(separator: " "))
                buffer = []
                bufferTokenCount = 0
            }

            buffer.append(sentence)
            bufferTokenCount += tokenCount
        }

        if !buffer.isEmpty {
            chunks.append(buffer.joined(separator: " "))
        }

        return chunks
    }
}

// MARK: - Convenience

extension ChunkingService.DocumentChunk {

    /// Convert to ChunkPoint (without embeddings)
    func toChunkPoint() -> ChunkPoint {
        ChunkPoint(
            id: id,
            vector: [],  // Embeddings will be added later
            text: text,
            source: source,
            page: page,
            headings: headings,
            metadata: metadata
        )
    }
}

extension Array where Element == ChunkingService.DocumentChunk {

    /// Convert all chunks to ChunkPoints (without embeddings)
    func toChunkPoints() -> [ChunkPoint] {
        map { $0.toChunkPoint() }
    }
}
