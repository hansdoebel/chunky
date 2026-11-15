import CoreGraphics
import Foundation

struct CitationHighlight: Identifiable, Equatable {
    var id: String
    var title: String
    var page: Int
    var chrome: String
    var boxes: [VerificationBBox]
    var pdfURL: URL?
    var message: String?
}

enum CitationPDF {
    static let missingFile = "The source PDF is not on this Mac."
    static let unreadableFile = "The source PDF could not be opened."

    static func shouldStore(path: String, existing: String?) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let current = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current != trimmed
    }

    static func pointIDs(missing path: String, in points: [(id: String, sourcePath: String?)]) -> [String] {
        points.compactMap { point in
            shouldStore(path: path, existing: point.sourcePath) ? point.id : nil
        }
    }

    static func resolve(
        path: String?,
        source: String,
        known: [URL],
        exists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> URL? {
        for candidate in [path, source] {
            guard let candidate, candidate.hasPrefix("/") else { continue }
            if exists(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        let name = (source as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return known.first { $0.lastPathComponent == name && exists($0.path) }
    }

    static func boxes(json: String?, page: Int?) -> [VerificationBBox] {
        guard let json, let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let l = number(row["l"]), let t = number(row["t"]),
                  let r = number(row["r"]), let b = number(row["b"])
            else { return nil }
            if let page, let boxPage = integer(row["page"]), boxPage != page {
                return nil
            }
            let raw = (row["origin"] as? String) ?? (row["coord_origin"] as? String)
            return VerificationBBox(l: l, t: t, r: r, b: b, origin: origin(raw))
        }
    }

    static func pdfRect(_ box: VerificationBBox, pageHeight: Double) -> CGRect {
        let height = max(pageHeight, 1)
        let left = min(box.l, box.r)
        let width = abs(box.r - box.l)
        let vertical = abs(box.t - box.b)
        let bottom: Double
        if box.origin == "top_left" || box.t < box.b {
            bottom = height - max(box.t, box.b)
        } else {
            bottom = min(box.t, box.b)
        }
        return CGRect(x: left, y: max(bottom, 0), width: width, height: vertical)
    }

    static func viewRect(_ box: VerificationBBox, pageWidth: Double, pageHeight: Double, in area: CGRect) -> CGRect {
        let pdf = pdfRect(box, pageHeight: pageHeight)
        let normalized = VerificationBBox(
            l: pdf.minX,
            t: pdf.maxY,
            r: pdf.maxX,
            b: pdf.minY,
            origin: "bottom_left"
        )
        return normalized.rect(pageWidth: pageWidth, pageHeight: pageHeight, in: area)
    }

    static func chrome(printed: String?, labels: String?, page: Int?) -> String {
        if let printed, !printed.isEmpty { return printed }
        if let labels {
            let parts = labels.split { $0 == "\n" || $0 == ">" }.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if let first = parts.first {
                return first.hasPrefix("p.") || first.hasPrefix("pp.") ? first : "p. \(first)"
            }
        }
        if let page { return "p. \(page)" }
        return "Source page"
    }

    static func highlight(hit: RetrievalHit, known: [URL], exists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> CitationHighlight {
        make(
            id: hit.id,
            title: hit.docTitle.isEmpty ? hit.source : hit.docTitle,
            source: hit.source,
            path: hit.payload["source_path"],
            page: hit.page,
            printed: hit.payload["printed_page"],
            labels: hit.payload["page_labels"],
            bboxes: hit.payload["bboxes"],
            known: known,
            exists: exists
        )
    }

    static func highlight(
        citation: RAGCitation,
        hit: RetrievalHit?,
        known: [URL],
        exists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> CitationHighlight {
        let source = hit?.source ?? citation.source
        return make(
            id: citation.id,
            title: citation.paperLabel,
            source: source,
            path: hit?.payload["source_path"],
            page: hit?.page ?? citation.page,
            printed: hit?.payload["printed_page"] ?? citation.printedPage,
            labels: hit?.payload["page_labels"],
            bboxes: hit?.payload["bboxes"],
            known: known,
            exists: exists
        )
    }

    private static func make(
        id: String,
        title: String,
        source: String,
        path: String?,
        page: Int?,
        printed: String?,
        labels: String?,
        bboxes: String?,
        known: [URL],
        exists: (String) -> Bool
    ) -> CitationHighlight {
        let index = page ?? 1
        let url = resolve(path: path, source: source, known: known, exists: exists)
        return CitationHighlight(
            id: id,
            title: title,
            page: index,
            chrome: chrome(printed: printed, labels: labels, page: page),
            boxes: boxes(json: bboxes, page: page),
            pdfURL: url,
            message: url == nil ? missingFile : nil
        )
    }

    private static func origin(_ raw: String?) -> String {
        let folded = (raw ?? "").lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return folded == "topleft" ? "top_left" : "bottom_left"
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
