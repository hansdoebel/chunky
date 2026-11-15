import CryptoKit
import Foundation

nonisolated struct SummaryChunk: Equatable, Sendable {
    var text: String
    var headings: [String]
    var page: Int?
}

nonisolated struct DocumentSummaryChoice: Equatable, Sendable {
    var text: String
    var kind: String
    var source: String
}

nonisolated enum DocumentSummary {
    static let abstractHeadings: Set<String> = ["abstract", "summary", "zusammenfassung"]
    static let documentRecord = "document"
    static let passageOnlyKeys: Set<String> = ["content_type", "page", "page_end", "headings", "section"]

    static func summaryID(source: String) -> String {
        let namespace: [UInt8] = [
            0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
            0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
        ]
        var bytes = namespace
        bytes.append(contentsOf: Array("chunky-summary:\(source)".utf8))
        var hash = Array(Insecure.SHA1.hash(data: Data(bytes)))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        return "\(String(chars[0..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))-\(String(chars[16..<20]))-\(String(chars[20..<32]))"
    }

    static func resolve(chunks: [SummaryChunk], title: String, generated: String?) -> DocumentSummaryChoice {
        let material = fallbackSource(chunks: chunks, title: title)
        if let abstract = abstractText(chunks: chunks) {
            return DocumentSummaryChoice(text: abstract, kind: "abstract", source: material)
        }
        let written = generated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !written.isEmpty {
            return DocumentSummaryChoice(text: written, kind: "generated", source: material)
        }
        return DocumentSummaryChoice(text: material, kind: "extract", source: material)
    }

    static func abstractText(chunks: [SummaryChunk]) -> String? {
        let parts = chunks.compactMap { chunk -> String? in
            let headings = chunk.headings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard headings.contains(where: { abstractHeadings.contains($0) }) else { return nil }
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func fallbackSource(chunks: [SummaryChunk], title: String) -> String {
        var headings: [String] = []
        var pages: [String] = []
        for chunk in chunks {
            for heading in chunk.headings where !headings.contains(heading) {
                headings.append(heading)
            }
            if (chunk.page ?? 1) <= 2 {
                let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    pages.append(text)
                }
            }
        }
        var lines: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            lines.append(trimmedTitle)
        }
        if !headings.isEmpty {
            lines.append("Sections: \(headings.prefix(12).joined(separator: " > "))")
        }
        let body = pages.joined(separator: "\n")
        if !body.isEmpty {
            lines.append(String(body.prefix(4000)))
        }
        return lines.joined(separator: "\n")
    }
}
