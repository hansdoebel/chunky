import Foundation

nonisolated struct SectionSibling: Equatable, Sendable {
    var id: String
    var source: String
    var headings: [String]
    var page: Int?
    var pageEnd: Int?
    var text: String
}

nonisolated enum SectionExpansion {
    static let defaultThreshold = 0.5

    static func merge(hits: [RetrievalHit], siblings: [SectionSibling], threshold: Double) -> [RetrievalHit] {
        let ratio = threshold.isFinite ? min(max(threshold, 0), 1) : defaultThreshold
        var grouped: [String: [RetrievalHit]] = [:]
        var order: [String] = []
        for hit in hits where hit.payload["record_type"] != DocumentSummary.documentRecord {
            let key = groupKey(source: hit.source, headings: hit.headings)
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(hit)
        }
        let byGroup = Dictionary(grouping: siblings, by: { groupKey(source: $0.source, headings: $0.headings) })
        var merged: [RetrievalHit] = []
        for key in order {
            let group = grouped[key] ?? []
            guard let first = group.first, !first.headings.isEmpty else {
                merged.append(contentsOf: group)
                continue
            }
            let section = byGroup[key] ?? []
            let population = max(section.count, group.count)
            let share = Double(group.count) / Double(population)
            if population > 1, share + 0.000_000_1 >= ratio {
                merged.append(combined(hits: group, section: section.isEmpty ? group.map(sibling) : section))
            } else {
                merged.append(contentsOf: group)
            }
        }
        return merged
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
            text: hit.text
        )
    }

    private static func combined(hits: [RetrievalHit], section: [SectionSibling]) -> RetrievalHit {
        let ordered = section.sorted { lhs, rhs in
            let left = lhs.page ?? Int.max
            let right = rhs.page ?? Int.max
            if left == right { return lhs.id < rhs.id }
            return left < right
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
