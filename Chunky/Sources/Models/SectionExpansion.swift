import Foundation

nonisolated struct SectionSibling: Equatable, Sendable {
    var id: String
    var source: String
    var headings: [String]
    var page: Int?
    var pageEnd: Int?
    var text: String
    var chunkIndex: Int? = nil
    var libraryID: String? = nil
}

nonisolated enum SectionExpansion {
    static let defaultThreshold = 0.5

    static func merge(hits: [RetrievalHit], siblings: [SectionSibling], threshold: Double) -> [RetrievalHit] {
        let ratio = threshold.isFinite ? min(max(threshold, 0), 1) : defaultThreshold
        var grouped: [String: [RetrievalHit]] = [:]
        for hit in hits where hit.payload["record_type"] != DocumentSummary.documentRecord {
            grouped[groupKey(source: hit.source, headings: hit.headings), default: []].append(hit)
        }
        let byGroup = Dictionary(grouping: siblings, by: { groupKey(source: $0.source, headings: $0.headings) })
        var merging: Set<String> = []
        for (key, group) in grouped {
            guard let first = group.first, !first.headings.isEmpty else { continue }
            let section = byGroup[key] ?? []
            let population = max(section.count, group.count)
            let share = Double(group.count) / Double(population)
            if population > 1, share + 0.000_000_1 >= ratio {
                merging.insert(key)
            }
        }
        var emitted: Set<String> = []
        var result: [RetrievalHit] = []
        for hit in hits {
            if hit.payload["record_type"] == DocumentSummary.documentRecord {
                result.append(hit)
                continue
            }
            let key = groupKey(source: hit.source, headings: hit.headings)
            guard merging.contains(key) else {
                result.append(hit)
                continue
            }
            if emitted.contains(key) { continue }
            emitted.insert(key)
            let group = grouped[key] ?? [hit]
            let section = byGroup[key] ?? []
            result.append(combined(hits: group, section: section.isEmpty ? group.map(sibling) : section))
        }
        return result
    }

    static func restricting(_ siblings: [SectionSibling], filters: [RetrievalFilter]) -> [SectionSibling] {
        let library = filters.filter { $0.key == PaperLibrary.field }
        guard !library.isEmpty else { return siblings }
        return siblings.filter { sibling in
            var payload: [String: Any] = [:]
            if let libraryID = sibling.libraryID, !libraryID.isEmpty {
                payload[PaperLibrary.field] = libraryID
            }
            return RetrievalFilter.keeps(payload, filters: library)
        }
    }

    static func groupKey(source: String, headings: [String]) -> String {
        source + "\n" + headings.joined(separator: "\n")
    }

    private static func sibling(_ hit: RetrievalHit) -> SectionSibling {
        SectionSibling(
            id: hit.id,
            source: hit.source,
            headings: hit.headings,
            page: hit.page,
            pageEnd: hit.pageEnd,
            text: hit.text,
            chunkIndex: Int(hit.payload["chunk_index"] ?? "")
        )
    }

    private static func combined(hits: [RetrievalHit], section: [SectionSibling]) -> RetrievalHit {
        let ordered = section.sorted { lhs, rhs in
            let leftPage = lhs.page ?? Int.max
            let rightPage = rhs.page ?? Int.max
            if leftPage != rightPage { return leftPage < rightPage }
            let leftIndex = lhs.chunkIndex ?? Int.max
            let rightIndex = rhs.chunkIndex ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return lhs.id < rhs.id
        }
        let pages = (hits.compactMap(\.page) + hits.compactMap(\.pageEnd) + ordered.compactMap(\.page) + ordered.compactMap(\.pageEnd))
        let page = pages.min()
        let pageEnd = pages.max()
        let ids = hits.map(\.id)
        var payload = hits[0].payload
        payload["chunk_ids"] = ids.joined(separator: ",")
        if let page { payload["page"] = String(page) }
        if let pageEnd { payload["page_end"] = String(pageEnd) }
        payload["text"] = ordered.map(\.text).joined(separator: "\n\n")
        return RetrievalHit(
            id: ids[0],
            score: hits.map(\.score).max() ?? hits[0].score,
            text: payload["text"] ?? hits[0].text,
            source: hits[0].source,
            page: page,
            headings: hits[0].headings,
            payload: payload,
            docTitle: hits[0].docTitle,
            pageEnd: pageEnd
        )
    }
}
