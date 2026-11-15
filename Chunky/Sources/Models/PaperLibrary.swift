import Foundation

nonisolated struct PaperLibrary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String

    static let defaultID = "default"
    static let field = "library_id"
    static let starter = PaperLibrary(id: defaultID, name: "Library")
    static let defaultJSON = #"[{"id":"default","name":"Library"}]"#

    static func load(_ json: String) -> [PaperLibrary] {
        let data = Data(json.utf8)
        let decoded = (try? JSONDecoder().decode([PaperLibrary].self, from: data)) ?? []
        if decoded.contains(where: { $0.id == defaultID }) { return decoded }
        return [starter] + decoded
    }

    static func adding(name: String, to libraries: [PaperLibrary]) -> [PaperLibrary] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return libraries }
        if libraries.contains(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return libraries
        }
        let id = stableID(name: trimmed, existing: Set(libraries.map(\.id)))
        return libraries + [PaperLibrary(id: id, name: trimmed)]
    }

    static func stableID(name: String, existing: Set<String>) -> String {
        let base = name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(base).split(separator: "-").joined(separator: "-")
        if slug.isEmpty { slug = "library" }
        if !existing.contains(slug) { return slug }
        var index = 2
        while existing.contains("\(slug)-\(index)") { index += 1 }
        return "\(slug)-\(index)"
    }

    static func save(_ libraries: [PaperLibrary]) -> String {
        let data = (try? JSONEncoder().encode(libraries)) ?? Data(defaultJSON.utf8)
        return String(data: data, encoding: .utf8) ?? defaultJSON
    }
}

nonisolated enum LibrarySearch: String, Sendable {
    case active
    case selected
    case all
}

nonisolated enum LibraryFilter {
    static func filters(activeID: String, selectedIDs: [String], scope: LibrarySearch) -> [RetrievalFilter] {
        switch scope {
        case .all:
            return []
        case .active:
            return membership(ids: [activeID.isEmpty ? PaperLibrary.defaultID : activeID])
        case .selected:
            let ids = selectedIDs.isEmpty ? [activeID] : selectedIDs
            return membership(ids: ids)
        }
    }

    static func membership(ids: [String]) -> [RetrievalFilter] {
        let cleaned = Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !cleaned.isEmpty else { return [] }
        if cleaned.count == 1, let only = cleaned.first, only != PaperLibrary.defaultID {
            return [RetrievalFilter(key: PaperLibrary.field, match: .text(only))]
        }
        var items = [RetrievalFilter(key: PaperLibrary.field, match: .anyText(cleaned), should: true)]
        if cleaned.contains(PaperLibrary.defaultID) {
            items.append(RetrievalFilter(key: PaperLibrary.field, matchEmpty: true, should: true))
        }
        return items
    }

    static func assignedID(_ libraryID: String) -> String {
        let trimmed = libraryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PaperLibrary.defaultID : trimmed
    }

    static func belongs(existing: String?, to libraryID: String) -> Bool {
        keeps([PaperLibrary.field: existing ?? ""], filters: membership(ids: [assignedID(libraryID)]))
    }

    static func backfill(existing: String?) -> String? {
        let trimmed = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? PaperLibrary.defaultID : nil
    }

    static func movePayload(libraryID: String) -> [String: String] {
        [PaperLibrary.field: libraryID]
    }

    static func keeps(_ payload: [String: Any], filters: [RetrievalFilter]) -> Bool {
        RetrievalFilter.keeps(payload, filters: filters)
    }
}

nonisolated struct LibraryMove: Equatable, Sendable {
    var ids: [String]
    var payload: [String: String]
    var reembed: Bool

    static func plan(ids: [String], libraryID: String) -> LibraryMove {
        LibraryMove(
            ids: ids,
            payload: LibraryFilter.movePayload(libraryID: LibraryFilter.assignedID(libraryID)),
            reembed: false
        )
    }
}
